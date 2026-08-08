import XCTest
@testable import UsageBar

final class ClaudeLimitsTests: XCTestCase {
    private let payload = """
    {
      "five_hour": {"utilization": 12.0, "resets_at": "2026-08-08T23:40:00.397667+00:00"},
      "seven_day": {"utilization": 40.0, "resets_at": "2026-08-10T23:00:00.397687+00:00"},
      "seven_day_opus": null,
      "limits": [
        {"kind": "session", "group": "session", "percent": 12, "severity": "normal",
         "resets_at": "2026-08-08T23:40:00.397667+00:00", "scope": null, "is_active": true},
        {"kind": "weekly_all", "group": "weekly", "percent": 40, "severity": "normal",
         "resets_at": "2026-08-10T23:00:00.397687+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 100, "severity": "reached",
         "resets_at": "2026-08-10T23:00:00.397941+00:00",
         "scope": {"model": {"id": null, "display_name": "Opus"}, "surface": null},
         "is_active": false}
      ]
    }
    """

    private func decode() throws -> ClaudeUsageResponse {
        try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(payload.utf8))
    }

    func testBucketsMatchClaudeCodeUsageBars() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let buckets = ClaudeLimits.buckets(from: try decode(), now: now)

        XCTAssertEqual(buckets.map(\.kind), [.session, .weeklyAll, .weeklyScoped])
        XCTAssertEqual(buckets.map(\.displayName), [
            "Session 5h",
            "Week · All models",
            "Week · Opus",
        ])
        XCTAssertEqual(buckets.map(\.remainingPercent), [88, 60, 0])
        XCTAssertTrue(buckets.allSatisfy { $0.provider == .claude })
    }

    func testReachedIsFlaggedAtFullUtilization() throws {
        let buckets = ClaudeLimits.buckets(from: try decode())

        XCTAssertEqual(buckets.filter(\.reached).map(\.kind), [.weeklyScoped])
    }

    func testResetCountdownIsRelativeToNow() async throws {
        let now = Date(timeIntervalSince1970: 1_786_225_200)
        let buckets = ClaudeLimits.buckets(from: try decode(), now: now)

        XCTAssertEqual(buckets[0].resetAfterSeconds, 7_200)
        let countdown = await UsageModel.durationString(seconds: buckets[0].resetAfterSeconds ?? 0)
        XCTAssertEqual(countdown, "2h 0m")
    }

    func testFallbackUsesLegacyWindowsWhenLimitsArrayIsMissing() throws {
        let legacy = """
        {"five_hour": {"utilization": 25.0, "resets_at": "2026-08-08T23:40:00Z"},
         "seven_day": {"utilization": 10.0, "resets_at": "2026-08-10T23:00:00Z"},
         "seven_day_opus": {"utilization": 90.0, "resets_at": "2026-08-10T23:00:00Z"}}
        """
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(legacy.utf8))
        let buckets = ClaudeLimits.buckets(from: response)

        XCTAssertEqual(buckets.map(\.kind), [.session, .weeklyAll, .weeklyScoped])
        XCTAssertEqual(buckets.map(\.remainingPercent), [75, 90, 10])
        XCTAssertEqual(buckets[2].displayName, "Week · Opus")
    }

    func testISODateParsesSixDigitFractionalSeconds() {
        let date = ISODate.parse("2026-08-08T23:40:00.397667+00:00")

        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_786_232_400.397, accuracy: 0.01)
        XCTAssertNotNil(ISODate.parse("2026-08-08T23:40:00Z"))
        XCTAssertNil(ISODate.parse(nil))
        XCTAssertNil(ISODate.parse("bientôt"))
    }

    @MainActor
    func testMenuBarShowsCodexAndClaudeAllModels() throws {
        let model = UsageModel(
            previewBuckets: [
                LimitBucket(
                    kind: .primary,
                    name: "weekly",
                    usedPercent: 42,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: 604_800,
                    reached: false
                )
            ],
            planType: "prolite",
            lastUpdated: Date(),
            claudeBuckets: ClaudeLimits.buckets(from: try decode()),
            claudePlan: "max"
        )

        XCTAssertEqual(model.menuBarText, "58%")
        XCTAssertEqual(model.menuBarClaudeText, "60%")
        XCTAssertEqual(model.claudeAllModels?.kind, .weeklyAll)
    }

    @MainActor
    func testMenuBarOmitsClaudeWhenNoSession() {
        let model = UsageModel(
            previewBuckets: [
                LimitBucket(
                    kind: .primary,
                    name: "5h",
                    usedPercent: 10,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: 18_000,
                    reached: false
                )
            ],
            planType: "prolite",
            lastUpdated: Date()
        )

        XCTAssertNil(model.menuBarClaudeText)
        XCTAssertNil(model.menuBarClaudeAccessibilityText)
        XCTAssertEqual(model.buckets[0].displayName, "5h")
    }
}
