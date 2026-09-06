import Foundation

enum UsageEndpoint: String, Codable, CaseIterable {
    case codex, claude, cursor, cursorGrokBot, opencode, commandcode

    var provider: LimitBucket.Provider {
        switch self {
        case .codex: return .codex
        case .claude: return .claude
        case .cursor, .cursorGrokBot: return .cursor
        case .opencode: return .opencode
        case .commandcode: return .commandcode
        }
    }
}

struct UsageRefreshState: Codable {
    static let interval: TimeInterval = 3 * 60

    var lastSuccess: Date?
    var nextRefresh: Date?
    var lastError: String?
    var backoff = ThrottleBackoff()

    var nextEligible: Date {
        max(nextRefresh ?? .distantPast, backoff.blockedUntil ?? .distantPast)
    }

    func canStart(at now: Date, force: Bool) -> Bool {
        guard backoff.blockedUntil.map({ $0 > now }) != true else { return false }
        return force || nextEligible <= now
    }

    mutating func succeed(at now: Date) {
        lastSuccess = now
        lastError = nil
        nextRefresh = now.addingTimeInterval(Self.interval)
        backoff.reset()
    }

    mutating func fail(_ message: String, at now: Date) {
        lastError = message
        nextRefresh = now.addingTimeInterval(Self.interval)
    }

    mutating func throttle(_ message: String, retryAfter: Date?, at now: Date) {
        fail(message, at: now)
        backoff.recordThrottle(now: now, retryAfter: retryAfter)
    }
}

enum UsageFetchResult {
    case codex(UsageResponse)
    case claude(ClaudeUsageResponse, ClaudeCredentials)
    case cursor(CursorUsageResponse, CursorCredentials)
    case cursorGrokBot(CursorGrokBotFetchResult, CursorCredentials)
    case opencode(OpenCodeUsageResponse)
    case commandcode(CommandCodeUsageSnapshot)
}

struct UsageFetcher {
    var fetch: @Sendable (UsageEndpoint) async throws -> UsageFetchResult

    static var live: UsageFetcher {
        let codex = UsageService()
        let claude = ClaudeUsageService()
        let cursor = CursorUsageService()
        let opencode = OpenCodeUsageService()
        let commandcode = CommandCodeUsageService()
        return UsageFetcher { endpoint in
            switch endpoint {
            case .codex:
                return .codex(try await codex.fetchUsage())
            case .claude:
                let (usage, credentials) = try await claude.fetchUsage()
                return .claude(usage, credentials)
            case .cursor:
                let (usage, credentials) = try await cursor.fetchPeriodUsage()
                return .cursor(usage, credentials)
            case .cursorGrokBot:
                let (usage, credentials) = try await cursor.fetchGrokBotUsage()
                return .cursorGrokBot(usage, credentials)
            case .opencode:
                return .opencode(try await opencode.fetchUsage().usage)
            case .commandcode:
                return .commandcode(try await commandcode.fetchUsage().usage)
            }
        }
    }
}
