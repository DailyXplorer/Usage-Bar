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
