import Foundation

struct OpenCodeUsageResponse: Decodable {
    struct Usage: Decodable {
        let rolling: OpenCodeWindow?
        let weekly: OpenCodeWindow?
        let monthly: OpenCodeWindow?

        enum CodingKeys: String, CodingKey {
            case rolling, weekly, monthly
        }

        init(rolling: OpenCodeWindow? = nil, weekly: OpenCodeWindow? = nil, monthly: OpenCodeWindow? = nil) {
            self.rolling = rolling
            self.weekly = weekly
            self.monthly = monthly
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rolling = try? container.decodeIfPresent(OpenCodeWindow.self, forKey: .rolling)
            weekly = try? container.decodeIfPresent(OpenCodeWindow.self, forKey: .weekly)
            monthly = try? container.decodeIfPresent(OpenCodeWindow.self, forKey: .monthly)
        }
    }

    let usage: Usage

    enum CodingKeys: String, CodingKey {
        case usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usage = (try? container.decodeIfPresent(Usage.self, forKey: .usage)) ?? Usage()
    }
}

struct OpenCodeWindow: Decodable {
    let status: String?
    let percent: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case status, percent, resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        if let value = try? container.decodeIfPresent(Double.self, forKey: .percent) {
            percent = value.isFinite ? value : nil
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .percent),
                  let value = Double(text), value.isFinite {
            percent = value
        } else {
            percent = nil
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: .resetsAt) {
            resetsAt = text
        } else if let number = try? container.decodeIfPresent(Double.self, forKey: .resetsAt),
                  number.isFinite, number > 0, number < 1e14 {
            let seconds = number >= 1_000_000_000_000 ? number / 1_000 : number
            resetsAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
        } else {
            resetsAt = nil
        }
    }
}

enum OpenCodeLimits {
    static let planName = "Go"
    static let rateLimitedStatus = "rate-limited"
    static let rollingDisplayName = WindowLabels.currentSession
    static let weeklyDisplayName = WindowLabels.weeklyLimit
    static let monthlyDisplayName = WindowLabels.monthlyLimit
    static let rollingWindowSeconds = 5 * 60 * 60
    static let weeklyWindowSeconds = 7 * 24 * 60 * 60
    static let monthlyWindowSeconds = 30 * 24 * 60 * 60

    static func plan(for buckets: [LimitBucket]) -> String? {
        buckets.isEmpty ? nil : planName
    }

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
            scope: bucket.scope,
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
