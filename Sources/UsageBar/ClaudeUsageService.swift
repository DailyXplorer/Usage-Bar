import Foundation

struct ClaudeCredentials {
    let accessToken: String
    let subscriptionType: String?
    let expiresAt: Date?
}

enum ClaudeUsageError: LocalizedError {
    case notSignedIn
    case tokenExpired
    case throttled
    case network(String)
    case httpStatus(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "No Claude Code session. Run `claude`, then `/login`."
        case .tokenExpired:
            return "Claude token expired. Open Claude Code to refresh it."
        case .throttled:
            return "Claude usage endpoint is rate limited. Retrying at the next refresh."
        case .network(let message):
            return "Network error: \(message)"
        case .httpStatus(let code):
            return "Claude returned HTTP \(code). Open Claude Code to refresh the session."
        case .decoding(let message):
            return "Unreadable Claude response: \(message)"
        }
    }
}

/// Lit les quotas Claude Code : mêmes identifiants et même endpoint que `/usage`.
actor ClaudeUsageService {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"
    private static let credentialsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")

    func fetchUsage() async throws -> (usage: ClaudeUsageResponse, credentials: ClaudeCredentials) {
        let credentials = try Self.loadCredentials()

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeUsageError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeUsageError.network("invalid response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ClaudeUsageError.tokenExpired
            }
            if http.statusCode == 429 {
                throw ClaudeUsageError.throttled
            }
            throw ClaudeUsageError.httpStatus(http.statusCode)
        }

        do {
            return (try JSONDecoder().decode(ClaudeUsageResponse.self, from: data), credentials)
        } catch {
            throw ClaudeUsageError.decoding(error.localizedDescription)
        }
    }

    // MARK: - Identifiants

    private struct CredentialsFile: Decodable {
        struct OAuth: Decodable {
            let accessToken: String?
            let expiresAt: Double?
            let subscriptionType: String?

            enum CodingKeys: String, CodingKey {
                case accessToken
                case expiresAt
                case subscriptionType
            }
        }

        let claudeAiOauth: OAuth?
    }

    private static func loadCredentials() throws -> ClaudeCredentials {
        let data: Data
        if let keychainData = keychainData() {
            data = keychainData
        } else if let fileData = try? Data(contentsOf: credentialsFile) {
            data = fileData
        } else {
            throw ClaudeUsageError.notSignedIn
        }

        guard let oauth = try? JSONDecoder().decode(CredentialsFile.self, from: data).claudeAiOauth,
              let accessToken = oauth.accessToken, !accessToken.isEmpty else {
            throw ClaudeUsageError.notSignedIn
        }
        return ClaudeCredentials(
            accessToken: accessToken,
            subscriptionType: oauth.subscriptionType,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    /// Claude Code écrit cette entrée via `/usr/bin/security`, donc son ACL ne fait
    /// confiance qu'à ce binaire. On l'appelle de la même façon : un `SecItemCopyMatching`
    /// direct déclencherait une demande d'autorisation à chaque lancement.
    /// `nil` = pas d'entrée lisible, on tentera le fichier.
    private static func keychainData() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
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
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }
}
