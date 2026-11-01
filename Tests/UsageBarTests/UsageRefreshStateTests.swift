import Foundation
import XCTest
@testable import UsageBar

final class UsageRefreshStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    func testEachProviderHasItsOwnCadence() {
        XCTAssertEqual(UsageEndpoint.codex.policy.interval, 180)
        XCTAssertEqual(UsageEndpoint.claude.policy.interval, 900)
        XCTAssertEqual(UsageEndpoint.claudeWhilePaused.policy.interval, 900)
        XCTAssertEqual(UsageEndpoint.cursor.policy.interval, 300)
        XCTAssertEqual(UsageEndpoint.opencode.policy.interval, 300)
        XCTAssertEqual(UsageEndpoint.commandcode.policy.interval, 300)
    }

    func testSuccessfulCompletionSetsTheNextDueTimeFromCompletion() {
        var state = UsageRefreshState()
        let policy = UsageEndpoint.codex.policy

        state.succeed(at: now, interval: policy.interval)

        XCTAssertEqual(state.lastSuccess, now)
        XCTAssertEqual(state.nextRefresh, now.addingTimeInterval(180))
        XCTAssertFalse(state.canStart(at: now.addingTimeInterval(179), force: false, policy: policy))
        XCTAssertTrue(state.canStart(at: now.addingTimeInterval(180), force: false, policy: policy))
    }

    func testSuccessKeepsTheDateOfTheDataItShows() {
        var state = UsageRefreshState()

        state.succeed(at: now, dataDate: now.addingTimeInterval(-2_400), interval: 900)

        XCTAssertEqual(state.lastSuccess, now.addingTimeInterval(-2_400))
        XCTAssertEqual(state.nextRefresh, now.addingTimeInterval(900))
    }

    func testForcedRefreshRespectsThrottleButCanBypassNormalCadence() {
        var state = UsageRefreshState()
        let policy = UsageEndpoint.codex.policy
        state.succeed(at: now, interval: policy.interval)

        XCTAssertTrue(state.canStart(at: now.addingTimeInterval(1), force: true, policy: policy))

        let retryAfter = now.addingTimeInterval(900)
        state.throttle("Rate limited", retryAfter: retryAfter, at: now, interval: policy.interval)

        XCTAssertFalse(state.canStart(at: now.addingTimeInterval(300), force: true, policy: policy))
        XCTAssertTrue(state.canStart(at: retryAfter, force: true, policy: policy))
    }

    func testClaudeRefreshButtonWaitsAMinuteBetweenCalls() {
        var state = UsageRefreshState()
        let policy = UsageEndpoint.claude.policy
        state.begin(at: now)
        state.succeed(at: now, interval: policy.interval)

        XCTAssertFalse(state.canStart(at: now.addingTimeInterval(59), force: true, policy: policy))
        XCTAssertTrue(state.canStart(at: now.addingTimeInterval(60), force: true, policy: policy))
    }

    func testOpeningThePopoverRefetchesClaudeOnlyWhenDataIsOlderThanFiveMinutes() {
        var state = UsageRefreshState()
        let policy = UsageEndpoint.claude.policy
        state.begin(at: now)
        state.succeed(at: now, interval: policy.interval)

        XCTAssertFalse(state.canStartOnOpen(at: now.addingTimeInterval(299), policy: policy))
        XCTAssertTrue(state.canStartOnOpen(at: now.addingTimeInterval(301), policy: policy))
    }

    func testOpeningThePopoverNeverStartsTheQuotaCheck() {
        var state = UsageRefreshState()
        let policy = UsageEndpoint.claudeWhilePaused.policy
        state.begin(at: now)
        state.succeed(at: now, interval: policy.interval)

        XCTAssertFalse(state.canStartOnOpen(at: now.addingTimeInterval(600), policy: policy))
        XCTAssertFalse(state.canStart(at: now.addingTimeInterval(600), force: true, policy: policy))
        XCTAssertTrue(state.canStart(at: now.addingTimeInterval(900), force: false, policy: policy))
    }

    func testQuotaCheckIsNotBlockedForDaysAfterTheClockMovesBack() {
        var state = UsageRefreshState()
        let policy = UsageEndpoint.claudeWhilePaused.policy
        state.begin(at: now)
        state.fail("offline", at: now, retryAfter: 60)
        let earlier = now.addingTimeInterval(-3 * 86_400)

        let restored = state.restored(now: earlier)

        XCTAssertFalse(restored.canStart(at: earlier.addingTimeInterval(899), force: false, policy: policy))
        XCTAssertTrue(restored.canStart(at: earlier.addingTimeInterval(900), force: false, policy: policy))
    }

    func testCooldownRoundTripsThroughCoding() throws {
        let retryAfter = now.addingTimeInterval(600)
        var state = UsageRefreshState()
        state.throttle("Rate limited", retryAfter: retryAfter, at: now, interval: 180, scope: "account")

        let restored = try JSONDecoder().decode(
            UsageRefreshState.self,
            from: JSONEncoder().encode(state)
        )

        XCTAssertEqual(restored.lastError, "Rate limited")
        XCTAssertEqual(restored.nextRefresh, retryAfter)
        XCTAssertEqual(restored.backoff.blockedUntil, retryAfter)
        XCTAssertEqual(restored.backoff.scope, "account")
        XCTAssertFalse(restored.canStart(at: now.addingTimeInterval(599), force: true, policy: UsageEndpoint.codex.policy))
    }

    func testRetryHappensWhenThePauseEnds() {
        var state = UsageRefreshState()

        state.throttle("Paused", retryAfter: nil, at: now, interval: 900)

        XCTAssertEqual(state.backoff.blockedUntil, now.addingTimeInterval(300))
        XCTAssertEqual(state.nextRefresh, now.addingTimeInterval(300))
        XCTAssertTrue(state.canStart(at: now.addingTimeInterval(300), force: false, policy: UsageEndpoint.claude.policy))
    }

    func testASuccessWithoutCallingTheEndpointKeepsTheEscalation() {
        var state = UsageRefreshState()
        state.throttle("Paused", retryAfter: nil, at: now, interval: 900)

        state.succeed(at: now.addingTimeInterval(400), interval: 900, resetsBackoff: false)
        state.throttle("Paused", retryAfter: nil, at: now.addingTimeInterval(500), interval: 900)

        XCTAssertEqual(state.backoff.attempt, 2)
        XCTAssertEqual(state.backoff.blockedUntil, now.addingTimeInterval(500 + 900))
    }

    func testOldSavedStateWithoutAttemptStillDecodes() throws {
        let json = #"{"lastSuccess": 10, "nextRefresh": 20, "backoff": {"attempt": 1}}"#
        let state = try JSONDecoder().decode(UsageRefreshState.self, from: Data(json.utf8))

        XCTAssertNil(state.lastAttempt)
        XCTAssertEqual(state.backoff.attempt, 1)
    }
}
