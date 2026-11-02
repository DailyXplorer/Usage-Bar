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

    private let unifiedSand = """
    {"currentPeriodStart":"2026-10-28T09:00:00Z","nextResetTimestampUtc":"2026-11-04T09:00:00Z","usagePercent":37.5,"hasAvailableUsage":true,"hasNonZeroIncludedLimit":true,"isTeamSeat":false,"cursorPlanName":"Ultra","isUnified":true,"billingBrand":"SAND_BILLING_BRAND_GROK","onDemandSettings":{"visible":true,"eligible":true,"enabled":false,"dashboardUrl":"https://cursor.com/dashboard/spending"},"unifiedBillingUrl":"https://grok.com/dashboard"}
    """

    private let unifiedPeriod = """
    {"billingCycleStart":"1790928000000","billingCycleEnd":"1793520000000","planUsage":{"totalSpend":1500,"includedSpend":1500,"limit":40000,"autoPercentUsed":30,"apiPercentUsed":0,"totalPercentUsed":37.5},"spendLimitUsage":{"individualLimit":5000,"individualUsed":1200,"individualRemaining":3800,"limitType":"user"},"enabled":true}
    """

    private let pendingMergeSand = """
    {"usagePercent":0,"hasNonZeroIncludedLimit":false,"isUnified":false,"unifyPendingMerge":{"state":"UNIFY_PENDING_MERGE_STATE_IN_PROGRESS"},"unifyPendingMergeUnread":true}
    """

    private let weeklyPlanInfo = """
    {"planInfo":{"planName":"Ultra","includedAmountCents":40000,"billingCycleEnd":"1793520000000","includedUsagePeriod":"INCLUDED_USAGE_PERIOD_WEEKLY","includedUsageResetsAt":"1793952000000"},"isMerged":true}
    """

    private let observedLegacySand = """
    {
      "currentPeriodStart": "2026-08-26T17:22:03.913Z",
      "nextResetTimestampUtc": "2026-09-01T17:46:41.504Z",
      "usagePercent": 49.290432,
      "hasAvailableUsage": true,
      "hasNonZeroIncludedLimit": true,
      "upgradeRecommendation": {
        "cta": {"label": "Upgrade to Ultra", "url": {"url": "https://cursor.com/api/auth/checkoutDeepControl?tier=ultra"}},
        "supportingText": "Get $1,000 of Grok Bot usage each week with Ultra",
        "kind": "upgrade-to-ultra-for-more-usage"
      },
      "onDemandSettings": {"visible": true, "eligible": true, "dashboardUrl": "https://cursor.com/dashboard/spending"},
      "grokPlanLabel": "Grok Bot Plan"
    }
    """

    private func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func layout(
        period: String? = nil,
        sand: String? = nil,
        planInfo: String? = nil,
        membership: String? = "pro",
        now: Date = Date(timeIntervalSince1970: 1_786_566_047)
    ) throws -> CursorLayout {
        let snapshot = CursorUsageSnapshot(
            period: try decode(period ?? payload),
            sand: try sand.map { try decode($0) },
            planInfo: try planInfo.map { try decode($0) },
            membershipType: membership
        )
        return CursorLimits.layout(for: snapshot, now: now)
    }

    func testLegacyBucketsMatchCursorDashboardPools() throws {
        let buckets = try layout().buckets

        XCTAssertEqual(buckets.map(\.kind), [.cursorModels, .otherModels])
        XCTAssertEqual(buckets.map(\.displayName), ["Cursor Models", "Other Models"])
        XCTAssertEqual(buckets.map(\.usedPercent), [42, 11])
        XCTAssertEqual(buckets.map(\.remainingPercent), [58, 89])
        XCTAssertTrue(buckets.allSatisfy { $0.provider == .cursor })
        XCTAssertTrue(buckets.allSatisfy { $0.detail == nil })
    }

    func testLegacyResetCountdownUsesBillingCycleEndWithoutWeeklyPlanInfo() throws {
        let buckets = try layout(now: Date(timeIntervalSince1970: 1_786_566_047.085)).buckets

        XCTAssertEqual(buckets[0].resetAfterSeconds, 2_678_400)
        XCTAssertEqual(buckets[0].limitWindowSeconds, 2_678_400)
    }

    func testLegacyWeeklyPlanTakesResetFromPlanInfo() throws {
        let now = Date(timeIntervalSince1970: 1_793_500_000)
        let buckets = try layout(period: unifiedPeriod, planInfo: weeklyPlanInfo, now: now).buckets

        XCTAssertEqual(buckets.map(\.kind), [.cursorModels, .otherModels])
        XCTAssertEqual(buckets[0].resetAt, Date(timeIntervalSince1970: 1_793_952_000))
        XCTAssertEqual(buckets[0].limitWindowSeconds, CursorLimits.weekSeconds)
        XCTAssertEqual(buckets[0].resetAfterSeconds, 452_000)
    }

    func testPlanInfoAcceptsShortWeeklyEnum() throws {
        let info: CursorPlanInfoResponse = try decode("""
        {"planInfo":{"includedUsagePeriod":"WEEKLY","includedUsageResetsAt":1793952000000}}
        """)

        XCTAssertEqual(info.weeklyResetAt, Date(timeIntervalSince1970: 1_793_952_000))
    }

    func testMonthlyPlanInfoKeepsBillingCycleEnd() throws {
        let monthly = """
        {"planInfo":{"includedUsagePeriod":"INCLUDED_USAGE_PERIOD_MONTHLY","includedUsageResetsAt":"1793952000000"}}
        """
        let buckets = try layout(planInfo: monthly).buckets

        XCTAssertEqual(buckets[0].resetAt, CursorTimestamp.parse("1789244447085"))
    }

    func testCursorModelsPercentUsedAliasIsAccepted() throws {
        let aliased = """
        {"billingCycleStart":"1786566047085","billingCycleEnd":"1789244447085",
         "planUsage":{"cursorModelsPercentUsed":7,"apiPercentUsed":3},"enabled":true}
        """

        XCTAssertEqual(try layout(period: aliased).buckets.map(\.remainingPercent), [93, 97])
    }

    func testNumericCycleTimestampsDecode() throws {
        let numeric = """
        {"billingCycleStart":1786566047085,"billingCycleEnd":1789244447085,
         "planUsage":{"autoPercentUsed":0,"apiPercentUsed":0},"enabled":true}
        """
        let buckets = try layout(period: numeric).buckets

        XCTAssertEqual(buckets.count, 2)
        XCTAssertNotNil(buckets[0].resetAt)
    }

    func testDisabledResponseYieldsNoBuckets() throws {
        let disabled = """
        {"planUsage":{"autoPercentUsed":12,"apiPercentUsed":8},"enabled":false}
        """

        XCTAssertTrue(try layout(period: disabled).buckets.isEmpty)
    }

    func testUnifiedAccountShowsOneWeeklyBarAndAdditionalUsage() throws {
        let now = try XCTUnwrap(ISODate.parse("2026-10-30T09:00:00Z"))
        let result = try layout(period: unifiedPeriod, sand: unifiedSand, membership: "pro", now: now)

        XCTAssertEqual(result.buckets.map(\.kind), [.weekly, .other])
        XCTAssertEqual(result.plan, "Ultra")
        XCTAssertNil(result.notice)

        let weekly = result.buckets[0]
        XCTAssertEqual(weekly.name, "Weekly usage")
        XCTAssertEqual(weekly.usedPercent, 38)
        XCTAssertEqual(weekly.resetAt, ISODate.parse("2026-11-04T09:00:00Z"))
        XCTAssertEqual(weekly.limitWindowSeconds, CursorLimits.weekSeconds)
        XCTAssertEqual(weekly.resetAfterSeconds, 5 * 24 * 60 * 60)

        let additional = result.buckets[1]
        XCTAssertEqual(additional.name, "Additional usage")
        XCTAssertEqual(additional.usedPercent, 24)
        XCTAssertEqual(additional.detail, "$12.00 / $50.00")
        XCTAssertEqual(additional.resetAt, Date(timeIntervalSince1970: 1_793_520_000))
    }

    func testUnifiedAccountHidesModelPoolsAndGrokBot() throws {
        let kinds = try layout(period: unifiedPeriod, sand: unifiedSand).buckets.map(\.kind)

        XCTAssertFalse(kinds.contains(.cursorModels))
        XCTAssertFalse(kinds.contains(.otherModels))
        XCTAssertFalse(kinds.contains(.grokBot))
    }

    func testUnifiedAccountWithoutSpendLimitHasNoAdditionalUsageRow() throws {
        let buckets = try layout(sand: unifiedSand).buckets

        XCTAssertEqual(buckets.map(\.kind), [.weekly])
    }

    func testBillingBrandAcceptsLongAndShortEnumNames() throws {
        let long: CursorSandUsageStatus = try decode(unifiedSand)
        let short: CursorSandUsageStatus = try decode(#"{"isUnified":true,"billingBrand":"grok","usagePercent":5}"#)

        XCTAssertEqual(long.billingBrand, "GROK")
        XCTAssertEqual(short.billingBrand, "GROK")
        XCTAssertEqual(try layout(sand: #"{"isUnified":true,"billingBrand":"grok","usagePercent":5}"#).buckets.map(\.kind), [.weekly])
    }

    func testUnknownEnumAndExtraFieldsDoNotFailDecoding() throws {
        let sand: CursorSandUsageStatus = try decode("""
        {"isUnified":true,"billingBrand":"SAND_BILLING_BRAND_SOMETHING_NEW","usagePercent":"12.5",
         "unifiedUpsellButtons":[{"label":"x"}],"futureField":{"a":[1,2]}}
        """)

        XCTAssertEqual(sand.billingBrand, "SOMETHING_NEW")
        XCTAssertEqual(sand.usagePercent, 12.5)
    }

    func testPooledEnterpriseUnifiedAccountShowsNoWeeklyBar() throws {
        let sand = #"{"isUnified":true,"usagePercent":40,"usesPooledEnterpriseAllowance":true}"#

        XCTAssertTrue(try layout(sand: sand).buckets.isEmpty)
    }

    func testPendingMergeShowsMessageInsteadOfZeroBar() throws {
        let result = try layout(sand: pendingMergeSand)

        XCTAssertEqual(result.notice, CursorLimits.accountMergeNotice)
        XCTAssertFalse(result.buckets.contains { $0.kind == .grokBot || $0.kind == .weekly })
        XCTAssertEqual(result.buckets.map(\.kind), [.cursorModels, .otherModels])
    }

    func testPendingMergeWithoutStateStillCounts() throws {
        let sand: CursorSandUsageStatus = try decode(#"{"isUnified":false,"unifyPendingMerge":{}}"#)

        XCTAssertTrue(sand.isPendingMerge)
    }

    @MainActor
    func testPendingMergeWithoutPoolsShowsTheMergeMessage() async throws {
        let suiteName = "CursorLimitsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        ProviderPreferences(popover: [.cursor], menuBar: [.cursor]).save(to: defaults)
        let snapshot = CursorUsageSnapshot(
            period: try decode(#"{"enabled":true}"#),
            sand: try decode(pendingMergeSand),
            planInfo: nil,
            membershipType: nil
        )
        let model = UsageModel(
            defaults: defaults,
            fetcher: UsageFetcher { _ in .cursor(snapshot) },
            now: { Date(timeIntervalSince1970: 1_786_566_047) },
            automaticallySchedules: false
        )
        model.refreshNow(force: true)
        for _ in 0..<200 where model.isLoading {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(model.sectionMessage(for: .cursor), CursorLimits.accountMergeNotice)
        XCTAssertNil(model.menuBarCursorText)
    }

    func testLegacySeparateGrokBotPoolFromObservedBody() throws {
        let now = try XCTUnwrap(ISODate.parse("2026-08-28T12:00:00Z"))
        let buckets = try layout(sand: observedLegacySand, now: now).buckets
        let grok = try XCTUnwrap(buckets.first { $0.kind == .grokBot })
        let expectedReset = try XCTUnwrap(CursorTimestamp.parse("2026-09-01T17:46:41.504Z"))

        XCTAssertEqual(buckets.map(\.kind), [.cursorModels, .otherModels, .grokBot])
        XCTAssertEqual(grok.name, "Grok Bot")
        XCTAssertEqual(grok.usedPercent, 49)
        XCTAssertEqual(grok.resetAt, expectedReset)
        XCTAssertEqual(grok.resetAfterSeconds, max(0, Int(expectedReset.timeIntervalSince(now).rounded())))
    }

    func testLegacyGrokBotNeedsASeparateNonZeroPool() throws {
        let hidden = [
            #"{"usagePercent":20}"#,
            #"{"usagePercent":20,"hasNonZeroIncludedLimit":false}"#,
            #"{"usagePercent":20,"hasNonZeroIncludedLimit":true,"includedLimitZero":true}"#,
            #"{"usagePercent":20,"hasNonZeroIncludedLimit":true,"usesPooledEnterpriseAllowance":true}"#,
            #"{"hasNonZeroIncludedLimit":true}"#,
        ]
        for sand in hidden {
            XCTAssertFalse(try layout(sand: sand).buckets.contains { $0.kind == .grokBot }, sand)
        }
        let shown = #"{"usagePercent":100,"hasNonZeroIncludedLimit":true}"#
        let grok = try XCTUnwrap(try layout(sand: shown).buckets.first { $0.kind == .grokBot })
        XCTAssertTrue(grok.reached)
        XCTAssertEqual(grok.limitWindowSeconds, CursorLimits.weekSeconds)
    }

    func testOutOfRangeTimestampsAndNaNDoNotCrash() throws {
        let period = """
        {"billingCycleStart":"1e300","billingCycleEnd":"-1e300","planUsage":{"autoPercentUsed":"NaN","apiPercentUsed":"12"},"spendLimitUsage":"broken","enabled":true}
        """
        let sand = #"{"isUnified":true,"usagePercent":10,"nextResetTimestampUtc":"1e300","currentPeriodStart":1e300}"#
        let unified = try layout(period: period, sand: sand)
        let legacy = try layout(period: period)

        XCTAssertNil(unified.buckets.first?.resetAt)
        XCTAssertEqual(unified.buckets.map(\.kind), [.weekly])
        XCTAssertEqual(legacy.buckets.map(\.kind), [.otherModels])
        XCTAssertNil(legacy.buckets.first?.resetAt)
    }

    @MainActor
    func testMenuBarUsesWeeklyPoolForUnifiedAccounts() throws {
        let model = UsageModel(
            previewBuckets: [],
            planType: "free",
            lastUpdated: Date(),
            cursorBuckets: try layout(period: unifiedPeriod, sand: unifiedSand).buckets,
            cursorPlan: "Ultra",
            menuBarProviders: [.cursor]
        )

        XCTAssertEqual(model.cursorMenuBarBucket?.kind, LimitBucket.Kind.weekly)
        XCTAssertEqual(model.menuBarCursorText, "62%")
        XCTAssertEqual(model.menuBarCursorAccessibilityText, "Cursor weekly usage, 62 percent left")
    }

    @MainActor
    func testMenuBarUsesCursorModelsPoolForLegacyAccounts() throws {
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
            cursorBuckets: try layout(sand: observedLegacySand).buckets,
            cursorPlan: "pro",
            menuBarProviders: [.codex, .cursor]
        )

        XCTAssertEqual(model.menuBarText, "99%")
        XCTAssertEqual(model.menuBarCursorText, "58%")
        XCTAssertEqual(model.cursorMenuBarBucket?.kind, .cursorModels)
        XCTAssertEqual(model.menuBarSegments.map(\.value), ["99%", "58%"])
        XCTAssertEqual(model.menuBarCursorAccessibilityText, "Cursor models, 58 percent left")
    }

    @MainActor
    func testMenuBarOmitsCursorPercentWhenOnlyGrokBotIsPresent() throws {
        let disabled = #"{"enabled":false}"#
        let model = UsageModel(
            previewBuckets: [],
            planType: "pro",
            lastUpdated: Date(),
            cursorBuckets: try layout(period: disabled, sand: observedLegacySand).buckets,
            cursorPlan: "pro",
            menuBarProviders: [.cursor]
        )

        XCTAssertEqual(model.cursorBuckets.map(\.kind), [.grokBot])
        XCTAssertNil(model.menuBarCursorText)
    }

    @MainActor
    func testEmptyStateExplainsHowToSignIn() {
        let model = UsageModel(
            previewBuckets: [],
            planType: "pro",
            lastUpdated: Date(),
            menuBarProviders: [.cursor],
            errorMessage: "ChatGPT is unreachable.",
            cursorAvailable: false
        )

        XCTAssertEqual(model.visibleEmptyStateMessage, CursorUsageError.notSignedIn.errorDescription)
        XCTAssertEqual(
            model.visibleEmptyStateMessage,
            "Not signed in to Cursor. Sign in to the Cursor editor, or paste a Cursor session token in Settings."
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

    func testErrorTextHasNoStatusCodesOrExceptionText() {
        let errors: [CursorUsageError] = [
            .notSignedIn, .unreadableLogin, .tokenExpired, .throttled(retryAfter: nil),
            .network("The request timed out."), .httpStatus(503), .decoding("keyNotFound"),
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.contains("503"), text)
            XCTAssertFalse(text.contains("timed out"), text)
            XCTAssertFalse(text.contains("keyNotFound"), text)
            XCTAssertFalse(text.contains("HTTP"), text)
        }
    }
}
