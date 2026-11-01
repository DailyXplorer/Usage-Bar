import Foundation

enum UsageEndpoint: String, Codable, CaseIterable {
    case codex, claude, claudeWhilePaused, cursor, opencode, commandcode

    var provider: LimitBucket.Provider {
        switch self {
        case .codex: return .codex
        case .claude, .claudeWhilePaused: return .claude
        case .cursor: return .cursor
        case .opencode: return .opencode
        case .commandcode: return .commandcode
        }
    }

    var policy: RefreshPolicy {
        switch self {
        case .codex:
            return RefreshPolicy(interval: 3 * 60)
        case .claude:
            return RefreshPolicy(interval: 15 * 60, manualGap: 60, refreshOnOpenAfter: 5 * 60)
        case .claudeWhilePaused:
            return RefreshPolicy(interval: 15 * 60, manualGap: nil, minimumGap: 15 * 60)
        case .cursor, .opencode, .commandcode:
            return RefreshPolicy(interval: 5 * 60)
        }
    }
}

struct RefreshPolicy: Equatable {
    static let networkRetry: TimeInterval = 60
    static let wakeRetry: TimeInterval = 15

    let interval: TimeInterval
    var manualGap: TimeInterval? = 0
    var refreshOnOpenAfter: TimeInterval? = nil
    var minimumGap: TimeInterval? = nil

    var staleAfter: TimeInterval {
        interval * 2
    }
}

struct UsageRefreshState: Codable {
    var lastSuccess: Date?
    var lastAttempt: Date?
    var nextRefresh: Date?
    var lastError: String?
    var backoff = ThrottleBackoff()

    func nextEligible(policy: RefreshPolicy) -> Date {
        let floor = policy.minimumGap.flatMap { gap in lastAttempt.map { $0.addingTimeInterval(gap) } }
        return [nextRefresh, backoff.blockedUntil, floor].compactMap { $0 }.max() ?? .distantPast
    }

    func isPaused(at now: Date) -> Bool {
        backoff.blockedUntil.map { $0 > now } == true
    }

    func canStart(at now: Date, force: Bool, policy: RefreshPolicy) -> Bool {
        guard !isPaused(at: now) else { return false }
        if nextEligible(policy: policy) <= now { return true }
        guard force, let gap = policy.manualGap else { return false }
        return lastAttempt.map { now.timeIntervalSince($0) >= gap || $0 > now } ?? true
    }

    func canStartOnOpen(at now: Date, policy: RefreshPolicy) -> Bool {
        guard !isPaused(at: now) else { return false }
        if nextEligible(policy: policy) <= now { return true }
        guard let age = policy.refreshOnOpenAfter, let gap = policy.manualGap else { return false }
        let dataIsOld = lastSuccess.map { now.timeIntervalSince($0) > age } ?? true
        let gapPassed = lastAttempt.map { now.timeIntervalSince($0) >= gap || $0 > now } ?? true
        return dataIsOld && gapPassed
    }

    mutating func begin(at now: Date) {
        lastAttempt = now
    }

    mutating func succeed(at now: Date, dataDate: Date? = nil, interval: TimeInterval, resetsBackoff: Bool = true) {
        lastSuccess = min(dataDate ?? now, now)
        lastError = nil
        nextRefresh = now.addingTimeInterval(interval)
        if resetsBackoff {
            backoff.reset()
        }
    }

    mutating func idle(at now: Date, interval: TimeInterval) {
        nextRefresh = now.addingTimeInterval(interval)
    }

    mutating func fail(_ message: String?, at now: Date, retryAfter delay: TimeInterval) {
        lastError = message
        nextRefresh = now.addingTimeInterval(delay)
    }

    mutating func throttle(_ message: String, retryAfter: Date?, at now: Date, interval: TimeInterval, scope: String? = nil) {
        backoff.recordThrottle(now: now, retryAfter: retryAfter, scope: scope)
        lastError = message
        nextRefresh = backoff.blockedUntil ?? now.addingTimeInterval(interval)
    }

    func restored(now: Date) -> UsageRefreshState {
        var copy = self
        copy.backoff = backoff.capped(now: now)
        if let nextRefresh, nextRefresh.timeIntervalSince(now) > ThrottleBackoff.maximumPause {
            copy.nextRefresh = now
        }
        if let lastAttempt, lastAttempt > now {
            copy.lastAttempt = now
        }
        return copy
    }
}

struct UsageFetchContext {
    var dataDate: Date?
    var claudeQuotaCheck = false
    var claudeScopedModelName: String?
}

enum UsageFetchResult {
    case codex(UsageResponse)
    case claude(ClaudeFetch)
    case cursor(CursorUsageSnapshot)
    case opencode(OpenCodeUsageResponse)
    case commandcode(CommandCodeUsageSnapshot)
}

struct UsageFetcher {
    var fetch: @Sendable (UsageEndpoint, UsageFetchContext) async throws -> UsageFetchResult

    init(fetch: @escaping @Sendable (UsageEndpoint, UsageFetchContext) async throws -> UsageFetchResult) {
        self.fetch = fetch
    }

    init(_ fetch: @escaping @Sendable (UsageEndpoint) async throws -> UsageFetchResult) {
        self.fetch = { endpoint, _ in try await fetch(endpoint) }
    }

    static var live: UsageFetcher {
        let codex = UsageService()
        let claude = ClaudeUsageService()
        let cursor = CursorUsageService()
        let opencode = OpenCodeUsageService()
        let commandcode = CommandCodeUsageService()
        return UsageFetcher { endpoint, context in
            switch endpoint {
            case .codex:
                return .codex(try await codex.fetchUsage())
            case .claude:
                return .claude(try await claude.fetchUsage(ownDataDate: context.dataDate))
            case .claudeWhilePaused:
                return .claude(try await claude.fetchWhilePaused(
                    ownDataDate: context.dataDate,
                    quotaCheck: context.claudeQuotaCheck,
                    scopedModelName: context.claudeScopedModelName
                ))
            case .cursor:
                return .cursor(try await cursor.fetchUsage())
            case .opencode:
                return .opencode(try await opencode.fetchUsage().usage)
            case .commandcode:
                return .commandcode(try await commandcode.fetchUsage().usage)
            }
        }
    }
}
