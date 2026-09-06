import XCTest
@testable import UsageBar

final class ModelsTests: XCTestCase {
    func testRemainingPercentIsDerivedFromUsedPercent() {
        let bucket = LimitBucket(
            kind: .primary,
            name: "weekly",
            usedPercent: 42,
            resetAt: nil,
            resetAfterSeconds: nil,
            limitWindowSeconds: 604_800,
            reached: false
        )

        XCTAssertEqual(bucket.remainingPercent, 58)
    }

    func testRemainingPercentIsClamped() {
        let base = { (usedPercent: Int) in
            LimitBucket(
                kind: .primary,
                name: "weekly",
                usedPercent: usedPercent,
                resetAt: nil,
                resetAfterSeconds: nil,
                limitWindowSeconds: 604_800,
                reached: false
            )
        }

        XCTAssertEqual(base(-10).remainingPercent, 100)
        XCTAssertEqual(base(120).remainingPercent, 0)
    }

    func testCountdownUsesAbsoluteDeadlineWithoutMutatingUsage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bucket = LimitBucket(
            kind: .primary,
            name: "Current Session",
            usedPercent: 42,
            resetAt: now.addingTimeInterval(180),
            resetAfterSeconds: 999,
            limitWindowSeconds: 18_000,
            reached: false
        )
        XCTAssertEqual(bucket.remainingResetSeconds(at: now), 180)
        XCTAssertEqual(bucket.remainingResetSeconds(at: now.addingTimeInterval(60)), 120)
        XCTAssertEqual(bucket.remainingResetSeconds(at: now.addingTimeInterval(181)), 0)
        XCTAssertEqual(bucket.usedPercent, 42)
    }

    func testCodexAnchorsRelativeResetAtResponseTime() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(
            #"{"rate_limit":{"primary_window":{"used_percent":42,"reset_after_seconds":180}}}"#.utf8
        ))
        let bucket = try XCTUnwrap(CodexLimits.buckets(from: response, now: now).first)
        XCTAssertEqual(bucket.resetAt, now.addingTimeInterval(180))
        XCTAssertEqual(bucket.remainingResetSeconds(at: now.addingTimeInterval(60)), 120)
    }

    func testUnknownResetDoesNotInventACountdown() {
        let bucket = LimitBucket(
            kind: .primary, name: "Current Session", usedPercent: 42,
            resetAt: nil, resetAfterSeconds: nil, limitWindowSeconds: nil, reached: false
        )
        XCTAssertNil(bucket.remainingResetSeconds(at: Date()))
    }

    func testKnownWindowLabels() {
        XCTAssertEqual(
            WindowLabels.label(forWindowSeconds: 5 * 60 * 60, isSecondary: false),
            "Current Session"
        )
        XCTAssertEqual(
            WindowLabels.label(forWindowSeconds: 7 * 24 * 60 * 60, isSecondary: false),
            "Weekly Limit"
        )
        XCTAssertEqual(
            WindowLabels.label(forWindowSeconds: 30 * 24 * 60 * 60, isSecondary: false),
            "Monthly Limit"
        )
    }

    func testLongDurationUsesDays() async {
        let duration = await UsageModel.durationString(seconds: 231_321)
        XCTAssertEqual(duration, "2d 16h")
    }

    @MainActor
    func testMenuBarTextShowsRemainingPercentage() {
        let bucket = LimitBucket(
            kind: .primary,
            name: "weekly",
            usedPercent: 42,
            resetAt: nil,
            resetAfterSeconds: nil,
            limitWindowSeconds: 604_800,
            reached: false
        )
        let model = UsageModel(
            previewBuckets: [bucket],
            planType: "prolite",
            lastUpdated: Date()
        )

        XCTAssertEqual(model.menuBarText, "58%")
    }
}
