import Foundation

struct CommandCodeCredentials {
    let apiKey: String
}

enum CommandCodeUsageError: LocalizedError {
    case notSignedIn
    case invalidKey
    case throttled(retryAfter: Date?)
    case network(String)
    case httpStatus(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "No Command Code key. Run `cmd login` in your terminal."
        case .invalidKey:
            return "Command Code API key is invalid. Run `cmd login` again."
        case .throttled:
            return "Command Code usage endpoint is rate limited. Waiting before retrying."
        case .network(let message):
            return "Network error: \(message)"
        case .httpStatus(let code):
            return "Command Code returned HTTP \(code). Run `cmd login`."
        case .decoding(let message):
            return "Unreadable Command Code response: \(message)"
        }
    }
}

actor CommandCodeUsageService {
    static let defaultBaseURL = URL(string: "https://api.commandcode.ai")!
    private static let accountCacheLifetime: TimeInterval = 30 * 60
    private static let summaryFailureCooldown: TimeInterval = 3 * 60

    private let baseURL: URL
    private let session: URLSession
    private let now: () -> Date
    private let accountCacheLifetime: TimeInterval
    private var accountCache: CachedAccount?
    private var summaryContext: AccountContext?
    private var summaryBackoff = ThrottleBackoff()
    private var summaryFailureUntil: Date?
    private var fetchGeneration = 0

    init(
        baseURL: URL = CommandCodeUsageService.defaultBaseURL,
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init,
        accountCacheLifetime: TimeInterval = CommandCodeUsageService.accountCacheLifetime
    ) {
        self.baseURL = baseURL
        self.session = session
        self.now = now
        self.accountCacheLifetime = accountCacheLifetime
    }

    func fetchUsage(
        from files: [URL] = CommandCodeUsageService.authFileCandidates(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> (usage: CommandCodeUsageSnapshot, credentials: CommandCodeCredentials) {
        let generation = beginFetch()
        let credentials: CommandCodeCredentials
        do {
            credentials = try Self.loadCredentials(from: files, environment: environment)
        } catch {
            clearCaches(ifCurrent: generation)
            throw error
        }
        try Task.checkCancellation()
        clearCachesForChangedCredentials(credentials, generation: generation)

        do {
            let account = try await account(for: credentials, generation: generation)
            try Task.checkCancellation()
            let credits: CommandCodeCreditsResponse = try await get(
                path: "/alpha/billing/credits",
                token: credentials.apiKey,
                query: Self.query(orgId: account.context.orgId)
            )
            try Task.checkCancellation()
            let monthlyUsed = try await fetchSummary(
                for: account.context,
                token: credentials.apiKey,
                generation: generation
            )
            let snapshot = CommandCodeUsageSnapshot(
                planId: account.subscriptions.data?.planId,
                subscriptionStatus: account.subscriptions.data?.status,
                currentPeriodEnd: account.subscriptions.data?.currentPeriodEnd,
                credits: credits.credits,
                windowLimits: credits.windowLimits,
                monthlyUsed: monthlyUsed
            )
            return (snapshot, credentials)
        } catch CommandCodeUsageError.invalidKey {
            clearCaches(ifCurrent: generation)
            throw CommandCodeUsageError.invalidKey
        } catch {
            throw error
        }
    }

    nonisolated static func authFileCandidates(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [home.appendingPathComponent(".commandcode/auth.json")]
    }

    nonisolated static func loadCredentials(
        from files: [URL],
        environment: [String: String] = [:]
    ) throws -> CommandCodeCredentials {
        for name in ["COMMAND_CODE_API_KEY", "COMMANDCODE_API_KEY"] {
            if let key = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                return CommandCodeCredentials(apiKey: key)
            }
        }
        for file in files {
            guard FileManager.default.fileExists(atPath: file.path),
                  let data = try? Data(contentsOf: file),
                  let auth = try? JSONDecoder().decode(CommandCodeAuthFile.self, from: data),
                  let apiKey = auth.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !apiKey.isEmpty else {
                continue
            }
            return CommandCodeCredentials(apiKey: apiKey)
        }
        throw CommandCodeUsageError.notSignedIn
    }

    private func get<T: Decodable>(
        path: String,
        token: String,
        query: [URLQueryItem] = []
    ) async throws -> T {
        try Task.checkCancellation()
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(
            url: baseURL.appending(path: trimmed),
            resolvingAgainstBaseURL: false
        ) else {
            throw CommandCodeUsageError.network("invalid url")
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw CommandCodeUsageError.network("invalid url")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw CommandCodeUsageError.network(error.localizedDescription)
        }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw CommandCodeUsageError.network("invalid response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 {
                throw CommandCodeUsageError.invalidKey
            }
            if http.statusCode == 429 {
                throw CommandCodeUsageError.throttled(retryAfter: RetryAfter.date(from: http, now: now()))
            }
            throw CommandCodeUsageError.httpStatus(http.statusCode)
        }

        do {
            try Task.checkCancellation()
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw CommandCodeUsageError.decoding(error.localizedDescription)
        }
    }

    private func account(
        for credentials: CommandCodeCredentials,
        generation: Int
    ) async throws -> CachedAccount {
        let currentTime = now()
        if let accountCache,
           accountCache.context.apiKey == credentials.apiKey,
           accountCache.expiresAt > currentTime {
            return accountCache
        }

        let whoami: CommandCodeWhoamiResponse = try await get(
            path: "/alpha/whoami",
            token: credentials.apiKey
        )
        try Task.checkCancellation()
        let subscriptions: CommandCodeSubscriptionsResponse = try await get(
            path: "/alpha/billing/subscriptions",
            token: credentials.apiKey,
            query: Self.query(orgId: whoami.org?.id)
        )
        try Task.checkCancellation()

        let context = AccountContext(
            apiKey: credentials.apiKey,
            orgId: whoami.org?.id,
            currentPeriodStart: subscriptions.data?.currentPeriodStart,
            currentPeriodEnd: subscriptions.data?.currentPeriodEnd
        )
        let account = CachedAccount(
            context: context,
            subscriptions: subscriptions,
            expiresAt: accountCacheExpiry(
                currentPeriodEnd: subscriptions.data?.currentPeriodEnd,
                currentTime: currentTime
            )
        )
        guard generation == fetchGeneration else { return account }

        let contextChanged = accountCache?.context != context
        accountCache = account
        if contextChanged {
            summaryContext = context
            summaryBackoff.reset()
            summaryFailureUntil = nil
        }
        return account
    }

    private func fetchSummary(
        for context: AccountContext,
        token: String,
        generation: Int
    ) async throws -> Double? {
        guard shouldFetchSummary(for: context, generation: generation) else { return nil }
        do {
            let summary: CommandCodeSummaryResponse = try await get(
                path: "/alpha/usage/summary",
                token: token,
                query: Self.query(orgId: context.orgId, since: context.currentPeriodStart)
            )
            try Task.checkCancellation()
            recordSummarySuccess(for: context, generation: generation)
            return summary.totalMonthlyCredits
        } catch is CancellationError {
            throw CancellationError()
        } catch CommandCodeUsageError.throttled(let retryAfter) {
            recordSummaryThrottle(retryAfter, for: context, generation: generation)
            return nil
        } catch {
            recordSummaryFailure(for: context, generation: generation)
            return nil
        }
    }

    private func beginFetch() -> Int {
        fetchGeneration &+= 1
        return fetchGeneration
    }

    private func clearCachesForChangedCredentials(
        _ credentials: CommandCodeCredentials,
        generation: Int
    ) {
        guard generation == fetchGeneration else { return }
        guard accountCache?.context.apiKey != credentials.apiKey else { return }
        clearCaches()
    }

    private func clearCaches(ifCurrent generation: Int) {
        guard generation == fetchGeneration else { return }
        clearCaches()
    }

    private func clearCaches() {
        accountCache = nil
        summaryContext = nil
        summaryBackoff.reset()
        summaryFailureUntil = nil
    }

    private func accountCacheExpiry(
        currentPeriodEnd: String?,
        currentTime: Date
    ) -> Date {
        let ttlExpiry = currentTime.addingTimeInterval(accountCacheLifetime)
        guard let currentPeriodEnd,
              let periodEnd = ISODate.parse(currentPeriodEnd) else {
            return ttlExpiry
        }
        return min(ttlExpiry, periodEnd)
    }

    private func shouldFetchSummary(for context: AccountContext, generation: Int) -> Bool {
        guard generation == fetchGeneration, summaryContext == context else { return false }
        let currentTime = now()
        if let summaryFailureUntil, summaryFailureUntil > currentTime {
            return false
        }
        if let summaryBlockedUntil = summaryBackoff.blockedUntil,
           summaryBlockedUntil > currentTime {
            return false
        }
        return true
    }

    private func recordSummarySuccess(for context: AccountContext, generation: Int) {
        guard generation == fetchGeneration, summaryContext == context else { return }
        summaryBackoff.reset()
        summaryFailureUntil = nil
    }

    private func recordSummaryThrottle(
        _ retryAfter: Date?,
        for context: AccountContext,
        generation: Int
    ) {
        guard generation == fetchGeneration, summaryContext == context else { return }
        summaryBackoff.recordThrottle(now: now(), retryAfter: retryAfter)
    }

    private func recordSummaryFailure(for context: AccountContext, generation: Int) {
        guard generation == fetchGeneration, summaryContext == context else { return }
        let currentTime = now()
        summaryFailureUntil = max(
            summaryFailureUntil ?? .distantPast,
            currentTime.addingTimeInterval(Self.summaryFailureCooldown)
        )
    }

    private static func query(orgId: String?, since: String? = nil) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let orgId, !orgId.isEmpty {
            items.append(URLQueryItem(name: "orgId", value: orgId))
        }
        if let since, !since.isEmpty {
            items.append(URLQueryItem(name: "since", value: since))
        }
        return items
    }
}

private struct AccountContext: Equatable {
    let apiKey: String
    let orgId: String?
    let currentPeriodStart: String?
    let currentPeriodEnd: String?
}

private struct CachedAccount {
    let context: AccountContext
    let subscriptions: CommandCodeSubscriptionsResponse
    let expiresAt: Date
}

private struct CommandCodeAuthFile: Decodable {
    let apiKey: String?
}
