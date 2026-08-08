import Foundation

struct UsageSnapshot: Codable {
    var codexBuckets: [LimitBucket] = []
    var codexPlan: String?
    var claudeBuckets: [LimitBucket] = []
    var claudePlan: String?
    var fetchedAt: Date

    func refreshed(now: Date = Date()) -> UsageSnapshot {
        var copy = self
        copy.codexBuckets = codexBuckets.map { $0.recountingReset(from: now) }
        copy.claudeBuckets = claudeBuckets.map { $0.recountingReset(from: now) }
        return copy
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
