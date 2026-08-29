import Foundation

struct CommandCodeWhoamiResponse: Decodable {
    struct Org: Decodable {
        let id: String?
    }

    let org: Org?
}

struct CommandCodeSubscriptionsResponse: Decodable {
    struct Subscription: Decodable {
        let planId: String?
        let status: String?
        let currentPeriodStart: String?
        let currentPeriodEnd: String?
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
    let totalMonthlyCredits: Double?
}

struct CommandCodeUsageSnapshot {
    var planId: String?
    var subscriptionStatus: String?
    var currentPeriodEnd: String?
    var credits: CommandCodeCreditsResponse.Credits?
    var windowLimits: CommandCodeCreditsResponse.WindowLimits?
    var monthlyUsed: Double?
}

enum CommandCodeLimits {
    static let rollingDisplayName = WindowLabels.currentSession
    static let weeklyDisplayName = WindowLabels.weeklyLimit
    static let monthlyDisplayName = WindowLabels.monthlyLimit
    static let rollingWindowSeconds = 5 * 60 * 60
    static let weeklyWindowSeconds = 7 * 24 * 60 * 60
    static let monthlyWindowSeconds = 30 * 24 * 60 * 60
    static let payAsYouGoPlanId = "individual-provider"

    private static let plans: [(id: String, name: String, monthlyCredits: Double)] = [
        ("individual-provider", "Provider", 0),
        ("individual-pro-v1", "Pro", 80),
        ("individual-ultra", "Max 20x", 300),
        ("individual-goat", "Goat", 70),
        ("individual-max", "Max 10x", 150),
        ("individual-pro", "Pro", 30),
        ("individual-go", "Go", 10),
        ("teams-pro", "Team Pro", 40),
    ]

    static func canonicalPlanId(from planId: String?) -> String? {
        guard let planId, !planId.isEmpty else { return nil }
        let key = planId.lowercased().replacingOccurrences(of: "_", with: "-")
        return plans.first(where: { key.hasPrefix($0.id) })?.id
    }

    static func displayName(for planId: String?) -> String? {
        guard let id = canonicalPlanId(from: planId), id != payAsYouGoPlanId else { return nil }
        return plans.first(where: { $0.id == id })?.name
    }

    static func monthlyCredits(for planId: String?) -> Double? {
        guard let id = canonicalPlanId(from: planId), id != payAsYouGoPlanId else { return nil }
        return plans.first(where: { $0.id == id })?.monthlyCredits
    }

    static func shouldHide(_ snapshot: CommandCodeUsageSnapshot) -> Bool {
        if canonicalPlanId(from: snapshot.planId) == payAsYouGoPlanId {
            return true
        }
        if windowLimits(from: snapshot)?.limited == false {
            return true
        }
        return false
    }

    static func buckets(from snapshot: CommandCodeUsageSnapshot, now: Date = Date()) -> [LimitBucket] {
        guard !shouldHide(snapshot) else { return [] }
        let windows = windowLimits(from: snapshot)
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
        guard let total = monthlyCredits(for: snapshot.planId), total > 0 else { return nil }
        let remaining = snapshot.credits?.monthlyCredits.map { max(0, $0) }
        guard let used = snapshot.monthlyUsed.map({ max(0, min($0, total)) })
            ?? remaining.map({ max(0, total - min($0, total)) }) else {
            return nil
        }
        let usedPercent = clampPercent((used / total) * 100)
        let reached = used >= total || remaining == 0
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

    private static func date(fromEpoch value: Double?) -> Date? {
        guard let value, value > 0 else { return nil }
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
            return Double(raw)
        }
        return nil
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
