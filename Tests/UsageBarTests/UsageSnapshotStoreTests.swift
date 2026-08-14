import XCTest
@testable import UsageBar

final class UsageSnapshotStoreTests: XCTestCase {
    private func bucket(resetAt: Date?, resetAfterSeconds: Int?) -> LimitBucket {
        LimitBucket(
            provider: .claude,
            kind: .weeklyAll,
            name: "All models",
            usedPercent: 1,
            resetAt: resetAt,
            resetAfterSeconds: resetAfterSeconds,
            limitWindowSeconds: 604_800,
            reached: false
        )
    }

    func testSnapshotRoundTripsThroughUserDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        let snapshot = UsageSnapshot(
            claudeBuckets: [bucket(resetAt: Date(timeIntervalSince1970: 1_786_402_800), resetAfterSeconds: 600)],
            claudePlan: "max",
            cursorBuckets: [
                LimitBucket(
                    provider: .cursor,
                    kind: .cursorModels,
                    name: "Cursor Models",
                    usedPercent: 12,
                    resetAt: Date(timeIntervalSince1970: 1_789_244_447),
                    resetAfterSeconds: 600,
                    limitWindowSeconds: 2_678_400,
                    reached: false
                )
            ],
            cursorPlan: "pro",
            fetchedAt: Date(timeIntervalSince1970: 1_786_400_000)
        )
        UsageSnapshotStore.save(snapshot, to: defaults)

        let loaded = try XCTUnwrap(UsageSnapshotStore.load(from: defaults))
        XCTAssertEqual(loaded.claudePlan, "max")
        XCTAssertEqual(loaded.claudeBuckets.count, 1)
        XCTAssertEqual(loaded.claudeBuckets[0].remainingPercent, 99)
        XCTAssertEqual(loaded.cursorPlan, "pro")
        XCTAssertEqual(loaded.cursorBuckets[0].remainingPercent, 88)
        XCTAssertNil(loaded.cursorBuckets[0].detail)
        XCTAssertEqual(loaded.fetchedAt, snapshot.fetchedAt)
    }

    func testLegacySnapshotWithoutCursorStillDecodes() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        let legacy = UsageSnapshot(
            claudeBuckets: [bucket(resetAt: Date(timeIntervalSince1970: 1_786_402_800), resetAfterSeconds: 600)],
            claudePlan: "max",
            fetchedAt: Date(timeIntervalSince1970: 1_786_400_000)
        )
        let data = try JSONEncoder().encode(legacy)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "cursorBuckets")
        object.removeValue(forKey: "cursorPlan")
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "lastUsageSnapshot")

        let loaded = try XCTUnwrap(UsageSnapshotStore.load(from: defaults))
        XCTAssertTrue(loaded.cursorBuckets.isEmpty)
        XCTAssertNil(loaded.cursorPlan)
        XCTAssertEqual(loaded.claudePlan, "max")
    }

    func testMenuBarPreferencesDefaultToCodexAndClaude() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        XCTAssertEqual(MenuBarPreferences.load(from: defaults), [.codex, .claude])

        MenuBarPreferences.save([.cursor, .codex], to: defaults)
        XCTAssertEqual(MenuBarPreferences.load(from: defaults), [.codex, .cursor])
    }

    func testCountdownIsRecomputedOnLoad() {
        let resetAt = Date(timeIntervalSince1970: 1_786_402_800)
        let snapshot = UsageSnapshot(
            claudeBuckets: [bucket(resetAt: resetAt, resetAfterSeconds: 999_999)],
            fetchedAt: resetAt.addingTimeInterval(-7_200)
        )

        let refreshed = snapshot.refreshed(now: resetAt.addingTimeInterval(-1_800))

        XCTAssertEqual(refreshed.claudeBuckets[0].resetAfterSeconds, 1_800)
    }

    func testCountdownFloorsAtZeroOnceResetHasPassed() {
        let resetAt = Date(timeIntervalSince1970: 1_786_402_800)
        let snapshot = UsageSnapshot(
            claudeBuckets: [bucket(resetAt: resetAt, resetAfterSeconds: 600)],
            fetchedAt: resetAt
        )

        let refreshed = snapshot.refreshed(now: resetAt.addingTimeInterval(3_600))

        XCTAssertEqual(refreshed.claudeBuckets[0].resetAfterSeconds, 0)
    }

    func testBackoffWidensThenResets() {
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        var backoff = ThrottleBackoff()
        XCTAssertFalse(backoff.isBlocked)

        backoff.recordThrottle(now: now)
        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(5 * 60))

        backoff.recordThrottle(now: now)
        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(15 * 60))

        backoff.reset()
        XCTAssertFalse(backoff.isBlocked)
        XCTAssertNil(backoff.blockedUntil)
    }

    func testBackoffCapsAtTheLongestStep() {
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        var backoff = ThrottleBackoff()
        for _ in 0..<10 {
            backoff.recordThrottle(now: now)
        }

        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(60 * 60))
    }
}
