import XCTest
@testable import UsageBar

final class CursorLimitsTests: XCTestCase {
    private let payload = """
    {
      "billingCycleStart": "1786566047085",
      "billingCycleEnd": "1789244447085",
      "planUsage": {
        "totalSpend": 28,
        "includedSpend": 28,
        "remaining": 1972,
        "limit": 2000,
        "autoPercentUsed": 42.4,
        "apiPercentUsed": 10.6,
        "totalPercentUsed": 15.48
      },
      "enabled": true
    }
    """

    private func decode() throws -> CursorUsageResponse {
        try JSONDecoder().decode(CursorUsageResponse.self, from: Data(payload.utf8))
    }

    func testBucketsMatchCursorDashboardPools() throws {
        let now = Date(timeIntervalSince1970: 1_786_566_047)
        let buckets = CursorLimits.buckets(from: try decode(), now: now)

        XCTAssertEqual(buckets.map(\.kind), [.cursorModels, .otherModels])
        XCTAssertEqual(buckets.map(\.displayName), ["Cursor Models", "Other Models"])
        XCTAssertEqual(buckets.map(\.usedPercent), [42, 11])
        XCTAssertEqual(buckets.map(\.remainingPercent), [58, 89])
        XCTAssertTrue(buckets.allSatisfy { $0.provider == .cursor })
        XCTAssertEqual(buckets[0].detail, CursorLimits.modelsDetail)
        XCTAssertEqual(buckets[1].detail, CursorLimits.otherDetail)
    }

    func testResetCountdownUsesBillingCycleEnd() throws {
        let now = Date(timeIntervalSince1970: 1_786_566_047.085)
        let buckets = CursorLimits.buckets(from: try decode(), now: now)

        XCTAssertEqual(buckets[0].resetAfterSeconds, 2_678_400)
        XCTAssertEqual(buckets[0].limitWindowSeconds, 2_678_400)
    }

    func testCursorModelsPercentUsedAliasIsAccepted() throws {
        let aliased = """
        {"billingCycleStart":"1786566047085","billingCycleEnd":"1789244447085",
         "planUsage":{"cursorModelsPercentUsed":7,"apiPercentUsed":3},"enabled":true}
        """
        let response = try JSONDecoder().decode(CursorUsageResponse.self, from: Data(aliased.utf8))
        let buckets = CursorLimits.buckets(from: response)

        XCTAssertEqual(buckets.map(\.remainingPercent), [93, 97])
    }

    func testNumericCycleTimestampsDecode() throws {
        let numeric = """
        {"billingCycleStart":1786566047085,"billingCycleEnd":1789244447085,
         "planUsage":{"autoPercentUsed":0,"apiPercentUsed":0},"enabled":true}
        """
        let response = try JSONDecoder().decode(CursorUsageResponse.self, from: Data(numeric.utf8))
        let buckets = CursorLimits.buckets(from: response)

        XCTAssertEqual(buckets.count, 2)
        XCTAssertNotNil(buckets[0].resetAt)
    }

    func testDisabledResponseYieldsNoBuckets() throws {
        let disabled = """
        {"planUsage":{"autoPercentUsed":12,"apiPercentUsed":8},"enabled":false}
        """
        let response = try JSONDecoder().decode(CursorUsageResponse.self, from: Data(disabled.utf8))

        XCTAssertTrue(CursorLimits.buckets(from: response).isEmpty)
    }

    @MainActor
    func testMenuBarUsesCursorModelsPool() throws {
        let model = UsageModel(
            previewBuckets: [
                LimitBucket(
                    kind: .primary,
                    name: "weekly",
                    usedPercent: 1,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: 604_800,
                    reached: false
                )
            ],
            planType: "prolite",
            lastUpdated: Date(),
            cursorBuckets: CursorLimits.buckets(from: try decode()),
            cursorPlan: "pro",
            menuBarProviders: [.codex, .cursor]
        )

        XCTAssertEqual(model.menuBarText, "99%")
        XCTAssertEqual(model.menuBarCursorText, "58%")
        XCTAssertEqual(model.cursorModels?.kind, .cursorModels)
        XCTAssertEqual(model.menuBarSegments.map(\.value), ["99%", "58%"])
    }
}
