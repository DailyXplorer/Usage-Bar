import Foundation

struct CodexCredentials {
    let accessToken: String
    let accountId: String
}

enum UsageError: LocalizedError {
    case missingAuthFile
    case missingTokens
    case signInExpired
    case forbidden
    case network(String)
    case throttled(retryAfter: Date?)
    case server
    case httpStatus(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingAuthFile:
            return "No Codex sign-in found. Run `codex` and sign in."
        case .missingTokens:
            return "Codex is not signed in with ChatGPT. Run `codex` and sign in."
        case .signInExpired:
            return "Codex sign-in expired. Open Codex to renew it."
        case .forbidden:
            return "This Codex sign-in cannot read usage. Run `codex` and sign in again."
        case .network:
            return "Could not reach ChatGPT. Check your internet connection."
        case .throttled:
            return "ChatGPT paused usage updates. Trying again later."
        case .server:
            return "ChatGPT is not responding right now. Trying again shortly."
        case .httpStatus:
            return "Could not read Codex usage right now. Trying again shortly."
        case .decoding:
            return "Codex sent usage data in an unknown format. Check for a Usage Bar update."
        }
    }
}

actor UsageService {
    static let defaultEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let endpoint: URL
    private let session: URLSession
    private let authFile: URL
    private let now: @Sendable () -> Date

    init(
        endpoint: URL = UsageService.defaultEndpoint,
        session: URLSession = ProviderSession.shared,
        authFile: URL = UsageService.authFile(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.session = session
        self.authFile = authFile
        self.now = now
    }

    static func authFile(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty {
            let expanded = (codexHome as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).appendingPathComponent("auth.json")
        }
        return home.appendingPathComponent(".codex/auth.json")
    }

    func fetchUsage() async throws -> UsageResponse {
        let credentials = try Self.loadCredentials(from: authFile, now: now())
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.network("invalid response")
        }
        guard http.statusCode == 200 else {
            switch http.statusCode {
            case 401:
                throw UsageError.signInExpired
            case 403:
                throw UsageError.forbidden
            case 429:
                throw UsageError.throttled(retryAfter: RetryAfter.date(from: http, now: now()))
            case 500...599:
                throw UsageError.server
            default:
                throw UsageError.httpStatus(http.statusCode)
            }
        }

        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw UsageError.decoding(error.localizedDescription)
        }
    }

    static func loadCredentials(from authFile: URL, now: Date = Date()) throws -> CodexCredentials {
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
        guard let auth = try? JSONDecoder().decode(AuthFile.self, from: data),
              let accessToken = auth.tokens?.accessToken, !accessToken.isEmpty,
              let accountId = auth.tokens?.accountId, !accountId.isEmpty else {
            throw UsageError.missingTokens
        }
        if let expiry = tokenExpiry(accessToken), expiry <= now {
            throw UsageError.signInExpired
        }
        return CodexCredentials(accessToken: accessToken, accountId: accountId)
    }

    static func tokenExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let exp: Double?
        switch object["exp"] {
        case let number as NSNumber:
            exp = number.doubleValue
        case let text as String:
            exp = Double(text)
        default:
            exp = nil
        }
        guard let exp, exp.isFinite, exp >= CodexNumbers.earliestEpoch, exp <= CodexNumbers.latestEpoch else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
