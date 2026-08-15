import Foundation

struct UsageSnapshot: Codable {
    var codexBuckets: [LimitBucket] = []
    var codexPlan: String?
    var claudeBuckets: [LimitBucket] = []
    var claudePlan: String?
    var cursorBuckets: [LimitBucket] = []
    var cursorPlan: String?
    var opencodeBuckets: [LimitBucket] = []
    var opencodePlan: String?
    var fetchedAt: Date

    private enum CodingKeys: String, CodingKey {
        case codexBuckets, codexPlan, claudeBuckets, claudePlan
        case cursorBuckets, cursorPlan, opencodeBuckets, opencodePlan, fetchedAt
    }

    init(
        codexBuckets: [LimitBucket] = [],
        codexPlan: String? = nil,
        claudeBuckets: [LimitBucket] = [],
        claudePlan: String? = nil,
        cursorBuckets: [LimitBucket] = [],
        cursorPlan: String? = nil,
        opencodeBuckets: [LimitBucket] = [],
        opencodePlan: String? = nil,
        fetchedAt: Date
    ) {
        self.codexBuckets = codexBuckets
        self.codexPlan = codexPlan
        self.claudeBuckets = claudeBuckets
        self.claudePlan = claudePlan
        self.cursorBuckets = cursorBuckets
        self.cursorPlan = cursorPlan
        self.opencodeBuckets = opencodeBuckets
        self.opencodePlan = opencodePlan
        self.fetchedAt = fetchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codexBuckets = try container.decodeIfPresent([LimitBucket].self, forKey: .codexBuckets) ?? []
        codexPlan = try container.decodeIfPresent(String.self, forKey: .codexPlan)
        claudeBuckets = try container.decodeIfPresent([LimitBucket].self, forKey: .claudeBuckets) ?? []
        claudePlan = try container.decodeIfPresent(String.self, forKey: .claudePlan)
        cursorBuckets = try container.decodeIfPresent([LimitBucket].self, forKey: .cursorBuckets) ?? []
        cursorPlan = try container.decodeIfPresent(String.self, forKey: .cursorPlan)
        opencodeBuckets = try container.decodeIfPresent([LimitBucket].self, forKey: .opencodeBuckets) ?? []
        opencodePlan = try container.decodeIfPresent(String.self, forKey: .opencodePlan)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
    }

    func refreshed(now: Date = Date()) -> UsageSnapshot {
        var copy = self
        copy.codexBuckets = codexBuckets.map { $0.recountingReset(from: now) }
        copy.claudeBuckets = claudeBuckets.map { ClaudeLimits.relabeled($0).recountingReset(from: now) }
        copy.cursorBuckets = cursorBuckets.map { $0.recountingReset(from: now) }
        copy.opencodeBuckets = opencodeBuckets.map { OpenCodeLimits.relabeled($0).recountingReset(from: now) }
        copy.opencodePlan = nil
        return copy
    }
}

enum MenuBarPreferences {
    static let key = "menuBarProviders"
    static let defaultProviders: [LimitBucket.Provider] = [.codex, .claude]

    static func load(from defaults: UserDefaults = .standard) -> Set<LimitBucket.Provider> {
        guard let raw = defaults.array(forKey: key) as? [String] else {
            return Set(defaultProviders)
        }
        let parsed = raw.compactMap(LimitBucket.Provider.init(rawValue:))
        return parsed.isEmpty ? Set(defaultProviders) : Set(parsed)
    }

    static func save(_ providers: Set<LimitBucket.Provider>, to defaults: UserDefaults = .standard) {
        let ordered = LimitBucket.Provider.allCases.filter { providers.contains($0) }
        defaults.set(ordered.map(\.rawValue), forKey: key)
    }
}

enum UsageSnapshotStore {
    private static let key = "lastUsageSnapshot"

    static func load(from defaults: UserDefaults = .standard) -> UsageSnapshot? {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data) else {
            return nil
        }
        return snapshot
    }

    static func save(_ snapshot: UsageSnapshot, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}

struct ThrottleBackoff {
    static let steps: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 60 * 60]

    private(set) var attempt = 0
    private(set) var blockedUntil: Date?

    var isBlocked: Bool {
        guard let blockedUntil else { return false }
        return blockedUntil > Date()
    }

    mutating func recordThrottle(now: Date = Date()) {
        let delay = Self.steps[min(attempt, Self.steps.count - 1)]
        attempt += 1
        blockedUntil = now.addingTimeInterval(delay)
    }

    mutating func reset() {
        attempt = 0
        blockedUntil = nil
    }
}
