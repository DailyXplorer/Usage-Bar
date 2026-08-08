import Foundation

struct CodexCredentials {
    let accessToken: String
    let accountId: String
}

enum UsageError: LocalizedError {
    case missingAuthFile
    case missingTokens
    case network(String)
    case httpStatus(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingAuthFile:
            return "auth.json not found. Run `codex login` in your terminal."
        case .missingTokens:
            return "Missing tokens in auth.json. Run `codex login` again."
        case .network(let message):
            return "Network error: \(message)"
        case .httpStatus(let code):
            return "HTTP \(code). Check that you are signed in to ChatGPT (codex login)."
        case .decoding(let message):
            return "Unreadable response: \(message)"
        }
    }
}

actor UsageService {
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let authFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/auth.json")

    func fetchUsage() async throws -> UsageResponse {
        let credentials = try Self.loadCredentials()
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.network("invalid response")
        }
        guard http.statusCode == 200 else {
            throw UsageError.httpStatus(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw UsageError.decoding(error.localizedDescription)
        }
    }

    private static func loadCredentials() throws -> CodexCredentials {
        guard FileManager.default.fileExists(atPath: authFile.path) else {
            throw UsageError.missingAuthFile
        }
        let data: Data
        do {
            data = try Data(contentsOf: authFile)
        } catch {
            throw UsageError.missingAuthFile
        }
        struct AuthFile: Decodable {
            let tokens: Tokens?
            struct Tokens: Decodable {
                let accessToken: String?
                let accountId: String?
                enum CodingKeys: String, CodingKey {
                    case accessToken = "access_token"
                    case accountId = "account_id"
                }
            }
        }
        do {
            let auth = try JSONDecoder().decode(AuthFile.self, from: data)
            guard let accessToken = auth.tokens?.accessToken, !accessToken.isEmpty,
                  let accountId = auth.tokens?.accountId, !accountId.isEmpty else {
                throw UsageError.missingTokens
            }
            return CodexCredentials(accessToken: accessToken, accountId: accountId)
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.missingTokens
        }
    }
}
