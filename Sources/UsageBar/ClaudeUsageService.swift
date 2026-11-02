import Foundation

enum ClaudeUsageError: LocalizedError {
    case notSignedIn
    case tokenExpired
    case refreshInProgress
    case credentialsNotSaved
    case keychainUnavailable
    case forbidden(errorType: String?)
    case throttled(retryAfter: Date?)
    case offline
    case network
    case server
    case decoding

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "No Claude Code session. Run claude in Terminal, then /login."
        case .tokenExpired:
            return "Claude Code sign-in expired. Run claude in Terminal, then /login."
        case .refreshInProgress:
            return "Claude Code is renewing its sign-in. Trying again shortly."
        case .credentialsNotSaved:
            return "Could not save the renewed Claude Code sign-in. Run claude in Terminal once to renew it."
        case .keychainUnavailable:
            return "Could not read the Claude Code sign-in from the Keychain. Trying again shortly."
        case .forbidden(let errorType):
            let detail = errorType.map { " (\($0))" } ?? ""
            return "This Claude Code sign-in cannot read usage\(detail). Run claude in Terminal, then /login."
        case .throttled:
            return "Anthropic paused usage updates. Trying again later."
        case .offline, .network:
            return "Could not reach Anthropic. Check your internet connection."
        case .server:
            return "Anthropic is not responding right now. Trying again shortly."
        case .decoding:
            return "Claude sent usage data in an unknown format. Check for a Usage Bar update."
        }
    }

    var holdsAuthRejection: Bool {
        switch self {
        case .tokenExpired, .forbidden:
            return true
        default:
            return false
        }
    }

    init(transportError error: Error) {
        let unsent: Set<URLError.Code> = [
            .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
            .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
        ]
        if let code = (error as? URLError)?.code, unsent.contains(code) {
            self = .offline
        } else {
            self = .network
        }
    }
}

struct ClaudeFetch {
    enum Source: String {
        case usageEndpoint, claudeCode, quotaCheck
    }

    var usage: ClaudeUsageResponse?
    var source: Source
    var dataDate: Date
    var plan: String?
    var accountKey: String?
}

struct ClaudeCredentialProvider: Sendable {
    var usable: @Sendable () async throws -> ClaudeCredentials
    var afterRejection: @Sendable (ClaudeCredentials) async throws -> ClaudeCredentials
    var withoutRenewal: @Sendable () async throws -> ClaudeCredentials

    static func store(_ store: ClaudeCredentialStore) -> ClaudeCredentialProvider {
        ClaudeCredentialProvider(
            usable: { try await store.usableCredentials() },
            afterRejection: { try await store.credentialsAfterRejection(of: $0) },
            withoutRenewal: { try await store.currentCredentials() }
        )
    }
}

struct ClaudeCodeState {
    static let cacheLifetime: TimeInterval = 60 * 60

    var accountKey: String?
    var cachedUsage: ClaudeUsageResponse?
    var cachedAt: Date?

    static func read(from url: URL) -> ClaudeCodeState {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ClaudeCodeState()
        }
        let account = (root["oauthAccount"] as? [String: Any])?["accountUuid"] as? String
        var state = ClaudeCodeState(accountKey: account.flatMap(ClaudeAccountKey.make))
        guard let cache = root["cachedUsageUtilization"] as? [String: Any],
              let cacheAccount = cache["accountUuid"] as? String,
              cacheAccount == account,
              let fetchedAtMs = (cache["fetchedAtMs"] as? NSNumber)?.doubleValue,
              let utilization = cache["utilization"],
              JSONSerialization.isValidJSONObject(utilization),
              let body = try? JSONSerialization.data(withJSONObject: utilization),
              let usage = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: body) else {
            return state
        }
        state.cachedUsage = usage
        state.cachedAt = Date(timeIntervalSince1970: fetchedAtMs / 1000)
        return state
    }

    func usableCache(now: Date, newerThan ownDataDate: Date?) -> (usage: ClaudeUsageResponse, date: Date)? {
        guard let cachedUsage, let cachedAt,
              now.timeIntervalSince(cachedAt) <= Self.cacheLifetime,
              cachedAt <= now.addingTimeInterval(60),
              cachedAt > (ownDataDate ?? .distantPast) else {
            return nil
        }
        return (cachedUsage, min(cachedAt, now))
    }
}

enum ClaudeAccountKey {
    static func make(_ identifier: String) -> String? {
        CredentialFingerprint.make(identifier)
    }
}

enum AnthropicErrorEnvelope {
    static func type(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let type = error["type"] as? String else {
            return nil
        }
        return type
    }
}

enum ClaudeRequests {
    static let claudeCodeVersion = "2.1.316"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    static let quotaCheckModel = "claude-haiku-4-5-20251001"

    static func usage(accessToken: String) -> URLRequest {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-cli/\(claudeCodeVersion) (external, cli)", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func profile(accessToken: String) -> URLRequest {
        var request = URLRequest(url: profileURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("claude-code/\(claudeCodeVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func quotaCheck(accessToken: String) -> URLRequest {
        var request = URLRequest(url: messagesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-cli/\(claudeCodeVersion) (external, cli)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": quotaCheckModel,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "quota"]],
        ] as [String: Any])
        return request
    }
}

struct ClaudeProfilePlanCache: Codable {
    static let key = "claudeProfilePlan"
    static let lifetime: TimeInterval = 24 * 60 * 60
    static let retryAfterFailure: TimeInterval = 60 * 60

    var accountKey: String?
    var planName: String?
    var checkedAt: Date

    static func load(from defaults: UserDefaults) -> ClaudeProfilePlanCache? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ClaudeProfilePlanCache.self, from: $0) }
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func isCurrent(for accountKey: String?, at now: Date) -> Bool {
        guard self.accountKey == accountKey, checkedAt <= now else { return false }
        let lifetime = planName == nil ? Self.retryAfterFailure : Self.lifetime
        return now.timeIntervalSince(checkedAt) < lifetime
    }
}

actor ClaudeUsageService {
    private let credentials: ClaudeCredentialProvider
    private let session: URLSession
    private let claudeCodeFile: URL
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    init(
        credentials: ClaudeCredentialProvider = .store(ClaudeCredentialStore()),
        session: URLSession = ProviderSession.shared,
        claudeCodeFile: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json"),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.session = session
        self.claudeCodeFile = claudeCodeFile
        self.defaults = defaults
        self.now = now
    }

    func fetchUsage(ownDataDate: Date?) async throws -> ClaudeFetch {
        let local = ClaudeCodeState.read(from: claudeCodeFile)
        if let cached = local.usableCache(now: now(), newerThan: ownDataDate) {
            return ClaudeFetch(
                usage: cached.usage,
                source: .claudeCode,
                dataDate: cached.date,
                plan: await localPlan(accountKey: local.accountKey),
                accountKey: local.accountKey
            )
        }
        let (data, http, credentials) = try await send(ClaudeRequests.usage, endpoint: "usage")
        let accountKey = local.accountKey ?? Self.accountKey(for: credentials)
        let outcome = usage(from: data, http)
        if case .failure(let error) = outcome, error.holdsAuthRejection {
            throw error
        }
        let plan = await plan(for: credentials, accountKey: accountKey)
        return ClaudeFetch(
            usage: try outcome.get(),
            source: .usageEndpoint,
            dataDate: now(),
            plan: plan,
            accountKey: accountKey
        )
    }

    func fetchWhilePaused(ownDataDate: Date?, quotaCheck: Bool, scopedModelName: String?) async throws -> ClaudeFetch {
        let local = ClaudeCodeState.read(from: claudeCodeFile)
        if let cached = local.usableCache(now: now(), newerThan: ownDataDate) {
            return ClaudeFetch(
                usage: cached.usage,
                source: .claudeCode,
                dataDate: cached.date,
                plan: await localPlan(accountKey: local.accountKey),
                accountKey: local.accountKey
            )
        }
        guard quotaCheck else {
            let identity = await pausedIdentity(local: local)
            return ClaudeFetch(
                usage: nil,
                source: .claudeCode,
                dataDate: now(),
                plan: identity.plan,
                accountKey: identity.accountKey
            )
        }
        let (data, http, credentials) = try await send(ClaudeRequests.quotaCheck, endpoint: "quota-check")
        let accountKey = local.accountKey ?? Self.accountKey(for: credentials)
        guard let usage = ClaudeUnifiedHeaders.response(from: http.allHeaderFields, scopedModelName: scopedModelName) else {
            if http.statusCode == 200 {
                return ClaudeFetch(usage: nil, source: .quotaCheck, dataDate: now(), accountKey: accountKey)
            }
            throw error(for: http, data: data)
        }
        return ClaudeFetch(
            usage: usage,
            source: .quotaCheck,
            dataDate: now(),
            plan: await plan(for: credentials, accountKey: accountKey),
            accountKey: accountKey
        )
    }

    private func send(
        _ makeRequest: (String) -> URLRequest,
        endpoint: String
    ) async throws -> (Data, HTTPURLResponse, ClaudeCredentials) {
        var current = try await credentials.usable()
        var (data, http) = try await perform(makeRequest(current.accessToken), endpoint: endpoint)
        if http.statusCode == 401 {
            current = try await credentials.afterRejection(current)
            (data, http) = try await perform(makeRequest(current.accessToken), endpoint: endpoint)
            if http.statusCode == 401 {
                throw ClaudeUsageError.tokenExpired
            }
        }
        return (data, http, current)
    }

    private func perform(_ request: URLRequest, endpoint: String) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeUsageError(transportError: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeUsageError.network
        }
        ProviderLog.rejected(.claude, endpoint: endpoint, response: http, body: data)
        return (data, http)
    }

    private func pausedIdentity(local: ClaudeCodeState) async -> (plan: String?, accountKey: String?) {
        if let key = local.accountKey,
           let cache = ClaudeProfilePlanCache.load(from: defaults),
           cache.isCurrent(for: key, at: now()),
           let planName = cache.planName {
            return (planName, key)
        }
        guard let signedIn = try? await credentials.withoutRenewal() else {
            return (await localPlan(accountKey: local.accountKey), local.accountKey)
        }
        let accountKey = local.accountKey ?? Self.accountKey(for: signedIn)
        return (await plan(for: signedIn, accountKey: accountKey), accountKey)
    }

    private func localPlan(accountKey: String?, signedIn: ClaudeCredentials? = nil) async -> String? {
        if let cache = ClaudeProfilePlanCache.load(from: defaults),
           cache.accountKey == accountKey,
           let planName = cache.planName {
            return planName
        }
        if let signedIn {
            return signedIn.planToken
        }
        return try? await credentials.withoutRenewal().planToken
    }

    private func plan(for credentials: ClaudeCredentials, accountKey: String?) async -> String? {
        let date = now()
        let fallback = credentials.planToken
        if let cache = ClaudeProfilePlanCache.load(from: defaults), cache.isCurrent(for: accountKey, at: date) {
            return cache.planName ?? fallback
        }
        guard !credentials.isExpired(at: date) else {
            return await localPlan(accountKey: accountKey, signedIn: credentials)
        }
        var planName: String?
        if let (data, http) = try? await perform(ClaudeRequests.profile(accessToken: credentials.accessToken), endpoint: "profile"),
           http.statusCode == 200,
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let organization = root["organization"] as? [String: Any],
           let name = organization["plan_display_name"] as? String,
           !name.trimmingCharacters(in: .whitespaces).isEmpty {
            planName = name.trimmingCharacters(in: .whitespaces)
        }
        ClaudeProfilePlanCache(accountKey: accountKey, planName: planName, checkedAt: date).save(to: defaults)
        return planName ?? fallback
    }

    private static func accountKey(for credentials: ClaudeCredentials) -> String? {
        ClaudeAccountKey.make(credentials.refreshToken ?? credentials.accessToken)
    }

    private func usage(from data: Data, _ http: HTTPURLResponse) -> Result<ClaudeUsageResponse, ClaudeUsageError> {
        guard http.statusCode == 200 else {
            return .failure(error(for: http, data: data))
        }
        guard let usage = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data) else {
            return .failure(.decoding)
        }
        return .success(usage)
    }

    private func error(for http: HTTPURLResponse, data: Data) -> ClaudeUsageError {
        switch http.statusCode {
        case 401:
            return .tokenExpired
        case 403:
            guard let type = AnthropicErrorEnvelope.type(in: data) else {
                return .throttled(retryAfter: RetryAfter.date(from: http, now: now()))
            }
            return .forbidden(errorType: ProviderRejection.safeErrorType(type))
        case 429:
            return .throttled(retryAfter: RetryAfter.date(from: http, now: now()))
        default:
            return .server
        }
    }
}
