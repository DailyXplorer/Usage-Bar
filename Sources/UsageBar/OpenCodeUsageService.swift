import Foundation

struct OpenCodeCredentials {
    let apiKey: String
}

enum OpenCodeUsageError: LocalizedError {
    case notSignedIn
    case invalidKey
    case notSubscribed
    case throttled(retryAfter: Date?)
    case network(String)
    case httpStatus(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "No OpenCode Go key found. Run `/connect` in OpenCode and select OpenCode Go."
        case .invalidKey:
            return "OpenCode Go rejected the key. Run `/connect` in OpenCode again."
        case .notSubscribed:
            return "This OpenCode workspace has no Go subscription. Subscribe to OpenCode Go, then try again."
        case .throttled:
            return "OpenCode paused usage updates. Usage Bar will try again later."
        case .network:
            return "Can’t reach OpenCode. Check your connection."
        case .httpStatus:
            return "OpenCode isn’t responding right now. Usage Bar will try again."
        case .decoding:
            return "OpenCode sent usage in a format Usage Bar can’t read. Check for a Usage Bar update."
        }
    }
}

actor OpenCodeUsageService {
    static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    static let integrationID = "opencode-go"

    private let session: URLSession

    init(session: URLSession = ProviderSession.shared) {
        self.session = session
    }

    func fetchUsage() async throws -> (usage: OpenCodeUsageResponse, credentials: OpenCodeCredentials) {
        let credentials = try await Self.loadCredentials()

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenCodeUsageError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeUsageError.network("invalid response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 {
                throw OpenCodeUsageError.invalidKey
            }
            if http.statusCode == 403 {
                throw OpenCodeUsageError.notSubscribed
            }
            if http.statusCode == 429 {
                throw OpenCodeUsageError.throttled(retryAfter: RetryAfter.date(from: http))
            }
            throw OpenCodeUsageError.httpStatus(http.statusCode)
        }

        do {
            return (try JSONDecoder().decode(OpenCodeUsageResponse.self, from: data), credentials)
        } catch {
            throw OpenCodeUsageError.decoding(String(describing: type(of: error)))
        }
    }

    static func loadCredentials(
        databases: [URL] = databaseCandidates(),
        authFiles: [URL] = authFileCandidates()
    ) async throws -> OpenCodeCredentials {
        for database in databases {
            if let key = await databaseKey(in: database) {
                return OpenCodeCredentials(apiKey: key)
            }
        }
        return try loadCredentials(from: authFiles)
    }

    static func databaseKey(in database: URL) async -> String? {
        guard let rows = await ReadOnlySQLite.rows(
            at: database,
            sql: "SELECT value FROM credential WHERE integration_id = ? ORDER BY active DESC, time_updated DESC",
            bindings: [integrationID]
        ) else {
            return nil
        }
        for row in rows {
            guard let text = row.first ?? nil,
                  let value = try? JSONDecoder().decode(OpenCodeCredentialValue.self, from: Data(text.utf8)),
                  value.type == nil || value.type == "key" || value.type == "api",
                  let key = value.key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                continue
            }
            return key
        }
        return nil
    }

    nonisolated static func databaseCandidates(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var files: [URL] = []
        if let path = environment["OPENCODE_DB"], !path.isEmpty, path != ":memory:" {
            files.append(URL(fileURLWithPath: path))
        }
        files += dataDirectories(home: home, environment: environment)
            .map { $0.appendingPathComponent("opencode.db") }
        return unique(files)
    }

    nonisolated static func authFileCandidates(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        unique(dataDirectories(home: home, environment: environment).map { $0.appendingPathComponent("auth.json") })
    }

    private nonisolated static func dataDirectories(home: URL, environment: [String: String]) -> [URL] {
        var directories: [URL] = []
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            directories.append(
                URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("opencode", isDirectory: true)
            )
        }
        directories.append(home.appendingPathComponent(".local/share/opencode", isDirectory: true))
        directories.append(home.appendingPathComponent("Library/Application Support/opencode", isDirectory: true))
        return directories
    }

    private nonisolated static func unique(_ files: [URL]) -> [URL] {
        var seen = Set<String>()
        return files.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    nonisolated static func loadCredentials(from files: [URL]) throws -> OpenCodeCredentials {
        for file in files {
            guard FileManager.default.fileExists(atPath: file.path),
                  let data = try? Data(contentsOf: file),
                  let auth = try? JSONDecoder().decode(OpenCodeAuthFile.self, from: data),
                  let apiKey = auth.opencodeGo?.key, !apiKey.isEmpty else {
                continue
            }
            return OpenCodeCredentials(apiKey: apiKey)
        }
        throw OpenCodeUsageError.notSignedIn
    }
}

private struct OpenCodeCredentialValue: Decodable {
    let type: String?
    let key: String?
}

private struct OpenCodeAuthFile: Decodable {
    struct Entry: Decodable {
        let key: String?
    }

    let opencodeGo: Entry?

    enum CodingKeys: String, CodingKey {
        case opencodeGo = "opencode-go"
    }
}
