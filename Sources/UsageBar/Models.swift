import Foundation

struct UsageResponse: Decodable {
    let planType: String?
    let rateLimit: RateLimitStatus?
    let rateLimitReachedType: String?
    let rateLimitResetCredits: RateLimitResetCreditsSummary?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case rateLimitReachedType = "rate_limit_reached_type"
        case rateLimitResetCredits = "rate_limit_reset_credits"
    }
}

struct RateLimitStatus: Decodable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: RateLimitWindow?
    let secondaryWindow: RateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct RateLimitWindow: Decodable {
    let usedPercent: Int?
    let limitWindowSeconds: Int?
    let resetAfterSeconds: Int?
    let resetAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }
}

struct RateLimitResetCreditsSummary: Decodable {
    let availableCount: Int?
    let applicableAvailableCount: Int?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case applicableAvailableCount = "applicable_available_count"
    }
}

struct LimitBucket: Identifiable, Codable {
    enum Provider: String, Codable, CaseIterable, Identifiable {
        case codex, claude, cursor, opencode

        var id: String { rawValue }

        var title: String {
            switch self {
            case .codex: return "Codex"
            case .claude: return "Claude"
            case .cursor: return "Cursor"
            case .opencode: return "OpenCode"
            }
        }
    }

    enum Kind: String, Codable {
        case primary, secondary
        case session, weeklyAll, weeklyScoped
        case cursorModels, otherModels
        case rolling, weekly, monthly
        case other
    }

    private enum CodingKeys: String, CodingKey {
        case provider, kind, name, usedPercent, resetAt, resetAfterSeconds
        case limitWindowSeconds, reached, detail
    }

    let id = UUID()
    var provider: Provider = .codex
    let kind: Kind
    let name: String
    let usedPercent: Int
    let resetAt: Date?
    var resetAfterSeconds: Int?
    let limitWindowSeconds: Int?
    let reached: Bool
    let detail: String?

    init(
        provider: Provider = .codex,
        kind: Kind,
        name: String,
        usedPercent: Int,
        resetAt: Date?,
        resetAfterSeconds: Int?,
        limitWindowSeconds: Int?,
        reached: Bool,
        detail: String? = nil
    ) {
        self.provider = provider
        self.kind = kind
        self.name = name
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.resetAfterSeconds = resetAfterSeconds
        self.limitWindowSeconds = limitWindowSeconds
        self.reached = reached
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(Provider.self, forKey: .provider) ?? .codex
        kind = try container.decode(Kind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        usedPercent = try container.decode(Int.self, forKey: .usedPercent)
        resetAt = try container.decodeIfPresent(Date.self, forKey: .resetAt)
        resetAfterSeconds = try container.decodeIfPresent(Int.self, forKey: .resetAfterSeconds)
        limitWindowSeconds = try container.decodeIfPresent(Int.self, forKey: .limitWindowSeconds)
        reached = try container.decode(Bool.self, forKey: .reached)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(usedPercent, forKey: .usedPercent)
        try container.encodeIfPresent(resetAt, forKey: .resetAt)
        try container.encodeIfPresent(resetAfterSeconds, forKey: .resetAfterSeconds)
        try container.encodeIfPresent(limitWindowSeconds, forKey: .limitWindowSeconds)
        try container.encode(reached, forKey: .reached)
        try container.encodeIfPresent(detail, forKey: .detail)
    }

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    var displayName: String {
        guard let first = name.first else { return name }
        return String(first).uppercased() + name.dropFirst()
    }

    func recountingReset(from now: Date) -> LimitBucket {
        guard let resetAt else { return self }
        var copy = self
        copy.resetAfterSeconds = max(0, Int(resetAt.timeIntervalSince(now).rounded()))
        return copy
    }
}

enum WindowLabels {
    static let minutesPerHour: Int = 60
    static let minutesPer5Hours: Int = 5 * minutesPerHour
    static let minutesPerDay: Int = 24 * minutesPerHour
    static let minutesPerWeek: Int = 7 * minutesPerDay
    static let minutesPerMonth: Int = 30 * minutesPerDay
    static let minutesPerYear: Int = 365 * minutesPerDay

    static func label(forWindowSeconds windowSeconds: Int?, isSecondary: Bool) -> String {
        guard let windowSeconds else {
            return fallbackLabel(isSecondary: isSecondary)
        }
        let minutes = windowSeconds / 60
        if isApproximate(minutes, expected: minutesPer5Hours) {
            return "5h"
        }
        if isApproximate(minutes, expected: minutesPerDay) {
            return "daily"
        }
        if isApproximate(minutes, expected: minutesPerWeek) {
            return "weekly"
        }
        if isApproximate(minutes, expected: minutesPerMonth) {
            return "monthly"
        }
        if isApproximate(minutes, expected: minutesPerYear) {
            return "annual"
        }
        return fallbackLabel(isSecondary: isSecondary)
    }

    static func fallbackLabel(isSecondary: Bool) -> String {
        isSecondary ? "secondary" : "primary"
    }

    private static func isApproximate(_ minutes: Int, expected: Int) -> Bool {
        let m = Double(minutes)
        let e = Double(expected)
        return m >= e * 0.95 && m <= e * 1.05
    }
}
