import Foundation

struct ClaudeUsageResponse: Decodable {
    let limits: [ClaudeLimitEntry]?
    let fiveHour: ClaudeWindow?
    let sevenDay: ClaudeWindow?
    let sevenDayOpus: ClaudeWindow?

    enum CodingKeys: String, CodingKey {
        case limits
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
    }
}

struct ClaudeLimitEntry: Decodable {
    struct Scope: Decodable {
        struct Model: Decodable {
            let displayName: String?

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
            }
        }

        let model: Model?
    }

    let kind: String?
    let group: String?
    let percent: Double?
    let severity: String?
    let resetsAt: String?
    let scope: Scope?
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }
}

struct ClaudeWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

enum ClaudeLimits {
    static let sessionKind = "session"
    static let weeklyAllKind = "weekly_all"
    static let weeklyScopedKind = "weekly_scoped"

    static func buckets(from response: ClaudeUsageResponse, now: Date = Date()) -> [LimitBucket] {
        let entries = response.limits ?? []
        if entries.isEmpty {
            return fallbackBuckets(from: response, now: now)
        }
        return entries
            .compactMap { bucket(from: $0, now: now) }
            .sorted { rank($0.kind) < rank($1.kind) }
    }

    private static func bucket(from entry: ClaudeLimitEntry, now: Date) -> LimitBucket? {
        guard let percent = entry.percent else { return nil }
        let kind = self.kind(for: entry.kind)
        let resetAt = ISODate.parse(entry.resetsAt)
        return LimitBucket(
            provider: .claude,
            kind: kind,
            name: label(kind: entry.kind, scopeModel: entry.scope?.model?.displayName),
            usedPercent: clampPercent(percent),
            resetAt: resetAt,
            resetAfterSeconds: secondsUntil(resetAt, from: now),
            limitWindowSeconds: windowSeconds(for: entry.kind),
            reached: percent >= 100
        )
    }

    private static func fallbackBuckets(from response: ClaudeUsageResponse, now: Date) -> [LimitBucket] {
        let windows: [(String, ClaudeWindow?)] = [
            (sessionKind, response.fiveHour),
            (weeklyAllKind, response.sevenDay),
            (weeklyScopedKind, response.sevenDayOpus),
        ]
        return windows.compactMap { rawKind, window in
            guard let window, let utilization = window.utilization else { return nil }
            let resetAt = ISODate.parse(window.resetsAt)
            return LimitBucket(
                provider: .claude,
                kind: kind(for: rawKind),
                name: label(
                    kind: rawKind,
                    scopeModel: rawKind == weeklyScopedKind ? "Opus" : nil
                ),
                usedPercent: clampPercent(utilization),
                resetAt: resetAt,
                resetAfterSeconds: secondsUntil(resetAt, from: now),
                limitWindowSeconds: windowSeconds(for: rawKind),
                reached: utilization >= 100
            )
        }
    }

    static func label(kind: String?, scopeModel: String?) -> String {
        switch kind {
        case sessionKind:
            return "Current session"
        case weeklyAllKind:
            return "All models"
        case weeklyScopedKind:
            guard let scopeModel, !scopeModel.isEmpty else { return "Pinned model" }
            return scopeModel
        default:
            guard let kind, !kind.isEmpty else { return "Limit" }
            return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func relabeled(_ bucket: LimitBucket) -> LimitBucket {
        guard bucket.provider == .claude else { return bucket }
        let nextName: String
        switch bucket.kind {
        case .session:
            nextName = label(kind: sessionKind, scopeModel: nil)
        case .weeklyAll:
            nextName = label(kind: weeklyAllKind, scopeModel: nil)
        case .weeklyScoped:
            nextName = label(kind: weeklyScopedKind, scopeModel: scopedModel(fromStoredName: bucket.name))
        default:
            return bucket
        }
        guard nextName != bucket.name else { return bucket }
        return LimitBucket(
            provider: bucket.provider,
            kind: bucket.kind,
            name: nextName,
            usedPercent: bucket.usedPercent,
            resetAt: bucket.resetAt,
            resetAfterSeconds: bucket.resetAfterSeconds,
            limitWindowSeconds: bucket.limitWindowSeconds,
            reached: bucket.reached,
            detail: bucket.detail
        )
    }

    private static func scopedModel(fromStoredName name: String) -> String? {
        var remainder = name
        for prefix in ["Week · ", "Week • "] where remainder.hasPrefix(prefix) {
            remainder = String(remainder.dropFirst(prefix.count))
        }
        if remainder.isEmpty { return nil }
        if remainder.compare("pinned model", options: .caseInsensitive) == .orderedSame {
            return nil
        }
        return remainder
    }

    private static func kind(for rawKind: String?) -> LimitBucket.Kind {
        switch rawKind {
        case sessionKind: return .session
        case weeklyAllKind: return .weeklyAll
        case weeklyScopedKind: return .weeklyScoped
        default: return .other
        }
    }

    private static func windowSeconds(for rawKind: String?) -> Int? {
        switch rawKind {
        case sessionKind: return 5 * 60 * 60
        case weeklyAllKind, weeklyScopedKind: return 7 * 24 * 60 * 60
        default: return nil
        }
    }

    private static func rank(_ kind: LimitBucket.Kind) -> Int {
        switch kind {
        case .session: return 0
        case .weeklyAll: return 1
        case .weeklyScoped: return 2
        default: return 3
        }
    }

    private static func clampPercent(_ value: Double) -> Int {
        Int(max(0, min(100, value.rounded())))
    }

    private static func secondsUntil(_ date: Date?, from now: Date) -> Int? {
        guard let date else { return nil }
        return max(0, Int(date.timeIntervalSince(now).rounded()))
    }
}

enum ISODate {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }

        guard let dot = value.firstIndex(of: "."),
              let zoneStart = value[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" })
        else {
            return nil
        }
        return plain.date(from: String(value[..<dot]) + String(value[zoneStart...]))
    }
}
