import Foundation
import SQLite3

struct CursorCredentials {
    let accessToken: String
    let membershipType: String?
}

enum CursorUsageError: LocalizedError {
    case notSignedIn
    case unreadableLogin
    case tokenExpired
    case throttled
    case network(String)
    case httpStatus(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "No Cursor session. Open Cursor and sign in."
        case .unreadableLogin:
            return "Couldn’t read the Cursor session. Open Cursor and try again."
        case .tokenExpired:
            return "Cursor token expired. Open Cursor to refresh it."
        case .throttled:
            return "Cursor usage endpoint is rate limited. Retrying at the next refresh."
        case .network(let message):
            return "Network error: \(message)"
        case .httpStatus(let code):
            return "Cursor returned HTTP \(code). Open Cursor to refresh the session."
        case .decoding(let message):
            return "Unreadable Cursor response: \(message)"
        }
    }
}

enum CursorGrokBotFetchResult {
    case refreshed(CursorSandUsageStatus?)
    case unavailable
    case throttled
}

struct CursorGrokBotBackoff {
    private var backoff = ThrottleBackoff()

    var isBlocked: Bool {
        backoff.isBlocked
    }

    var blockedUntil: Date? {
        backoff.blockedUntil
    }

    mutating func update(after result: CursorGrokBotFetchResult, now: Date = Date()) {
        switch result {
        case .refreshed:
            backoff.reset()
        case .throttled:
            backoff.recordThrottle(now: now)
        case .unavailable:
            break
        }
    }
}

struct CursorUsageRequests {
    let credentials: CursorCredentials
    let period: Task<Result<CursorUsageResponse, CursorUsageError>, Never>
    let grokBot: Task<CursorGrokBotFetchResult, Never>
}

actor CursorUsageService {
    static let defaultEndpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    )!
    static let defaultGrokBotEndpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus"
    )!
    private static let stateDB = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")

    private let endpoint: URL
    private let grokBotEndpoint: URL
    private let session: URLSession

    init(
        endpoint: URL = CursorUsageService.defaultEndpoint,
        grokBotEndpoint: URL = CursorUsageService.defaultGrokBotEndpoint,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.grokBotEndpoint = grokBotEndpoint
        self.session = session
    }

    func startFetch(includeGrokBot: Bool = true) throws -> CursorUsageRequests {
        let credentials = try Self.loadCredentials()
        return startFetch(credentials: credentials, includeGrokBot: includeGrokBot)
    }

    func startFetch(
        credentials: CursorCredentials,
        includeGrokBot: Bool = true
    ) -> CursorUsageRequests {
        let token = credentials.accessToken
        return CursorUsageRequests(
            credentials: credentials,
            period: Task { await fetchPeriod(token: token) },
            grokBot: Task { await fetchGrokBot(token: token, enabled: includeGrokBot) }
        )
    }

    private func fetchPeriod(token: String) async -> Result<CursorUsageResponse, CursorUsageError> {
        do {
            let data = try await postDashboard(url: endpoint, token: token)
            return .success(try JSONDecoder().decode(CursorUsageResponse.self, from: data))
        } catch let error as CursorUsageError {
            return .failure(error)
        } catch {
            return .failure(.decoding(error.localizedDescription))
        }
    }

    private func fetchGrokBot(token: String, enabled: Bool) async -> CursorGrokBotFetchResult {
        guard enabled else { return .unavailable }
        do {
            let data = try await postDashboard(url: grokBotEndpoint, token: token)
            let status = try JSONDecoder().decode(CursorSandUsageStatus?.self, from: data)
            return .refreshed(status)
        } catch CursorUsageError.throttled {
            return .throttled
        } catch {
            return .unavailable
        }
    }

    private func postDashboard(url: URL, token: String) async throws -> Data {
        let (data, http) = try await sendDashboard(url: url, token: token)
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw CursorUsageError.tokenExpired
            }
            if http.statusCode == 429 {
                throw CursorUsageError.throttled
            }
            throw CursorUsageError.httpStatus(http.statusCode)
        }
        return data
    }

    private func sendDashboard(url: URL, token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CursorUsageError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CursorUsageError.network("invalid response")
        }
        return (data, http)
    }

    private static func loadCredentials() throws -> CursorCredentials {
        guard FileManager.default.fileExists(atPath: stateDB.path) else {
            throw CursorUsageError.notSignedIn
        }
        guard let values = sqliteValues() else {
            throw CursorUsageError.unreadableLogin
        }
        guard let accessToken = values["cursorAuth/accessToken"], !accessToken.isEmpty else {
            throw CursorUsageError.notSignedIn
        }
        let membership = values["cursorAuth/stripeMembershipType"]
        return CursorCredentials(
            accessToken: accessToken,
            membershipType: membership?.isEmpty == false ? membership : nil
        )
    }

    private static func sqliteValues() -> [String: String]? {
        if let values = sqliteValuesInProcess() {
            return values
        }
        let encodedPath = stateDB.path.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: "/"))
        ) ?? stateDB.path
        let queries = [
            stateDB.path,
            "file:\(encodedPath)?mode=ro",
        ]
        for database in queries {
            if let values = sqliteValues(database: database) {
                return values
            }
        }
        return nil
    }

    private static func sqliteValuesInProcess() -> [String: String]? {
        var db: OpaquePointer?
        let encodedPath = stateDB.path.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: "/"))
        ) ?? stateDB.path
        let uri = "file:\(encodedPath)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)

        let sql = "SELECT key, value FROM ItemTable WHERE key IN ('cursorAuth/accessToken','cursorAuth/stripeMembershipType');"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var values: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let keyPointer = sqlite3_column_text(statement, 0),
                  let valuePointer = sqlite3_column_text(statement, 1) else {
                continue
            }
            values[String(cString: keyPointer)] = String(cString: valuePointer)
        }
        return values
    }

    private static func sqliteValues(database: String) -> [String: String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            "-batch",
            "-separator",
            "\t",
            database,
            "SELECT key, value FROM ItemTable WHERE key IN ('cursorAuth/accessToken','cursorAuth/stripeMembershipType');",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1])
        }
        return values
    }
}
