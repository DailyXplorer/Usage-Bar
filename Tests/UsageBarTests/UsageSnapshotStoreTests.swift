import XCTest
@testable import UsageBar

final class UsageSnapshotStoreTests: XCTestCase {
    private func bucket(resetAt: Date?, resetAfterSeconds: Int?) -> LimitBucket {
        LimitBucket(
            provider: .claude,
            kind: .weeklyAll,
            name: "Week · All models",
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
            fetchedAt: Date(timeIntervalSince1970: 1_786_400_000)
        )
        UsageSnapshotStore.save(snapshot, to: defaults)

        let loaded = try XCTUnwrap(UsageSnapshotStore.load(from: defaults))
        XCTAssertEqual(loaded.claudePlan, "max")
        XCTAssertEqual(loaded.claudeBuckets.count, 1)
        XCTAssertEqual(loaded.claudeBuckets[0].remainingPercent, 99)
        XCTAssertEqual(loaded.fetchedAt, snapshot.fetchedAt)
    }

    /// Le pourcentage est figé au moment du relevé, mais le compte-à-rebours
    /// doit repartir de l'heure de reset, sinon une barre relue affiche un
    /// délai périmé.
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
