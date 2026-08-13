import Foundation

struct CursorUsageResponse: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let planUsage: CursorPlanUsage?
    let enabled: Bool?

    enum CodingKeys: String, CodingKey {
        case billingCycleStart, billingCycleEnd, planUsage, enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        billingCycleStart = Self.string(in: container, for: .billingCycleStart)
        billingCycleEnd = Self.string(in: container, for: .billingCycleEnd)
        planUsage = try container.decodeIfPresent(CursorPlanUsage.self, forKey: .planUsage)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
    }

    private static func string(
        in container: KeyedDecodingContainer<CodingKeys>,
        for key: CodingKeys
    ) -> String? {
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            return String(Int(value))
        }
        return nil
    }
}

struct CursorPlanUsage: Decodable {
    let autoPercentUsed: Double?
    let cursorModelsPercentUsed: Double?
    let apiPercentUsed: Double?
    let totalPercentUsed: Double?

    var modelsPercentUsed: Double? {
        autoPercentUsed ?? cursorModelsPercentUsed
    }
}

enum CursorLimits {
    static let modelsDetail = "Includes Cursor Grok and Composer"
    static let otherDetail = "Third-party models billed at API rates"

    static func buckets(from response: CursorUsageResponse, now: Date = Date()) -> [LimitBucket] {
        guard response.enabled != false, let plan = response.planUsage else { return [] }

        let resetAt = CursorTimestamp.parse(response.billingCycleEnd)
        let startAt = CursorTimestamp.parse(response.billingCycleStart)
        let windowSeconds: Int?
        if let startAt, let resetAt {
            windowSeconds = max(0, Int(resetAt.timeIntervalSince(startAt).rounded()))
        } else {
            windowSeconds = nil
        }
        let resetAfter = secondsUntil(resetAt, from: now)

        var result: [LimitBucket] = []
        if let used = plan.modelsPercentUsed {
            result.append(
                bucket(
                    kind: .cursorModels,
                    name: "Cursor Models",
                    detail: modelsDetail,
                    used: used,
                    resetAt: resetAt,
                    resetAfterSeconds: resetAfter,
                    limitWindowSeconds: windowSeconds
                )
            )
        }
        if let used = plan.apiPercentUsed {
            result.append(
                bucket(
                    kind: .otherModels,
                    name: "Other Models",
                    detail: otherDetail,
                    used: used,
                    resetAt: resetAt,
                    resetAfterSeconds: resetAfter,
                    limitWindowSeconds: windowSeconds
                )
            )
        }
        return result
    }

    private static func bucket(
        kind: LimitBucket.Kind,
        name: String,
        detail: String,
        used: Double,
        resetAt: Date?,
        resetAfterSeconds: Int?,
        limitWindowSeconds: Int?
    ) -> LimitBucket {
        let usedPercent = clampPercent(used)
        return LimitBucket(
            provider: .cursor,
            kind: kind,
            name: name,
            usedPercent: usedPercent,
            resetAt: resetAt,
            resetAfterSeconds: resetAfterSeconds,
            limitWindowSeconds: limitWindowSeconds,
            reached: usedPercent >= 100,
            detail: detail
        )
    }

    private static func clampPercent(_ value: Double) -> Int {
        Int(max(0, min(100, value.rounded())))
    }

    private static func secondsUntil(_ date: Date?, from now: Date) -> Int? {
        guard let date else { return nil }
        return max(0, Int(date.timeIntervalSince(now).rounded()))
    }
}

enum CursorTimestamp {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let number = Double(value), number.isFinite {
            let seconds = abs(number) >= 100_000_000_000 ? number / 1_000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        return ISODate.parse(value)
    }
}
