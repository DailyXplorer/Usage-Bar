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

struct CursorSandUsageStatus: Decodable {
    let currentPeriodStart: String?
    let nextResetTimestampUtc: String?
    let usagePercent: Double?
    let hasNonZeroIncludedLimit: Bool?
    let includedLimitZero: Bool?
    let usesPooledEnterpriseAllowance: Bool?

    enum CodingKeys: String, CodingKey {
        case currentPeriodStart, nextResetTimestampUtc, usagePercent
        case hasNonZeroIncludedLimit, includedLimitZero, usesPooledEnterpriseAllowance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentPeriodStart = try container.decodeIfPresent(String.self, forKey: .currentPeriodStart)
        nextResetTimestampUtc = try container.decodeIfPresent(String.self, forKey: .nextResetTimestampUtc)
        usagePercent = Self.number(in: container, for: .usagePercent)
        hasNonZeroIncludedLimit = try container.decodeIfPresent(Bool.self, forKey: .hasNonZeroIncludedLimit)
        includedLimitZero = try container.decodeIfPresent(Bool.self, forKey: .includedLimitZero)
        usesPooledEnterpriseAllowance = try container.decodeIfPresent(
            Bool.self,
            forKey: .usesPooledEnterpriseAllowance
        )
    }

    private static func number(
        in container: KeyedDecodingContainer<CodingKeys>,
        for key: CodingKeys
    ) -> Double? {
        if let value = try? container.decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decode(String.self, forKey: key),
           let number = Double(value), number.isFinite {
            return number
        }
        return nil
    }
}

enum CursorLimits {
    static let grokBotDisplayName = "Grok Bot"
    static let grokBotWindowSeconds = 7 * 24 * 60 * 60

    static func buckets(
        from response: CursorUsageResponse,
        grokBot result: CursorGrokBotFetchResult,
        preserving previousBuckets: [LimitBucket],
        now: Date = Date()
    ) -> [LimitBucket] {
        updatingGrokBot(
            in: buckets(from: response, now: now),
            from: result,
            preserving: previousBuckets,
            now: now
        )
    }

    static func updatingGrokBot(
        in baseBuckets: [LimitBucket],
        from result: CursorGrokBotFetchResult,
        preserving previousBuckets: [LimitBucket],
        now: Date = Date()
    ) -> [LimitBucket] {
        var buckets = baseBuckets.filter { $0.kind != .grokBot }
        switch result {
        case .refreshed(let status):
            if let grokBot = grokBotBucket(from: status, now: now) {
                buckets.append(grokBot)
            }
        case .unavailable, .throttled:
            if let previousGrokBot = previousBuckets.first(where: { $0.kind == .grokBot }),
               previousGrokBot.resetAt.map({ $0 > now }) != false {
                buckets.append(previousGrokBot.recountingReset(from: now))
            }
        }
        return buckets
    }

    static func buckets(
        from response: CursorUsageResponse,
        grokBot: CursorSandUsageStatus? = nil,
        now: Date = Date()
    ) -> [LimitBucket] {
        var result: [LimitBucket] = []
        if response.enabled != false, let plan = response.planUsage {
            let resetAt = CursorTimestamp.parse(response.billingCycleEnd)
            let startAt = CursorTimestamp.parse(response.billingCycleStart)
            let windowSeconds: Int?
            if let startAt, let resetAt {
                windowSeconds = max(0, Int(resetAt.timeIntervalSince(startAt).rounded()))
            } else {
                windowSeconds = nil
            }
            let resetAfter = secondsUntil(resetAt, from: now)

            if let used = plan.modelsPercentUsed {
                result.append(
                    bucket(
                        kind: .cursorModels,
                        name: "Cursor Models",
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
                        used: used,
                        resetAt: resetAt,
                        resetAfterSeconds: resetAfter,
                        limitWindowSeconds: windowSeconds
                    )
                )
            }
        }
        if let grok = grokBotBucket(from: grokBot, now: now) {
            result.append(grok)
        }
        return result
    }

    private static func grokBotBucket(from status: CursorSandUsageStatus?, now: Date) -> LimitBucket? {
        guard let status else { return nil }
        guard status.usesPooledEnterpriseAllowance != true,
              status.hasNonZeroIncludedLimit != false,
              status.includedLimitZero != true,
              let used = status.usagePercent,
              used >= 0
        else {
            return nil
        }

        let resetAt = CursorTimestamp.parse(status.nextResetTimestampUtc)
        let startAt = CursorTimestamp.parse(status.currentPeriodStart)
        let windowSeconds: Int
        if let startAt, let resetAt, resetAt > startAt {
            windowSeconds = max(0, Int(resetAt.timeIntervalSince(startAt).rounded()))
        } else {
            windowSeconds = grokBotWindowSeconds
        }

        return bucket(
            kind: .grokBot,
            name: grokBotDisplayName,
            used: used,
            resetAt: resetAt,
            resetAfterSeconds: secondsUntil(resetAt, from: now),
            limitWindowSeconds: windowSeconds
        )
    }

    private static func bucket(
        kind: LimitBucket.Kind,
        name: String,
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
            reached: usedPercent >= 100
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
