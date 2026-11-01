import XCTest
@testable import UsageBar

final class CodexLimitsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_990_000)

    func testFreePlanShowsItsSingleMonthlyWindow() throws {
        let buckets = CodexLimits.buckets(from: try decode(CodexFixtures.freeObserved), now: now)

        XCTAssertEqual(buckets.map(\.kind), [.primary])
        XCTAssertEqual(buckets.map(\.name), ["Monthly Limit"])
        XCTAssertEqual(buckets.map(\.usedPercent), [26])
        XCTAssertEqual(buckets[0].resetAt, Date(timeIntervalSince1970: 1_796_156_839))
        XCTAssertEqual(buckets[0].resetAfterSeconds, 2_589_326)
        XCTAssertFalse(buckets[0].reached)
    }

    func testProAtLimitDecodesObjectReachedTypeAndShowsEveryRow() throws {
        let usage = try decode(CodexFixtures.proAtLimit)
        let buckets = CodexLimits.buckets(from: usage, now: now)

        XCTAssertEqual(usage.planType, "pro")
        XCTAssertEqual(usage.rateLimitReachedType, "rate_limit_reached")
        XCTAssertEqual(usage.rateLimitResetCredits?.availableCount, 2)
        XCTAssertEqual(buckets.map(\.kind), [.primary, .secondary, .balance, .additional])
        XCTAssertEqual(buckets.map(\.name), [
            "Current Session",
            "Weekly Limit",
            "Credits",
            "Model X Spark 5-Hour Limit",
        ])
        XCTAssertEqual(buckets.map(\.scope), [nil, nil, "credits", "additional.codex_bengalfox.primary"])
        XCTAssertEqual(buckets.map(\.usedPercent), [100, 64, 0, 12])
        XCTAssertEqual(buckets.map(\.reached), [true, false, false, false])
        XCTAssertEqual(buckets[2].detail, "1,251 credits")
        XCTAssertNil(buckets[2].resetAt)
    }

    func testWorkspaceMemberShowsCreditsAndMonthlyCreditLimit() throws {
        let usage = try decode(CodexFixtures.enterpriseMember)
        let buckets = CodexLimits.buckets(from: usage, now: now)

        XCTAssertEqual(usage.rateLimitReachedType, "workspace_member_usage_limit_reached")
        XCTAssertEqual(buckets.map(\.kind), [.balance, .spendLimit])
        XCTAssertEqual(buckets.map(\.name), ["Credits", "Monthly Credit Limit"])
        XCTAssertEqual(buckets.map(\.scope), ["credits", "spend-control"])
        XCTAssertEqual(buckets[0].detail, "Available")
        XCTAssertEqual(buckets[1].usedPercent, 100)
        XCTAssertTrue(buckets[1].reached)
        XCTAssertEqual(buckets[1].detail, "500 of 500 credits used")
        XCTAssertEqual(buckets[1].resetAt, Date(timeIntervalSince1970: 1_794_000_000))
        XCTAssertEqual(buckets[1].resetAfterSeconds, 864_000)
    }

    func testProWeeklyOnlyShowsOneWeeklyWindow() throws {
        let buckets = CodexLimits.buckets(from: try decode(CodexFixtures.proWeeklyOnly), now: now)

        XCTAssertEqual(buckets.map(\.kind), [.primary])
        XCTAssertEqual(buckets.map(\.name), ["Weekly Limit"])
        XCTAssertEqual(buckets.map(\.usedPercent), [42])
    }

    func testPlusShowsSessionAndWeeklyWindows() throws {
        let buckets = CodexLimits.buckets(from: try decode(CodexFixtures.plus), now: now)

        XCTAssertEqual(buckets.map(\.kind), [.primary, .secondary])
        XCTAssertEqual(buckets.map(\.name), ["Current Session", "Weekly Limit"])
        XCTAssertEqual(buckets.map(\.usedPercent), [30, 55])
        XCTAssertEqual(buckets.map(\.reached), [false, false])
    }

    func testReachedTypeInAnyShapeNeverFailsTheResponse() throws {
        let shapes = [
            #"{"type":"rate_limit_reached"}"#,
            #"{"type":"something_new"}"#,
            #"{"type":7}"#,
            #"{}"#,
            #""rate_limit_reached""#,
            "null",
            "42",
            "[1,2]",
        ]
        for shape in shapes {
            let usage = try decode("""
            {"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":604800}},
             "rate_limit_reached_type":\(shape)}
            """)
            XCTAssertEqual(CodexLimits.buckets(from: usage, now: now).map(\.usedPercent), [10], shape)
        }
    }

    func testUnknownPlanAndExtraFieldsAreIgnored() throws {
        let usage = try decode("""
        {"plan_type":"brand_new_plan","user_id":"user-x","model_usage":{"a":{"b":1}},
         "rate_limit_upsell":{"title":"x"},"promo":{"message":"x"},"code_review_rate_limit":{"anything":true},
         "rate_limit":{"allowed":true,"limit_reached":false,"future_flag":"x",
           "primary_window":{"used_percent":5,"limit_window_seconds":604800,"future_field":[1]}},
         "credits":{"has_credits":false,"unlimited":false,"overage_limit_reached":true,"balance":null}}
        """)

        XCTAssertEqual(usage.planType, "brand_new_plan")
        XCTAssertEqual(CodexLimits.buckets(from: usage, now: now).map(\.usedPercent), [5])
    }

    func testFractionalAndTextNumbersRoundAndClamp() throws {
        let usage = try decode("""
        {"rate_limit":{
          "primary_window":{"used_percent":42.6,"limit_window_seconds":18000.0,"reset_after_seconds":"600","reset_at":1793000000.4},
          "secondary_window":{"used_percent":"150","limit_window_seconds":"604800"}},
         "additional_rate_limits":[{"limit_name":"Model Y","rate_limit":{
          "primary_window":{"used_percent":-3,"limit_window_seconds":604800}}}]}
        """)
        let buckets = CodexLimits.buckets(from: usage, now: now)

        XCTAssertEqual(buckets.map(\.usedPercent), [43, 100, 0])
        XCTAssertEqual(buckets.map(\.name), ["Current Session", "Weekly Limit", "Model Y Weekly Limit"])
        XCTAssertEqual(buckets[0].resetAfterSeconds, 600)
        XCTAssertEqual(buckets[0].resetAt, Date(timeIntervalSince1970: 1_793_000_000))
        XCTAssertEqual(buckets.map(\.reached), [false, true, false])
    }

    func testWindowWithoutUsedPercentIsDroppedInsteadOfShownEmpty() throws {
        let usage = try decode("""
        {"rate_limit":{
          "primary_window":{"limit_window_seconds":18000,"reset_at":1793000000},
          "secondary_window":{"used_percent":20,"limit_window_seconds":604800}}}
        """)
        let buckets = CodexLimits.buckets(from: usage, now: now)

        XCTAssertEqual(buckets.map(\.kind), [.secondary])
        XCTAssertEqual(buckets.map(\.usedPercent), [20])
    }

    func testMalformedWindowDropsOnlyThatWindow() throws {
        let usage = try decode("""
        {"rate_limit":{"allowed":"yes",
          "primary_window":"broken",
          "secondary_window":{"used_percent":20,"limit_window_seconds":604800}},
         "credits":"broken","spend_control":7}
        """)
        let buckets = CodexLimits.buckets(from: usage, now: now)

        XCTAssertEqual(buckets.map(\.kind), [.secondary])
    }

    func testMalformedAdditionalEntryDropsOnlyThatEntry() throws {
        let usage = try decode("""
        {"additional_rate_limits":[
          "broken",
          42,
          {"limit_name":"Model Z","metered_feature":"feature_z",
           "rate_limit":{"primary_window":{"used_percent":15,"limit_window_seconds":604800}}},
          {"limit_name":"Model Q","rate_limit":"broken"}
        ]}
        """)
        let buckets = CodexLimits.buckets(from: usage, now: now)

        XCTAssertEqual(usage.additionalRateLimits?.count, 2)
        XCTAssertEqual(buckets.map(\.name), ["Model Z Weekly Limit"])
        XCTAssertEqual(buckets.map(\.scope), ["additional.feature_z.primary"])
    }

    func testOutOfRangeTimestampsAreIgnoredWithoutTrapping() throws {
        let usage = try decode("""
        {"rate_limit":{
          "primary_window":{"used_percent":10,"limit_window_seconds":1e300,"reset_at":1e300},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_at":"inf","reset_after_seconds":-50}},
         "spend_control":{"individual_limit":{"used_percent":10,"reset_at":-1e300,"reset_after_seconds":"1e300"}}}
        """)
        let buckets = CodexLimits.buckets(from: usage, now: now)

        XCTAssertEqual(buckets.map(\.kind), [.primary, .secondary, .spendLimit])
        XCTAssertNil(buckets[0].resetAt)
        XCTAssertEqual(buckets[0].name, "Primary Limit")
        XCTAssertEqual(buckets[1].resetAfterSeconds, 0)
        XCTAssertEqual(buckets[1].resetAt, now)
        XCTAssertNotNil(buckets[2].resetAt)
        XCTAssertLessThanOrEqual(buckets[2].resetAfterSeconds ?? 0, Int(CodexNumbers.maxSeconds))
    }

    func testEveryAdditionalLimitGetsItsOwnNamedRows() throws {
        let usage = try decode("""
        {"additional_rate_limits":[
          {"limit_name":"Model A","metered_feature":"feature_a","rate_limit":{
            "primary_window":{"used_percent":12,"limit_window_seconds":18000},
            "secondary_window":{"used_percent":34,"limit_window_seconds":604800}}},
          {"limit_name":"Model B","metered_feature":"feature_b","rate_limit":{
            "primary_window":{"used_percent":5,"limit_window_seconds":2592000}}},
          {"limit_name":"Model C","metered_feature":"feature_c","rate_limit":{
            "primary_window":{"used_percent":6,"limit_window_seconds":86400},
            "secondary_window":{"used_percent":7,"limit_window_seconds":31536000}}},
          {"limit_name":"gpt-reserve","metered_feature":"base_model_inference","rate_limit":{
            "primary_window":{"used_percent":0,"limit_window_seconds":604800}}},
          {"limit_name":"Model D","rate_limit":{
            "primary_window":{"used_percent":1},
            "secondary_window":{"used_percent":2}}}
        ]}
        """)
        let buckets = CodexLimits.buckets(from: usage, now: now)

        XCTAssertTrue(buckets.allSatisfy { $0.kind == .additional })
        XCTAssertEqual(buckets.map(\.name), [
            "Model A 5-Hour Limit",
            "Model A Weekly Limit",
            "Model B Monthly Limit",
            "Model C Daily Limit",
            "Model C Annual Limit",
            "gpt-reserve Weekly Limit",
            "Model D",
            "Model D Secondary Limit",
        ])
        XCTAssertEqual(buckets.map(\.scope), [
            "additional.feature_a.primary",
            "additional.feature_a.secondary",
            "additional.feature_b.primary",
            "additional.feature_c.primary",
            "additional.feature_c.secondary",
            "additional.base_model_inference.primary",
            "additional.Model D.primary",
            "additional.Model D.secondary",
        ])
        XCTAssertEqual(Set(buckets.map(\.id)).count, buckets.count)
    }

    func testRepeatedMeteredFeatureKeepsDistinctScopes() throws {
        let usage = try decode("""
        {"additional_rate_limits":[
          {"limit_name":"One","metered_feature":"shared","rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":604800}}},
          {"limit_name":"Two","metered_feature":"shared","rate_limit":{"primary_window":{"used_percent":2,"limit_window_seconds":604800}}}
        ]}
        """)
        let buckets = CodexLimits.buckets(from: usage, now: now)

        XCTAssertEqual(buckets.map(\.scope), ["additional.shared.primary", "additional.shared.1.primary"])
        XCTAssertNotEqual(buckets[0].id, buckets[1].id)
    }

    func testReachedComesFromEachWindowsOwnUsage() throws {
        let usage = try decode("""
        {"rate_limit":{"allowed":false,"limit_reached":true,
          "primary_window":{"used_percent":30,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":100,"limit_window_seconds":604800}}}
        """)
        let buckets = CodexLimits.buckets(from: usage, now: now)

        XCTAssertEqual(buckets.map(\.reached), [false, true])
    }

    func testBlockedLimitWithoutFullWindowMarksTheMostUsedWindow() throws {
        let usage = try decode("""
        {"rate_limit":{"allowed":false,"limit_reached":false,
          "primary_window":{"used_percent":97.4,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":40,"limit_window_seconds":604800}},
         "additional_rate_limits":[{"limit_name":"Model A","metered_feature":"feature_a","rate_limit":{
          "limit_reached":true,"primary_window":{"used_percent":90,"limit_window_seconds":604800}}}]}
        """)
        let buckets = CodexLimits.buckets(from: usage, now: now)

        XCTAssertEqual(buckets.map(\.reached), [true, false, true])
        XCTAssertEqual(buckets.map(\.usedPercent), [97, 40, 90])
    }

    func testSpendLimitBlockDoesNotMarkPlanWindows() throws {
        let usage = try decode("""
        {"rate_limit":{"allowed":false,"limit_reached":true,
          "primary_window":{"used_percent":50,"limit_window_seconds":604800}},
         "spend_control":{"reached":true,"individual_limit":{"limit":"2000","used":"1999.6","remaining_percent":1}},
         "rate_limit_reached_type":{"type":"workspace_member_usage_limit_reached"}}
        """)
        let buckets = CodexLimits.buckets(from: usage, now: now)

        XCTAssertEqual(buckets.map(\.kind), [.primary, .spendLimit])
        XCTAssertEqual(buckets.map(\.reached), [false, true])
        XCTAssertEqual(buckets[1].usedPercent, 99)
        XCTAssertEqual(buckets[1].detail, "2,000 of 2,000 credits used")
    }

    func testSpendLimitFallsBackToAmountsWhenPercentsAreMissing() throws {
        let usage = try decode("""
        {"spend_control":{"reached":false,"individual_limit":{"limit":400,"used":"100"}}}
        """)
        let buckets = CodexLimits.buckets(from: usage, now: now)

        XCTAssertEqual(buckets.map(\.usedPercent), [25])
        XCTAssertEqual(buckets.map(\.reached), [false])
        XCTAssertEqual(buckets[0].detail, "100 of 400 credits used")
    }

    func testSpendLimitWithoutAnyAmountIsHidden() throws {
        let usage = try decode("""
        {"spend_control":{"reached":false,"individual_limit":{"limit":"abc"}}}
        """)

        XCTAssertTrue(CodexLimits.buckets(from: usage, now: now).isEmpty)
    }

    func testCreditsRowShowsBalanceUnlimitedOrNothing() throws {
        let cases: [(String, String?)] = [
            (#"{"has_credits":true,"unlimited":true,"balance":"5"}"#, "Unlimited"),
            (#"{"has_credits":false,"unlimited":true}"#, "Unlimited"),
            (#"{"has_credits":true,"unlimited":false,"balance":"12345.4"}"#, "12,345 credits"),
            (#"{"has_credits":true,"unlimited":false,"balance":"1"}"#, "1 credit"),
            (#"{"has_credits":true,"unlimited":false,"balance":"0"}"#, "0 credits"),
            (#"{"has_credits":true,"unlimited":false,"balance":7.6}"#, "8 credits"),
            (#"{"has_credits":true,"unlimited":false,"balance":"abc"}"#, "Available"),
            (#"{"has_credits":true,"unlimited":false,"balance":null}"#, "Available"),
            (#"{"has_credits":false,"unlimited":false,"balance":"10"}"#, nil),
            (#"{}"#, nil),
        ]
        for (credits, expected) in cases {
            let usage = try decode(#"{"credits":\#(credits)}"#)
            let buckets = CodexLimits.buckets(from: usage, now: now)
            XCTAssertEqual(buckets.first?.detail, expected, credits)
            if expected != nil {
                XCTAssertEqual(buckets.map(\.kind), [.balance], credits)
                XCTAssertEqual(buckets.map(\.name), ["Credits"], credits)
                XCTAssertEqual(buckets.map(\.usedPercent), [0], credits)
                XCTAssertNil(buckets.first?.resetAt, credits)
            } else {
                XCTAssertTrue(buckets.isEmpty, credits)
            }
        }
    }

    func testRelabelingMigratesPersistedLowercaseNames() {
        let cases: [(LimitBucket.Kind, String, Int?, String)] = [
            (.primary, "daily", 86_400, "Daily Limit"),
            (.primary, "annual", 31_536_000, "Annual Limit"),
            (.primary, "primary", nil, "Primary Limit"),
            (.secondary, "secondary", 1_234, "Secondary Limit"),
            (.primary, "Current Session", 18_000, "Current Session"),
        ]
        for (kind, name, seconds, expected) in cases {
            let bucket = LimitBucket(
                kind: kind,
                name: name,
                usedPercent: 10,
                resetAt: nil,
                resetAfterSeconds: nil,
                limitWindowSeconds: seconds,
                reached: false
            )
            let relabeled = CodexLimits.relabeled(bucket)
            XCTAssertEqual(relabeled.name, expected, name)
            XCTAssertEqual(relabeled.id, bucket.id, name)
        }
    }

    @MainActor
    func testMenuBarIgnoresAdditionalLimitWithoutStandardWindow() {
        let model = UsageModel(
            previewBuckets: [
                LimitBucket(
                    kind: .additional,
                    scope: "additional.feature_a.primary",
                    name: "Model A Weekly Limit",
                    usedPercent: 10,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: 604_800,
                    reached: false
                )
            ],
            planType: "pro",
            lastUpdated: now
        )

        XCTAssertEqual(model.menuBarText, MenuBarSegment.placeholder)
        XCTAssertEqual(model.menuBarAccessibilityText, "not loaded")
    }

    @MainActor
    func testMenuBarFallsBackToSecondaryWindow() {
        let model = UsageModel(
            previewBuckets: [
                LimitBucket(
                    kind: .secondary,
                    name: "Weekly Limit",
                    usedPercent: 20,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: 604_800,
                    reached: false
                )
            ],
            planType: "pro",
            lastUpdated: now
        )

        XCTAssertEqual(model.menuBarText, "80%")
    }

    @MainActor
    func testMenuBarStaysOnWeeklyOnlyWindow() throws {
        let buckets = CodexLimits.buckets(from: try decode(CodexFixtures.proWeeklyOnly), now: now)
        let model = UsageModel(
            previewBuckets: buckets,
            planType: "pro",
            lastUpdated: now,
            now: { [now] in now }
        )

        XCTAssertEqual(model.menuBarText, "58%")
    }

    private func decode(_ payload: String) throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: Data(payload.utf8))
    }
}

enum CodexFixtures {
    static let freeObserved = """
    {"user_id":"user-x","account_id":"00000000-0000-0000-0000-000000000000","email":"user@example.com","plan_type":"free",
     "rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":26,"limit_window_seconds":2592000,"reset_after_seconds":2589326,"reset_at":1796156839},"secondary_window":null},
     "code_review_rate_limit":null,"additional_rate_limits":null,"model_usage":{},
     "credits":{"has_credits":false,"unlimited":false,"overage_limit_reached":false,"balance":null,"approx_local_messages":null,"approx_cloud_messages":null},
     "spend_control":{"reached":false,"individual_limit":null},"rate_limit_reached_type":null,"promo":null,
     "rate_limit_reset_credits":{"available_count":1,"applicable_available_count":0}}
    """

    static let proAtLimit = """
    {"plan_type":"pro",
     "rate_limit":{"allowed":false,"limit_reached":true,
       "primary_window":{"used_percent":100,"limit_window_seconds":18000,"reset_after_seconds":3600,"reset_at":1793000000},
       "secondary_window":{"used_percent":64,"limit_window_seconds":604800,"reset_after_seconds":400000,"reset_at":1793400000}},
     "credits":{"has_credits":true,"unlimited":false,"balance":"1250.5"},
     "spend_control":{"reached":false,"individual_limit":null},
     "additional_rate_limits":[{"limit_name":"Model X Spark","metered_feature":"codex_bengalfox","normal_model_slug":"model-x-spark",
       "rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_after_seconds":9000,"reset_at":1793005400},"secondary_window":null}}],
     "rate_limit_reached_type":{"type":"rate_limit_reached"},
     "rate_limit_reset_credits":{"available_count":2}}
    """

    static let enterpriseMember = """
    {"plan_type":"enterprise_cbp_usage_based","rate_limit":null,"credits":{"has_credits":true,"unlimited":false,"balance":null},
     "spend_control":{"reached":true,"individual_limit":{"limit":"500","used":"500","remaining":"0","used_percent":100,"remaining_percent":0,"reset_after_seconds":864000,"reset_at":1794000000}},
     "additional_rate_limits":null,"rate_limit_reached_type":{"type":"workspace_member_usage_limit_reached"}}
    """

    static let proWeeklyOnly = """
    {"plan_type":"pro",
     "rate_limit":{"allowed":true,"limit_reached":false,
       "primary_window":{"used_percent":42,"limit_window_seconds":604800,"reset_after_seconds":300000,"reset_at":1793300000},
       "secondary_window":null},
     "credits":{"has_credits":false,"unlimited":false,"balance":null},
     "spend_control":{"reached":false,"individual_limit":null},
     "additional_rate_limits":[],"rate_limit_reached_type":null}
    """

    static let plus = """
    {"plan_type":"plus",
     "rate_limit":{"allowed":true,"limit_reached":false,
       "primary_window":{"used_percent":30,"limit_window_seconds":18000,"reset_after_seconds":7200,"reset_at":1792997200},
       "secondary_window":{"used_percent":55,"limit_window_seconds":604800,"reset_after_seconds":200000,"reset_at":1793190000}},
     "credits":{"has_credits":false,"unlimited":false,"balance":null},
     "spend_control":{"reached":false,"individual_limit":null},
     "additional_rate_limits":null,"rate_limit_reached_type":null}
    """
}
