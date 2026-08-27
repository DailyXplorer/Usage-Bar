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

actor CursorUsageService {
    private static let endpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    )!
    private static let grokBotEndpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus"
    )!
    private static let stateDB = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")

    func fetchUsage() async throws -> (
        usage: CursorUsageResponse,
        grokBot: CursorSandUsageStatus?,
        credentials: CursorCredentials
    ) {
        let credentials = try Self.loadCredentials()
        async let periodData = postDashboard(url: Self.endpoint, token: credentials.accessToken)
        async let sandData = postDashboardIfOK(url: Self.grokBotEndpoint, token: credentials.accessToken)

        let usage: CursorUsageResponse
        do {
            usage = try JSONDecoder().decode(CursorUsageResponse.self, from: try await periodData)
        } catch let error as CursorUsageError {
            throw error
        } catch {
            throw CursorUsageError.decoding(error.localizedDescription)
        }

        let grokBot: CursorSandUsageStatus?
        if let sandData = await sandData {
            grokBot = try? JSONDecoder().decode(CursorSandUsageStatus.self, from: sandData)
        } else {
            grokBot = nil
        }
        return (usage, grokBot, credentials)
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

    private func postDashboardIfOK(url: URL, token: String) async -> Data? {
        do {
            let (data, http) = try await sendDashboard(url: url, token: token)
            guard http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
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
            (data, response) = try await URLSession.shared.data(for: request)
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
