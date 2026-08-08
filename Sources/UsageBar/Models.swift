import Foundation

// MARK: - Codable models (mirror of the wham/usage response)

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

// MARK: - Display model

struct LimitBucket: Identifiable, Codable {
    enum Provider: String, Codable {
        case codex, claude
    }

    enum Kind: String, Codable {
        /// Fenêtres Codex.
        case primary, secondary
        /// Fenêtres Claude Code.
        case session, weeklyAll, weeklyScoped
        case other
    }

    /// Hors persistance : l'identité ne sert qu'au diffing SwiftUI, elle est
    /// régénérée à la relecture.
    private enum CodingKeys: String, CodingKey {
        case provider, kind, name, usedPercent, resetAt, resetAfterSeconds
        case limitWindowSeconds, reached
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

    /// Pourcentage restant (ce que l'utilisateur voit).
    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    /// Titre de carte. Les libellés Codex arrivent en minuscules (`weekly`, `5h`)
    /// et ceux de Claude sont déjà formatés — d'où la majuscule initiale seule,
    /// qui évite un « 5H » disgracieux.
    var displayName: String {
        guard let first = name.first else { return name }
        return String(first).uppercased() + name.dropFirst()
    }

    /// Recalcule le compte-à-rebours depuis `resetAt`, pour une barre relue
    /// depuis le disque après un délai.
    func recountingReset(from now: Date) -> LimitBucket {
        guard let resetAt else { return self }
        var copy = self
        copy.resetAfterSeconds = max(0, Int(resetAt.timeIntervalSince(now).rounded()))
        return copy
    }
}

// MARK: - Window labeling (same heuristic as the Codex CLI's TUI)

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
