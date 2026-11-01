import Foundation

struct CommandCodeWhoamiResponse: Decodable {
    struct Org: Decodable {
        let id: String?
    }

    let org: Org?
    let orgLimits: [CommandCodeOrgLimit]

    private enum CodingKeys: String, CodingKey {
        case org, orgLimits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        org = try? container.decodeIfPresent(Org.self, forKey: .org)
        let entries = (try? container.decodeIfPresent([CommandCodeLenient<CommandCodeOrgLimit>].self, forKey: .orgLimits)) ?? nil
        orgLimits = entries?.compactMap(\.value) ?? []
    }
}

struct CommandCodeOrgLimit: Decodable, Equatable {
    let scope: String?
    let model: String?
    let modelLabel: String?
    let limit: Double
    let spent: Double
    let exceeded: Bool?
    let resetInterval: String?
    let resetAt: String?

    private enum CodingKeys: String, CodingKey {
        case scope, model, modelLabel, limit, spent, exceeded, resetInterval, resetAt
    }

    init(
        scope: String?,
        model: String? = nil,
        modelLabel: String? = nil,
        limit: Double,
        spent: Double,
        exceeded: Bool? = nil,
        resetInterval: String? = nil,
        resetAt: String? = nil
    ) {
        self.scope = scope
        self.model = model
        self.modelLabel = modelLabel
        self.limit = limit
        self.spent = spent
        self.exceeded = exceeded
        self.resetInterval = resetInterval
        self.resetAt = resetAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let limit = try container.decodeFlexibleDoubleIfPresent(forKey: .limit) else {
            throw DecodingError.keyNotFound(
                CodingKeys.limit,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing limit")
            )
        }
        self.limit = limit
        spent = try container.decodeFlexibleDoubleIfPresent(forKey: .spent) ?? 0
        scope = try? container.decodeIfPresent(String.self, forKey: .scope)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        modelLabel = try? container.decodeIfPresent(String.self, forKey: .modelLabel)
        exceeded = try container.decodeFlexibleBoolIfPresent(forKey: .exceeded)
        resetInterval = try? container.decodeIfPresent(String.self, forKey: .resetInterval)
        resetAt = container.decodeFlexibleDateTextIfPresent(forKey: .resetAt)
    }
}

struct CommandCodeLenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

struct CommandCodeSubscriptionsResponse: Decodable {
    struct Subscription: Decodable {
        let planId: String?
        let status: String?
        let currentPeriodStart: String?
        let currentPeriodEnd: String?

        private enum CodingKeys: String, CodingKey {
            case planId, status, currentPeriodStart, currentPeriodEnd
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            planId = try? container.decodeIfPresent(String.self, forKey: .planId)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            currentPeriodStart = container.decodeFlexibleDateTextIfPresent(forKey: .currentPeriodStart)
            currentPeriodEnd = container.decodeFlexibleDateTextIfPresent(forKey: .currentPeriodEnd)
        }
    }

    let data: Subscription?
}

struct CommandCodeCreditsResponse: Decodable {
    struct Credits: Decodable {
        let monthlyCredits: Double?
        let purchasedCredits: Double?
        let freeCredits: Double?
        let windowLimits: WindowLimits?

        private enum CodingKeys: String, CodingKey {
            case monthlyCredits, purchasedCredits, freeCredits, windowLimits
        }

        init(
            monthlyCredits: Double? = nil,
            purchasedCredits: Double? = nil,
            freeCredits: Double? = nil,
            windowLimits: WindowLimits? = nil
        ) {
            self.monthlyCredits = monthlyCredits
            self.purchasedCredits = purchasedCredits
            self.freeCredits = freeCredits
            self.windowLimits = windowLimits
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            monthlyCredits = try container.decodeFlexibleDoubleIfPresent(forKey: .monthlyCredits)
            purchasedCredits = try container.decodeFlexibleDoubleIfPresent(forKey: .purchasedCredits)
            freeCredits = try container.decodeFlexibleDoubleIfPresent(forKey: .freeCredits)
            windowLimits = try container.decodeIfPresent(WindowLimits.self, forKey: .windowLimits)
        }
    }

    struct WindowLimits: Decodable {
        let limited: Bool?
        let fiveHour: CommandCodeWindow?
        let weekly: CommandCodeWindow?
    }

    let credits: Credits?
    let windowLimits: WindowLimits?

    private enum CodingKeys: String, CodingKey {
        case credits, windowLimits
    }

    init(credits: Credits? = nil, windowLimits: WindowLimits? = nil) {
        self.credits = credits
        self.windowLimits = windowLimits ?? credits?.windowLimits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        credits = try container.decodeIfPresent(Credits.self, forKey: .credits)
        windowLimits = try container.decodeIfPresent(WindowLimits.self, forKey: .windowLimits)
            ?? credits?.windowLimits
    }
}

struct CommandCodeWindow: Decodable {
    let used: Double?
    let cap: Double?
    let exceeded: Bool?
    let resetAt: Double?

    private enum CodingKeys: String, CodingKey {
        case used, cap, exceeded, resetAt
    }

    init(used: Double?, cap: Double?, exceeded: Bool?, resetAt: Double?) {
        self.used = used
        self.cap = cap
        self.exceeded = exceeded
        self.resetAt = resetAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        used = try container.decodeFlexibleDoubleIfPresent(forKey: .used)
        cap = try container.decodeFlexibleDoubleIfPresent(forKey: .cap)
        exceeded = try container.decodeFlexibleBoolIfPresent(forKey: .exceeded)
        resetAt = try container.decodeFlexibleDoubleIfPresent(forKey: .resetAt)
    }
}

struct CommandCodeSummaryResponse: Decodable {
    let totalCost: Double?
    let totalMonthlyCredits: Double?

    private enum CodingKeys: String, CodingKey {
        case totalCost, totalMonthlyCredits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalCost = try container.decodeFlexibleDoubleIfPresent(forKey: .totalCost)
        totalMonthlyCredits = try container.decodeFlexibleDoubleIfPresent(forKey: .totalMonthlyCredits)
    }

    var spent: Double? {
        totalCost ?? totalMonthlyCredits
    }
}

struct CommandCodeUsageSnapshot {
    var planId: String?
    var subscriptionStatus: String?
    var currentPeriodEnd: String?
    var credits: CommandCodeCreditsResponse.Credits?
    var windowLimits: CommandCodeCreditsResponse.WindowLimits?
    var monthlyUsed: Double?
    var orgLimits: [CommandCodeOrgLimit] = []
}

enum CommandCodeLimits {
    static let rollingDisplayName = WindowLabels.currentSession
    static let weeklyDisplayName = WindowLabels.weeklyLimit
    static let monthlyDisplayName = WindowLabels.monthlyLimit
    static let rollingWindowSeconds = 5 * 60 * 60
    static let weeklyWindowSeconds = 7 * 24 * 60 * 60
    static let monthlyWindowSeconds = 30 * 24 * 60 * 60
    static let activeStatus = "active"

    private static let plans: [(id: String, name: String, monthlyCredits: Double)] = [
        ("individual-go", "Go", 10),
        ("individual-go-v1", "Go", 10),
        ("individual-goat", "GOAT", 70),
        ("individual-pro", "Pro", 30),
        ("individual-pro-v1", "Pro", 80),
        ("individual-provider", "Provider", 15),
        ("individual-max", "Max", 150),
        ("individual-ultra", "Ultra", 300),
        ("teams-pro", "Teams Pro", 40),
    ]

    private static let plansByLongestPrefix = plans.sorted { $0.id.count > $1.id.count }

    static func canonicalPlanId(from planId: String?) -> String? {
        guard let planId, !planId.isEmpty else { return nil }
        let key = planId.lowercased().replacingOccurrences(of: "_", with: "-")
        return plansByLongestPrefix.first(where: { key.hasPrefix($0.id) })?.id
    }

    static func displayName(for planId: String?) -> String? {
        guard let id = canonicalPlanId(from: planId) else { return nil }
        return plans.first(where: { $0.id == id })?.name
    }

    static func monthlyCredits(for planId: String?) -> Double? {
        guard let id = canonicalPlanId(from: planId) else { return nil }
        return plans.first(where: { $0.id == id })?.monthlyCredits
    }

    static func shouldHide(_ snapshot: CommandCodeUsageSnapshot) -> Bool {
        windowLimits(from: snapshot)?.limited == false && buckets(from: snapshot).isEmpty
    }

    static func buckets(from snapshot: CommandCodeUsageSnapshot, now: Date = Date()) -> [LimitBucket] {
        let windows = windowLimits(from: snapshot).flatMap { $0.limited == false ? nil : $0 }
        var result: [LimitBucket] = []
        if let bucket = windowBucket(
            kind: .rolling,
            name: rollingDisplayName,
            windowSeconds: rollingWindowSeconds,
            window: windows?.fiveHour,
            now: now
        ) {
            result.append(bucket)
        }
        if let bucket = windowBucket(
            kind: .weekly,
            name: weeklyDisplayName,
            windowSeconds: weeklyWindowSeconds,
            window: windows?.weekly,
            now: now
        ) {
            result.append(bucket)
        }
        if let bucket = monthlyBucket(from: snapshot, now: now) {
            result.append(bucket)
        }
        result += snapshot.orgLimits.enumerated().map { index, limit in
            orgLimitBucket(limit, index: index, now: now)
        }
        return result
    }

    static func relabeled(_ bucket: LimitBucket) -> LimitBucket {
        guard bucket.provider == .commandcode else { return bucket }
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

    private static func windowLimits(
        from snapshot: CommandCodeUsageSnapshot
    ) -> CommandCodeCreditsResponse.WindowLimits? {
        snapshot.windowLimits ?? snapshot.credits?.windowLimits
    }

    private static func windowBucket(
        kind: LimitBucket.Kind,
        name: String,
        windowSeconds: Int,
        window: CommandCodeWindow?,
        now: Date
    ) -> LimitBucket? {
        guard let window, let cap = window.cap, cap > 0 else { return nil }
        let used = max(0, window.used ?? 0)
        let reached = window.exceeded == true || used >= cap
        let usedPercent = reached ? 100 : clampPercent((used / cap) * 100)
        let resetAt = date(fromEpoch: window.resetAt)
        return LimitBucket(
            provider: .commandcode,
            kind: kind,
            name: name,
            usedPercent: usedPercent,
            resetAt: resetAt,
            resetAfterSeconds: secondsUntil(resetAt, from: now),
            limitWindowSeconds: windowSeconds,
            reached: reached
        )
    }

    private static func monthlyBucket(from snapshot: CommandCodeUsageSnapshot, now: Date) -> LimitBucket? {
        let planCredits = snapshot.subscriptionStatus == activeStatus ? monthlyCredits(for: snapshot.planId) : nil
        let spent = max(0, snapshot.monthlyUsed ?? 0)
        let usedPercent: Int
        let reached: Bool
        if let remaining = snapshot.credits?.monthlyCredits {
            let monthly = max(0, remaining)
            let extras = max(0, snapshot.credits?.purchasedCredits ?? 0) + max(0, snapshot.credits?.freeCredits ?? 0)
            let pool = monthly + extras
            let total = planCredits.map { max($0, monthly) + extras } ?? (spent + pool)
            guard pool > 0 || spent > 0 || planCredits != nil, total > 0 else { return nil }
            usedPercent = clampPercent(min(100, (total - pool) / total * 100))
            reached = pool <= 0
        } else {
            guard let planCredits, planCredits > 0, snapshot.monthlyUsed != nil else { return nil }
            usedPercent = clampPercent(min(100, spent / planCredits * 100))
            reached = spent >= planCredits
        }
        let resetAt = ISODate.parse(snapshot.currentPeriodEnd)
        return LimitBucket(
            provider: .commandcode,
            kind: .monthly,
            name: monthlyDisplayName,
            usedPercent: reached ? 100 : usedPercent,
            resetAt: resetAt,
            resetAfterSeconds: secondsUntil(resetAt, from: now),
            limitWindowSeconds: monthlyWindowSeconds,
            reached: reached
        )
    }

    private static func orgLimitBucket(_ limit: CommandCodeOrgLimit, index: Int, now: Date) -> LimitBucket {
        let name: String
        if limit.scope == "model" {
            name = limit.modelLabel ?? limit.model ?? "Model"
        } else {
            name = "Org-wide"
        }
        let reached = limit.exceeded == true || limit.limit <= 0
        let usedPercent = limit.limit <= 0 ? 100 : clampPercent(min(100, max(0, limit.spent) / limit.limit * 100))
        let resetAt = ISODate.parse(limit.resetAt).flatMap { $0 > now ? $0 : nil }
        return LimitBucket(
            provider: .commandcode,
            kind: .other,
            scope: "spend-limit-\(index)-\(limit.scope ?? "org")-\(limit.model ?? "")",
            name: "\(name) spend limit",
            usedPercent: reached ? 100 : usedPercent,
            resetAt: resetAt,
            resetAfterSeconds: secondsUntil(resetAt, from: now),
            limitWindowSeconds: nil,
            reached: reached,
            detail: "\(credits(limit.spent)) of \(credits(limit.limit))\(intervalSuffix(limit.resetInterval))"
        )
    }

    private static func credits(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private static func intervalSuffix(_ interval: String?) -> String {
        switch interval?.lowercased() {
        case "daily", "day": return "/day"
        case "weekly", "week": return "/week"
        case "monthly", "month": return "/mo"
        default: return ""
        }
    }

    private static func date(fromEpoch value: Double?) -> Date? {
        guard let value, value.isFinite, value > 0, value < 1e14 else { return nil }
        if value >= 1_000_000_000_000 {
            return Date(timeIntervalSince1970: value / 1_000)
        }
        return Date(timeIntervalSince1970: value)
    }

    private static func clampPercent(_ value: Double) -> Int {
        Int(max(0, min(100, value.rounded(.down))))
    }

    private static func secondsUntil(_ date: Date?, from now: Date) -> Int? {
        guard let date else { return nil }
        return max(0, Int(date.timeIntervalSince(now).rounded()))
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key), try decodeNil(forKey: key) == false else { return nil }
        if let value = try? decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return Double(value)
        }
        if let raw = try? decode(String.self, forKey: key) {
            return Double(raw).flatMap { $0.isFinite ? $0 : nil }
        }
        return nil
    }

    func decodeFlexibleDateTextIfPresent(forKey key: Key) -> String? {
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return text
        }
        guard let number = try? decodeIfPresent(Double.self, forKey: key),
              number.isFinite, number > 0, number < 1e14 else {
            return nil
        }
        let seconds = number >= 1_000_000_000_000 ? number / 1_000 : number
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
    }

    func decodeFlexibleBoolIfPresent(forKey key: Key) throws -> Bool? {
        guard contains(key), try decodeNil(forKey: key) == false else { return nil }
        if let value = try? decode(Bool.self, forKey: key) {
            return value
        }
        if let raw = try? decode(String.self, forKey: key) {
            switch raw.lowercased() {
            case "true", "1":
                return true
            case "false", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}
