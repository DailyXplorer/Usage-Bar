import Foundation
import XCTest
@testable import UsageBar

final class UsageRefreshStateTests: XCTestCase {
    func testSuccessfulCompletionSetsTheNextDueTimeFromCompletion() {
        let completedAt = Date(timeIntervalSince1970: 1_788_000_000)
        var state = UsageRefreshState()

        state.succeed(at: completedAt)

        XCTAssertEqual(state.lastSuccess, completedAt)
        XCTAssertEqual(state.nextRefresh, completedAt.addingTimeInterval(180))
        XCTAssertFalse(state.canStart(at: completedAt.addingTimeInterval(179), force: false))
        XCTAssertTrue(state.canStart(at: completedAt.addingTimeInterval(180), force: false))
    }

    func testForcedRefreshRespectsThrottleButCanBypassNormalCadence() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        var state = UsageRefreshState()
        state.succeed(at: now)

        XCTAssertTrue(state.canStart(at: now.addingTimeInterval(1), force: true))

        let retryAfter = now.addingTimeInterval(900)
        state.throttle("Rate limited", retryAfter: retryAfter, at: now)

        XCTAssertFalse(state.canStart(at: now.addingTimeInterval(300), force: true))
        XCTAssertTrue(state.canStart(at: retryAfter, force: true))
    }

    func testCooldownRoundTripsThroughCoding() throws {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let retryAfter = now.addingTimeInterval(600)
        var state = UsageRefreshState()
        state.throttle("Rate limited", retryAfter: retryAfter, at: now)

        let restored = try JSONDecoder().decode(
            UsageRefreshState.self,
            from: JSONEncoder().encode(state)
        )

        XCTAssertEqual(restored.lastError, "Rate limited")
        XCTAssertEqual(restored.nextRefresh, now.addingTimeInterval(UsageRefreshState.interval))
        XCTAssertEqual(restored.backoff.blockedUntil, retryAfter)
        XCTAssertFalse(restored.canStart(at: now.addingTimeInterval(599), force: true))
    }
}
