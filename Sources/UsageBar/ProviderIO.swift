import Foundation
import SQLite3

enum ProviderIO {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    static func runBlocking<T: Sendable>(
        timeout: TimeInterval,
        _ work: @escaping @Sendable () -> T?
    ) async -> T? {
        let gate = ResumeGate<T>()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            DispatchQueue.global(qos: .utility).async {
                gate.resume(with: work())
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                gate.resume(with: nil)
            }
        }
    }
}

private final class ResumeGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var pending: T??

    func install(_ continuation: CheckedContinuation<T?, Never>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(returning: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with value: T?) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            pending = .some(value)
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        if pending == nil {
            pending = .some(value)
        }
        lock.unlock()
    }
}

enum ReadOnlySQLite {
    static func rows(
        at file: URL,
        sql: String,
        bindings: [String] = [],
        timeout: TimeInterval = 3
    ) async -> [[String?]]? {
        let path = file.path
        return await ProviderIO.runBlocking(timeout: timeout) {
            query(path: path, sql: sql, bindings: bindings, deadline: Date().addingTimeInterval(timeout))
        }
    }

    private static func query(path: String, sql: String, bindings: [String], deadline: Date) -> [[String?]]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        if let rows = query(uri: "file:\(encoded)?mode=ro", sql: sql, bindings: bindings, deadline: deadline) {
            return rows
        }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: path + "-wal"),
              !fileManager.fileExists(atPath: path + "-shm"),
              !fileManager.fileExists(atPath: path + "-journal") else {
            return nil
        }
        return query(uri: "file:\(encoded)?mode=ro&immutable=1", sql: sql, bindings: bindings, deadline: deadline)
    }

    private static func query(uri: String, sql: String, bindings: [String], deadline: Date) -> [[String?]]? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        let deadlineBox = Unmanaged.passRetained(DeadlineBox(deadline))
        defer { deadlineBox.release() }
        sqlite3_progress_handler(db, 1_000, { context in
            guard let context else { return 0 }
            let box = Unmanaged<DeadlineBox>.fromOpaque(context).takeUnretainedValue()
            return Date() > box.deadline ? 1 : 0
        }, deadlineBox.toOpaque())

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }

        var rows: [[String?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            let count = sqlite3_column_count(statement)
            rows.append((0..<count).map { text(in: statement, column: $0) })
        }
        return rows
    }

    private static func text(in statement: OpaquePointer?, column: Int32) -> String? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL:
            return nil
        case SQLITE_BLOB:
            let length = Int(sqlite3_column_bytes(statement, column))
            guard length > 0, let bytes = sqlite3_column_blob(statement, column) else { return nil }
            let data = Data(bytes: bytes, count: length)
            if let text = String(data: data, encoding: .utf8), !text.contains("\u{0}") {
                return text
            }
            return String(data: data, encoding: .utf16LittleEndian)
        default:
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }
    }
}

private final class DeadlineBox {
    let deadline: Date

    init(_ deadline: Date) {
        self.deadline = deadline
    }
}
