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
        XCTAssertTrue(buckets.allSatisfy { $0.detail == nil })
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

    @MainActor
    func testEmptyStateIgnoresHiddenCodexError() {
        let model = UsageModel(
            previewBuckets: [],
            planType: "pro",
            lastUpdated: Date(),
            menuBarProviders: [.cursor],
            errorMessage: "ChatGPT is unreachable.",
            cursorAvailable: false
        )

        XCTAssertEqual(
            model.visibleEmptyStateMessage,
            "No Cursor session. Open Cursor and sign in."
        )
    }

    @MainActor
    func testSignedInCursorWithoutPoolsDoesNotLookSignedOut() {
        let model = UsageModel(
            previewBuckets: [],
            planType: "pro",
            lastUpdated: Date(),
            menuBarProviders: [.cursor],
            cursorAvailable: true
        )

        XCTAssertEqual(model.sectionMessage(for: .cursor), "Cursor returned no limits.")
    }

    func testGrokBotBarMapsSandUsagePercent() throws {
        let now = Date(timeIntervalSince1970: 1_786_838_400)
        let grokBot = try decodeGrokBot("""
        {
          "currentPeriodStart": "2026-08-10T00:00:00.000Z",
          "nextResetTimestampUtc": "2026-08-17T00:00:00.000Z",
          "usagePercent": 18.5,
          "hasAvailableUsage": true,
          "hasNonZeroIncludedLimit": true
        }
        """)
        let buckets = CursorLimits.buckets(from: try decode(), grokBot: grokBot, now: now)

        XCTAssertEqual(buckets.map(\.kind), [.cursorModels, .otherModels, .grokBot])
        XCTAssertEqual(buckets.map(\.displayName), ["Cursor Models", "Other Models", "Grok bot"])
        XCTAssertEqual(buckets.map(\.usedPercent), [42, 11, 19])
        XCTAssertEqual(buckets.map(\.remainingPercent), [58, 89, 81])
        XCTAssertEqual(buckets[2].resetAfterSeconds, 86_400)
        XCTAssertEqual(buckets[2].limitWindowSeconds, 604_800)
        XCTAssertEqual(buckets[0].limitWindowSeconds, 2_678_400)
    }

    func testGrokBotIntegerUsagePercentDecodes() throws {
        let grokBot = try decodeGrokBot("""
        {"usagePercent":4,"hasNonZeroIncludedLimit":true,"includedLimitZero":false}
        """)
        let buckets = CursorLimits.buckets(from: try decode(), grokBot: grokBot)

        XCTAssertEqual(buckets.last?.kind, .grokBot)
        XCTAssertEqual(buckets.last?.usedPercent, 4)
        XCTAssertEqual(buckets.last?.limitWindowSeconds, CursorLimits.grokBotWindowSeconds)
    }

    func testGrokBotHiddenWithoutIncludedLimit() throws {
        let grokBot = try decodeGrokBot("""
        {"usagePercent":40,"hasNonZeroIncludedLimit":false}
        """)
        let buckets = CursorLimits.buckets(from: try decode(), grokBot: grokBot)

        XCTAssertEqual(buckets.map(\.kind), [.cursorModels, .otherModels])
    }

    func testGrokBotHiddenForPooledEnterprise() throws {
        let grokBot = try decodeGrokBot("""
        {
          "usagePercent": 12,
          "hasNonZeroIncludedLimit": true,
          "usesPooledEnterpriseAllowance": true
        }
        """)
        let buckets = CursorLimits.buckets(from: try decode(), grokBot: grokBot)

        XCTAssertEqual(buckets.map(\.kind), [.cursorModels, .otherModels])
    }

    func testGrokBotHiddenWhenIncludedLimitIsZero() throws {
        let grokBot = try decodeGrokBot("""
        {"usagePercent":8,"hasNonZeroIncludedLimit":true,"includedLimitZero":true}
        """)
        let buckets = CursorLimits.buckets(from: try decode(), grokBot: grokBot)

        XCTAssertEqual(buckets.map(\.kind), [.cursorModels, .otherModels])
    }

    func testMissingGrokBotLeavesMonthlyPoolsIntact() throws {
        let buckets = CursorLimits.buckets(from: try decode(), grokBot: nil)

        XCTAssertEqual(buckets.map(\.kind), [.cursorModels, .otherModels])
    }

    func testGrokBotHiddenWhenUsagePercentIsMissing() throws {
        let grokBot = try decodeGrokBot("""
        {"hasNonZeroIncludedLimit":true,"nextResetTimestampUtc":"2026-08-17T00:00:00.000Z"}
        """)
        let buckets = CursorLimits.buckets(from: try decode(), grokBot: grokBot)

        XCTAssertEqual(buckets.map(\.kind), [.cursorModels, .otherModels])
    }

    func testDisabledPeriodUsageCanStillShowGrokBot() throws {
        let disabled = """
        {"planUsage":{"autoPercentUsed":12,"apiPercentUsed":8},"enabled":false}
        """
        let response = try JSONDecoder().decode(CursorUsageResponse.self, from: Data(disabled.utf8))
        let grokBot = try decodeGrokBot("""
        {"usagePercent":10,"hasNonZeroIncludedLimit":true}
        """)
        let buckets = CursorLimits.buckets(from: response, grokBot: grokBot)

        XCTAssertEqual(buckets.map(\.kind), [.grokBot])
        XCTAssertEqual(buckets.map(\.displayName), ["Grok bot"])
    }

    @MainActor
    func testMenuBarStillUsesCursorModelsWhenGrokBotIsPresent() throws {
        let grokBot = try decodeGrokBot("""
        {"usagePercent":90,"hasNonZeroIncludedLimit":true}
        """)
        let model = UsageModel(
            previewBuckets: [],
            planType: "pro",
            lastUpdated: Date(),
            cursorBuckets: CursorLimits.buckets(from: try decode(), grokBot: grokBot),
            cursorPlan: "pro",
            menuBarProviders: [.cursor]
        )

        XCTAssertEqual(model.cursorModels?.kind, .cursorModels)
        XCTAssertEqual(model.menuBarCursorText, "58%")
        XCTAssertEqual(model.cursorBuckets.map(\.kind), [.cursorModels, .otherModels, .grokBot])
    }

    private func decodeGrokBot(_ json: String) throws -> CursorSandUsageStatus {
        try JSONDecoder().decode(CursorSandUsageStatus.self, from: Data(json.utf8))
    }
}
