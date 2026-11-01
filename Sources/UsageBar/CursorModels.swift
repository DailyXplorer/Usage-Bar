import Foundation

struct CursorUsageResponse: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let planUsage: CursorPlanUsage?
    let spendLimitUsage: CursorSpendLimitUsage?
    let enabled: Bool?

    enum CodingKeys: String, CodingKey {
        case billingCycleStart, billingCycleEnd, planUsage, spendLimitUsage, enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        billingCycleStart = container.cursorTimestampText(forKey: .billingCycleStart)
        billingCycleEnd = container.cursorTimestampText(forKey: .billingCycleEnd)
        planUsage = try? container.decodeIfPresent(CursorPlanUsage.self, forKey: .planUsage)
        spendLimitUsage = try? container.decodeIfPresent(CursorSpendLimitUsage.self, forKey: .spendLimitUsage)
        enabled = container.cursorBool(forKey: .enabled)
    }
}

struct CursorPlanUsage: Decodable {
    let autoPercentUsed: Double?
    let cursorModelsPercentUsed: Double?
    let apiPercentUsed: Double?
    let totalPercentUsed: Double?

    enum CodingKeys: String, CodingKey {
        case autoPercentUsed, cursorModelsPercentUsed, apiPercentUsed, totalPercentUsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoPercentUsed = container.cursorNumber(forKey: .autoPercentUsed)
        cursorModelsPercentUsed = container.cursorNumber(forKey: .cursorModelsPercentUsed)
        apiPercentUsed = container.cursorNumber(forKey: .apiPercentUsed)
        totalPercentUsed = container.cursorNumber(forKey: .totalPercentUsed)
    }

    var modelsPercentUsed: Double? {
        autoPercentUsed ?? cursorModelsPercentUsed
    }
}

struct CursorSpendLimitUsage: Decodable {
    let individualLimit: Double?
    let individualUsed: Double?

    enum CodingKeys: String, CodingKey {
        case individualLimit, individualUsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        individualLimit = container.cursorNumber(forKey: .individualLimit)
        individualUsed = container.cursorNumber(forKey: .individualUsed)
    }
}

struct CursorSandUsageStatus: Decodable {
    let currentPeriodStart: String?
    let nextResetTimestampUtc: String?
    let usagePercent: Double?
    let hasNonZeroIncludedLimit: Bool?
    let includedLimitZero: Bool?
    let usesPooledEnterpriseAllowance: Bool?
    let isUnified: Bool?
    let billingBrand: String?
    let cursorPlanName: String?
    let grokPlanLabel: String?
    let unifyPendingMerge: PendingMerge?

    struct PendingMerge: Decodable {
        let state: String?

        enum CodingKeys: String, CodingKey {
            case state
        }

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            state = container.flatMap { CursorEnum.value(in: $0, forKey: .state, prefix: "UNIFY_PENDING_MERGE_STATE_") }
        }
    }

    enum CodingKeys: String, CodingKey {
        case currentPeriodStart, nextResetTimestampUtc, usagePercent
        case hasNonZeroIncludedLimit, includedLimitZero, usesPooledEnterpriseAllowance
        case isUnified, billingBrand, cursorPlanName, grokPlanLabel, unifyPendingMerge
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentPeriodStart = container.cursorTimestampText(forKey: .currentPeriodStart)
        nextResetTimestampUtc = container.cursorTimestampText(forKey: .nextResetTimestampUtc)
        usagePercent = container.cursorNumber(forKey: .usagePercent)
        hasNonZeroIncludedLimit = container.cursorBool(forKey: .hasNonZeroIncludedLimit)
        includedLimitZero = container.cursorBool(forKey: .includedLimitZero)
        usesPooledEnterpriseAllowance = container.cursorBool(forKey: .usesPooledEnterpriseAllowance)
        isUnified = container.cursorBool(forKey: .isUnified)
        billingBrand = CursorEnum.value(in: container, forKey: .billingBrand, prefix: "SAND_BILLING_BRAND_")
        cursorPlanName = container.cursorText(forKey: .cursorPlanName)
        grokPlanLabel = container.cursorText(forKey: .grokPlanLabel)
        unifyPendingMerge = try? container.decodeIfPresent(PendingMerge.self, forKey: .unifyPendingMerge)
    }

    var isPendingMerge: Bool {
        isUnified != true && unifyPendingMerge != nil
    }
}

struct CursorPlanInfoResponse: Decodable {
    struct PlanInfo: Decodable {
        let planName: String?
        let includedUsagePeriod: String?
        let includedUsageResetsAt: String?

        enum CodingKeys: String, CodingKey {
            case planName, includedUsagePeriod, includedUsageResetsAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            planName = container.cursorText(forKey: .planName)
            includedUsagePeriod = CursorEnum.value(
                in: container,
                forKey: .includedUsagePeriod,
                prefix: "INCLUDED_USAGE_PERIOD_"
            )
            includedUsageResetsAt = container.cursorTimestampText(forKey: .includedUsageResetsAt)
        }
    }

    let planInfo: PlanInfo?

    enum CodingKeys: String, CodingKey {
        case planInfo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planInfo = try? container.decodeIfPresent(PlanInfo.self, forKey: .planInfo)
    }

    var weeklyResetAt: Date? {
        guard planInfo?.includedUsagePeriod == "WEEKLY" else { return nil }
        return CursorTimestamp.parse(planInfo?.includedUsageResetsAt)
    }
}

struct CursorUsageSnapshot {
    var period: CursorUsageResponse
    var sand: CursorSandUsageStatus?
    var planInfo: CursorPlanInfoResponse?
    var membershipType: String?
}

struct CursorLayout {
    let buckets: [LimitBucket]
    let plan: String?
    let notice: String?
}

enum CursorLimits {
    static let weeklyUsageDisplayName = "Weekly usage"
    static let additionalUsageDisplayName = "Additional usage"
    static let grokBotDisplayName = "Grok Bot"
    static let weekSeconds = 7 * 24 * 60 * 60
    static let accountMergeNotice = "Account merge in progress. Usage appears once Cursor finishes it."

    static func layout(for snapshot: CursorUsageSnapshot, now: Date = Date()) -> CursorLayout {
        if let sand = snapshot.sand, sand.isUnified == true {
            return unifiedLayout(period: snapshot.period, sand: sand, fallbackPlan: snapshot.membershipType, now: now)
        }
        var buckets = legacyBuckets(from: snapshot.period, weeklyResetAt: snapshot.planInfo?.weeklyResetAt, now: now)
        let pendingMerge = snapshot.sand?.isPendingMerge == true
        if !pendingMerge, let grokBot = separateGrokBotBucket(from: snapshot.sand, now: now) {
            buckets.append(grokBot)
        }
        return CursorLayout(
            buckets: buckets,
            plan: snapshot.membershipType ?? snapshot.planInfo?.planInfo?.planName,
            notice: pendingMerge ? accountMergeNotice : nil
        )
    }

    static func menuBarBucket(in buckets: [LimitBucket]) -> LimitBucket? {
        buckets.first { $0.provider == .cursor && $0.kind == .weekly }
            ?? buckets.first { $0.provider == .cursor && $0.kind == .cursorModels }
    }

    static func menuBarAccessibilityText(for bucket: LimitBucket) -> String {
        let window = bucket.kind == .weekly ? "weekly usage" : "models"
        return "Cursor \(window), \(bucket.remainingPercent) percent left"
    }

    private static func unifiedLayout(
        period: CursorUsageResponse,
        sand: CursorSandUsageStatus,
        fallbackPlan: String?,
        now: Date
    ) -> CursorLayout {
        var buckets: [LimitBucket] = []
        if sand.usesPooledEnterpriseAllowance != true, let used = sand.usagePercent {
            let resetAt = CursorTimestamp.parse(sand.nextResetTimestampUtc)
            buckets.append(
                bucket(
                    kind: .weekly,
                    name: weeklyUsageDisplayName,
                    used: used,
                    resetAt: resetAt,
                    windowSeconds: windowSeconds(from: sand.currentPeriodStart, to: resetAt) ?? weekSeconds,
                    now: now
                )
            )
        }
        if let additional = additionalUsageBucket(from: period, now: now) {
            buckets.append(additional)
        }
        return CursorLayout(buckets: buckets, plan: sand.cursorPlanName ?? fallbackPlan, notice: nil)
    }

    private static func legacyBuckets(
        from response: CursorUsageResponse,
        weeklyResetAt: Date?,
        now: Date
    ) -> [LimitBucket] {
        guard response.enabled != false, let plan = response.planUsage else { return [] }
        let resetAt: Date?
        let window: Int?
        if let weeklyResetAt {
            resetAt = weeklyResetAt
            window = weekSeconds
        } else {
            resetAt = CursorTimestamp.parse(response.billingCycleEnd)
            window = windowSeconds(from: response.billingCycleStart, to: resetAt)
        }
        var result: [LimitBucket] = []
        if let used = plan.modelsPercentUsed {
            result.append(
                bucket(kind: .cursorModels, name: "Cursor Models", used: used, resetAt: resetAt, windowSeconds: window, now: now)
            )
        }
        if let used = plan.apiPercentUsed {
            result.append(
                bucket(kind: .otherModels, name: "Other Models", used: used, resetAt: resetAt, windowSeconds: window, now: now)
            )
        }
        return result
    }

    private static func separateGrokBotBucket(from status: CursorSandUsageStatus?, now: Date) -> LimitBucket? {
        guard let status,
              status.usesPooledEnterpriseAllowance != true,
              status.hasNonZeroIncludedLimit == true,
              status.includedLimitZero != true,
              let used = status.usagePercent
        else {
            return nil
        }
        let resetAt = CursorTimestamp.parse(status.nextResetTimestampUtc)
        return bucket(
            kind: .grokBot,
            name: grokBotDisplayName,
            used: used,
            resetAt: resetAt,
            windowSeconds: windowSeconds(from: status.currentPeriodStart, to: resetAt) ?? weekSeconds,
            now: now
        )
    }

    private static func additionalUsageBucket(from response: CursorUsageResponse, now: Date) -> LimitBucket? {
        guard let spend = response.spendLimitUsage,
              let limitCents = spend.individualLimit, limitCents > 0
        else {
            return nil
        }
        let usedCents = max(0, spend.individualUsed ?? 0)
        let resetAt = CursorTimestamp.parse(response.billingCycleEnd)
        return bucket(
            kind: .spendLimit,
            name: additionalUsageDisplayName,
            used: usedCents / limitCents * 100,
            resetAt: resetAt,
            windowSeconds: windowSeconds(from: response.billingCycleStart, to: resetAt),
            now: now,
            detail: "\(dollars(cents: usedCents)) / \(dollars(cents: limitCents))"
        )
    }

    static func dollars(cents: Double) -> String {
        String(format: "$%.2f", cents / 100)
    }

    private static func bucket(
        kind: LimitBucket.Kind,
        name: String,
        used: Double,
        resetAt: Date?,
        windowSeconds: Int?,
        now: Date,
        detail: String? = nil
    ) -> LimitBucket {
        let usedPercent = clampPercent(used)
        return LimitBucket(
            provider: .cursor,
            kind: kind,
            name: name,
            usedPercent: usedPercent,
            resetAt: resetAt,
            resetAfterSeconds: resetAt.map { max(0, Int($0.timeIntervalSince(now).rounded())) },
            limitWindowSeconds: windowSeconds,
            reached: usedPercent >= 100,
            detail: detail
        )
    }

    private static func windowSeconds(from start: String?, to resetAt: Date?) -> Int? {
        guard let startAt = CursorTimestamp.parse(start), let resetAt, resetAt > startAt else { return nil }
        return Int(resetAt.timeIntervalSince(startAt).rounded())
    }

    private static func clampPercent(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(max(0, min(100, value.rounded())))
    }
}

enum CursorTimestamp {
    private static let earliest = Date(timeIntervalSince1970: 946_684_800)
    private static let latest = Date(timeIntervalSince1970: 4_102_444_800)

    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let date: Date?
        if let number = Double(value), number.isFinite {
            let seconds = abs(number) >= 100_000_000_000 ? number / 1_000 : number
            date = Date(timeIntervalSince1970: seconds)
        } else {
            date = ISODate.parse(value)
        }
        guard let date, date >= earliest, date <= latest else { return nil }
        return date
    }
}

enum CursorEnum {
    static func value<Key: CodingKey>(
        in container: KeyedDecodingContainer<Key>,
        forKey key: Key,
        prefix: String
    ) -> String? {
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        let upper = raw.trimmingCharacters(in: .whitespaces).uppercased()
        let value = upper.hasPrefix(prefix) ? String(upper.dropFirst(prefix.count)) : upper
        return value.isEmpty ? nil : value
    }
}

private extension KeyedDecodingContainer {
    func cursorNumber(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value.isFinite ? value : nil
        }
        if let value = try? decodeIfPresent(String.self, forKey: key),
           let number = Double(value), number.isFinite {
            return number
        }
        return nil
    }

    func cursorBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        return nil
    }

    func cursorText(forKey key: Key) -> String? {
        guard let value = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func cursorTimestampText(forKey key: Key) -> String? {
        if let value = cursorText(forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite,
           abs(value) < 1e15 {
            return String(Int64(value))
        }
        return nil
    }
}
