import Foundation

struct OpenCodeUsageResponse: Decodable {
    struct Usage: Decodable {
        let rolling: OpenCodeWindow?
        let weekly: OpenCodeWindow?
        let monthly: OpenCodeWindow?
    }

    let usage: Usage
}

struct OpenCodeWindow: Decodable {
    let status: String?
    let percent: Double?
    let resetsAt: String?
}

enum OpenCodeLimits {
    static let planName = "Go"
    static let rateLimitedStatus = "rate-limited"
    static let rollingDisplayName = "Current session"
    static let weeklyDisplayName = "Weekly"
    static let monthlyDisplayName = "Monthly"
    static let rollingWindowSeconds = 5 * 60 * 60
    static let weeklyWindowSeconds = 7 * 24 * 60 * 60
    static let monthlyWindowSeconds = 30 * 24 * 60 * 60

    static func buckets(from response: OpenCodeUsageResponse, now: Date = Date()) -> [LimitBucket] {
        let windows: [(LimitBucket.Kind, String, Int, OpenCodeWindow?)] = [
            (.rolling, rollingDisplayName, rollingWindowSeconds, response.usage.rolling),
            (.weekly, weeklyDisplayName, weeklyWindowSeconds, response.usage.weekly),
            (.monthly, monthlyDisplayName, monthlyWindowSeconds, response.usage.monthly),
        ]
        return windows.compactMap { kind, name, windowSeconds, window in
            bucket(kind: kind, name: name, windowSeconds: windowSeconds, window: window, now: now)
        }
    }

    private static func bucket(
        kind: LimitBucket.Kind,
        name: String,
        windowSeconds: Int,
        window: OpenCodeWindow?,
        now: Date
    ) -> LimitBucket? {
        guard let window, let percent = window.percent else { return nil }
        let reached = window.status == rateLimitedStatus || percent >= 100
        let usedPercent = reached ? 100 : clampPercent(percent)
        let resetAt = ISODate.parse(window.resetsAt)
        return LimitBucket(
            provider: .opencode,
            kind: kind,
            name: name,
            usedPercent: usedPercent,
            resetAt: resetAt,
            resetAfterSeconds: secondsUntil(resetAt, from: now),
            limitWindowSeconds: windowSeconds,
            reached: reached
        )
    }

    static func relabeled(_ bucket: LimitBucket) -> LimitBucket {
        guard bucket.provider == .opencode else { return bucket }
        let nextName: String
        switch bucket.kind {
        case .rolling:
            nextName = rollingDisplayName
        case .weekly:
            nextName = weeklyDisplayName
        case .monthly:
            nextName = monthlyDisplayName
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

    private static func clampPercent(_ value: Double) -> Int {
        Int(max(0, min(100, value.rounded(.down))))
    }

    private static func secondsUntil(_ date: Date?, from now: Date) -> Int? {
        guard let date else { return nil }
        return max(0, Int(date.timeIntervalSince(now).rounded()))
    }
}
