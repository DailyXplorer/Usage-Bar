import XCTest
@testable import UsageBar

final class ClaudeCredentialsTests: XCTestCase {
    func testPlanTokenUsesRateLimitTierForMax() {
        XCTAssertEqual(credentials(subscription: "max", tier: "default_claude_max_5x").planToken, "max_5x")
        XCTAssertEqual(credentials(subscription: "max", tier: "default_claude_max_20x").planToken, "max_20x")
        XCTAssertEqual(credentials(subscription: "MAX", tier: "DEFAULT_CLAUDE_MAX_20X").planToken, "max_20x")
    }

    func testPlanTokenFallsBackToMaxWithoutTier() {
        XCTAssertEqual(credentials(subscription: "max", tier: nil).planToken, "max")
        XCTAssertEqual(credentials(subscription: "max", tier: "").planToken, "max")
        XCTAssertEqual(credentials(subscription: "max", tier: "default_claude_ai").planToken, "max")
    }

    func testPlanTokenLeavesProUnchanged() {
        XCTAssertEqual(credentials(subscription: "pro", tier: "default_claude_max_20x").planToken, "pro")
        XCTAssertEqual(credentials(subscription: "pro", tier: nil).planToken, "pro")
    }

    func testPlanTokenIsNilWithoutSubscription() {
        XCTAssertNil(credentials(subscription: nil, tier: "default_claude_max_5x").planToken)
        XCTAssertNil(credentials(subscription: "", tier: "default_claude_max_5x").planToken)
    }

    func testPrefers20xWhenBothTokensCouldMatch() {
        XCTAssertEqual(credentials(subscription: "max", tier: "max_20x_preview").planToken, "max_20x")
    }

    func testExpiryUsesTheStoredDeadline() {
        let deadline = Date(timeIntervalSince1970: 1_790_000_000)
        let stored = ClaudeCredentials(accessToken: "token", subscriptionType: "max", rateLimitTier: nil, expiresAt: deadline)
        XCTAssertFalse(stored.isExpired(at: deadline.addingTimeInterval(-1)))
        XCTAssertTrue(stored.isExpired(at: deadline))
        XCTAssertTrue(stored.isExpired(at: deadline.addingTimeInterval(2 * 24 * 3600)))
    }

    func testCredentialsWithoutDeadlineNeverExpireLocally() {
        XCTAssertFalse(credentials(subscription: "max", tier: nil).isExpired(at: .distantFuture))
    }

    private func credentials(subscription: String?, tier: String?) -> ClaudeCredentials {
        ClaudeCredentials(
            accessToken: "token",
            subscriptionType: subscription,
            rateLimitTier: tier,
            expiresAt: nil
        )
    }
}
