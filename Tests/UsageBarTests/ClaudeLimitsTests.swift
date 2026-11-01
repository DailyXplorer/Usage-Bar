import XCTest
@testable import UsageBar

enum ClaudeFixtures {
    static let withSession = """
    {"five_hour":{"utilization":32.0,"resets_at":"2026-11-02T01:20:00.487993+00:00"},
     "seven_day":{"utilization":6.0,"resets_at":"2026-11-04T21:00:00.488014+00:00"},
     "seven_day_opus":null,"seven_day_sonnet":null,
     "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null,"currency":null},
     "limits":[
      {"kind":"session","group":"session","percent":32,"severity":"normal","resets_at":"2026-11-02T01:20:00.487993+00:00","scope":null,"is_active":true},
      {"kind":"weekly_all","group":"weekly","percent":6,"severity":"normal","resets_at":"2026-11-04T21:00:00.488014+00:00","scope":null,"is_active":false},
      {"kind":"weekly_scoped","group":"weekly","percent":0,"severity":"normal","resets_at":"2026-11-04T21:00:00+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}],
     "weekly_scoped_shares":[{"limit_index":2,"used_percent_of_weekly":0,"allowance_percent_of_weekly":50}]}
    """

    static let withoutSession = """
    {"five_hour":null,
     "seven_day":{"utilization":75.0,"resets_at":"2026-11-02T23:00:00.000000+00:00"},
     "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1250,"utilization":25.0,"currency":"USD"},
     "limits":[
      {"kind":"weekly_all","group":"weekly","percent":75,"severity":"normal","resets_at":"2026-11-02T23:00:00.000000+00:00","scope":null,"is_active":true},
      {"kind":"weekly_scoped","group":"weekly","percent":0,"severity":"normal","resets_at":"2026-11-02T23:00:00+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]}
    """

    static let legacyOnly = """
    {"five_hour":{"utilization":25.0,"resets_at":"2026-11-02T01:20:00Z"},
     "seven_day":{"utilization":40.0,"resets_at":"2026-11-04T21:00:00Z"},
     "seven_day_sonnet":{"utilization":10.0,"resets_at":"2026-11-04T21:00:00Z"},
     "seven_day_opus":null}
    """

    static let credits = """
    {"cinder_cove":{"utilization":12.0,"resets_at":"2026-11-30T00:00:00Z"},
     "wattle_ember":{"utilization":30.0,"resets_at":"2026-11-30T00:00:00Z","label":"Credit","limit_dollars":50.0,"used_dollars":15.0,"remaining_dollars":35.0,"periods":[{"starts_at":"2026-11-01T00:00:00Z","ends_at":"2026-11-30T00:00:00Z"}]},
     "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1250,"utilization":25.0,"currency":"USD","disabled_reason":null}}
    """

    static let unifiedHeaders: [AnyHashable: Any] = [
        "anthropic-ratelimit-unified-status": "allowed",
        "anthropic-ratelimit-unified-representative-claim": "five_hour",
        "anthropic-ratelimit-unified-reset": "1793582400",
        "anthropic-ratelimit-unified-5h-status": "allowed",
        "Anthropic-Ratelimit-Unified-5h-Utilization": "0.32",
        "anthropic-ratelimit-unified-5h-reset": "1793582400",
        "anthropic-ratelimit-unified-7d-status": "allowed",
        "anthropic-ratelimit-unified-7d-utilization": "0.06",
        "anthropic-ratelimit-unified-7d-reset": "1793826000",
        "anthropic-ratelimit-unified-overage-status": "rejected",
        "anthropic-ratelimit-unified-overage-disabled-reason": "org_level_disabled",
    ]

    static func decode(_ json: String) throws -> ClaudeUsageResponse {
        try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
    }
}

final class ClaudeLimitsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_500_000)

    func testAccountWithSessionListsClaudeCodeUsageRows() throws {
        let buckets = ClaudeLimits.buckets(from: try ClaudeFixtures.decode(ClaudeFixtures.withSession), now: now)

        XCTAssertEqual(buckets.map(\.kind), [.session, .weeklyAll, .weeklyScoped])
        XCTAssertEqual(buckets.map(\.displayName), [
            "Current session",
            "Current week (all models)",
            "Current week (Fable)",
        ])
        XCTAssertEqual(buckets.map(\.remainingPercent), [68, 94, 100])
        XCTAssertEqual(buckets.map(\.isActive), [true, false, false])
        XCTAssertTrue(buckets.allSatisfy { $0.provider == .claude })
    }

    func testAccountWithoutSessionNeverInventsASessionRow() throws {
        let buckets = ClaudeLimits.buckets(from: try ClaudeFixtures.decode(ClaudeFixtures.withoutSession), now: now)

        XCTAssertEqual(buckets.map(\.kind), [.weeklyAll, .weeklyScoped, .spendLimit])
        XCTAssertFalse(buckets.contains { $0.kind == .session })
        XCTAssertEqual(buckets[0].remainingPercent, 25)
        XCTAssertTrue(buckets[0].isActive)
    }

    func testUsageCreditsShowSpendInTheAccountCurrency() throws {
        let buckets = ClaudeLimits.buckets(from: try ClaudeFixtures.decode(ClaudeFixtures.credits), now: now)

        let credits = try XCTUnwrap(buckets.first { $0.kind == .spendLimit })
        XCTAssertEqual(credits.name, "Usage credits")
        XCTAssertEqual(credits.usedPercent, 25)
        XCTAssertEqual(credits.detail, "$12.50 / $50.00 spent")
        XCTAssertNil(credits.resetAt)
        XCTAssertFalse(credits.drivesMenuBar)

        let creditWindows = buckets.filter { $0.kind == .credit }
        XCTAssertEqual(creditWindows.map(\.name), ["Claude Code and Cowork credit", "Credit"])
        XCTAssertEqual(creditWindows.map(\.usedPercent), [12, 30])
        XCTAssertEqual(creditWindows[1].detail, "$15.00 / $50.00 spent")
    }

    func testDisabledOrUnlimitedUsageCredits() throws {
        let disabled = try ClaudeFixtures.decode(ClaudeFixtures.withSession)
        XCTAssertFalse(ClaudeLimits.buckets(from: disabled, now: now).contains { $0.name == "Usage credits" })

        let unlimited = try ClaudeFixtures.decode(
            #"{"seven_day":{"utilization":5},"extra_usage":{"is_enabled":true,"monthly_limit":null,"used_credits":0}}"#
        )
        let row = try XCTUnwrap(ClaudeLimits.buckets(from: unlimited, now: now).first { $0.name == "Usage credits" })
        XCTAssertEqual(row.kind, .balance)
        XCTAssertEqual(row.detail, "Unlimited")
    }

    func testLegacyWindowsAreTheFallbackWhenLimitsIsAbsent() throws {
        let buckets = ClaudeLimits.buckets(from: try ClaudeFixtures.decode(ClaudeFixtures.legacyOnly), now: now)

        XCTAssertEqual(buckets.map(\.kind), [.session, .weeklyAll, .weeklyScoped])
        XCTAssertEqual(buckets.map(\.remainingPercent), [75, 60, 90])
        XCTAssertEqual(buckets[2].displayName, "Current week (Sonnet)")
    }

    func testLegacyWindowsAreUsedWhenNoLimitEntryHasAPercent() throws {
        let response = try ClaudeFixtures.decode("""
        {"five_hour":{"utilization":12,"resets_at":"2026-11-02T01:20:00Z"},
         "limits":[{"kind":"session","group":"session"},{"kind":"weekly_all","percent":null}]}
        """)

        let buckets = ClaudeLimits.buckets(from: response, now: now)

        XCTAssertEqual(buckets.map(\.kind), [.session])
        XCTAssertEqual(buckets[0].usedPercent, 12)
    }

    func testMalformedLimitEntryDropsOnlyThatEntry() throws {
        let response = try ClaudeFixtures.decode("""
        {"limits":[
          "garbage",
          {"kind":"weekly_all","group":"weekly","percent":"40","resets_at":1793600000},
          {"kind":"session","percent":{"value":3}},
          {"kind":"weekly_scoped","percent":7.6,"scope":{"model":"not-an-object"},"is_active":"yes"}
        ]}
        """)

        let buckets = ClaudeLimits.buckets(from: response, now: now)

        XCTAssertEqual(buckets.map(\.kind), [.weeklyAll, .weeklyScoped])
        XCTAssertEqual(buckets[0].usedPercent, 40)
        XCTAssertEqual(buckets[0].resetAt, Date(timeIntervalSince1970: 1_793_600_000))
        XCTAssertEqual(buckets[1].usedPercent, 8)
        XCTAssertEqual(buckets[1].displayName, "Current week (one model)")
    }

    func testUnknownKindsGetAReadableLabelAndAreKept() throws {
        let response = try ClaudeFixtures.decode(
            #"{"limits":[{"kind":"daily_routines","group":"daily","percent":10},{"kind":"monthly_credits","percent":20}]}"#
        )
        let first = ClaudeLimits.buckets(from: response, now: now)
        let second = ClaudeLimits.buckets(from: response, now: now)

        XCTAssertEqual(first.map(\.displayName), ["Daily routines", "Monthly credits"])
        XCTAssertEqual(first[0].limitWindowSeconds, 86_400)
        XCTAssertEqual(Set(first.map(\.id)).count, 2)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    func testBodyWithNoWindowGivesNoBuckets() throws {
        let response = try ClaudeFixtures.decode(#"{"five_hour":null,"seven_day":null,"limits":[]}"#)
        XCTAssertTrue(ClaudeLimits.buckets(from: response, now: now).isEmpty)
    }

    func testReachedIsFlaggedAtFullUtilization() throws {
        let response = try ClaudeFixtures.decode(
            #"{"limits":[{"kind":"weekly_all","percent":100},{"kind":"weekly_scoped","percent":99.4}]}"#
        )
        XCTAssertEqual(ClaudeLimits.buckets(from: response, now: now).map(\.reached), [true, false])
    }

    func testScopedModelIDsDisambiguateMatchingDisplayNames() throws {
        let response = try ClaudeFixtures.decode("""
        {"limits":[
          {"kind":"weekly_scoped","percent":10,"scope":{"model":{"id":"model-a","display_name":"Claude"}}},
          {"kind":"weekly_scoped","percent":20,"scope":{"model":{"id":"model-b","display_name":"Claude"}}}
        ]}
        """)
        let buckets = ClaudeLimits.buckets(from: response, now: now)

        XCTAssertEqual(buckets.map(\.scope), ["model:model-a", "model:model-b"])
        XCTAssertNotEqual(buckets[0].id, buckets[1].id)
    }

    func testUnifiedHeadersBecomeUsageWindows() throws {
        let response = try XCTUnwrap(ClaudeUnifiedHeaders.response(
            from: ClaudeFixtures.unifiedHeaders,
            scopedModelName: "Fable"
        ))
        let buckets = ClaudeLimits.buckets(from: response, now: now)

        XCTAssertEqual(buckets.map(\.kind), [.session, .weeklyAll])
        XCTAssertEqual(buckets.map(\.usedPercent), [32, 6])
        XCTAssertEqual(buckets[0].resetAt, Date(timeIntervalSince1970: 1_793_582_400))
        XCTAssertEqual(buckets[1].resetAt, Date(timeIntervalSince1970: 1_793_826_000))
        XCTAssertEqual(buckets.map(\.isActive), [true, false])
    }

    func testUnifiedHeadersWithIncludedModelsWindowMapToTheScopedRow() throws {
        var headers = ClaudeFixtures.unifiedHeaders
        headers["anthropic-ratelimit-unified-7d_oi-utilization"] = "1.02"
        headers["anthropic-ratelimit-unified-7d_oi-reset"] = "1793826000"
        headers["anthropic-ratelimit-unified-representative-claim"] = "seven_day_overage_included"

        let response = try XCTUnwrap(ClaudeUnifiedHeaders.response(from: headers, scopedModelName: "Fable"))
        let scoped = try XCTUnwrap(ClaudeLimits.buckets(from: response, now: now).first { $0.kind == .weeklyScoped })

        XCTAssertEqual(scoped.displayName, "Current week (Fable)")
        XCTAssertEqual(scoped.usedPercent, 100)
        XCTAssertTrue(scoped.reached)
        XCTAssertTrue(scoped.isActive)
    }

    func testHeadersWithoutWindowsGiveNothing() {
        XCTAssertNil(ClaudeUnifiedHeaders.response(
            from: ["anthropic-ratelimit-unified-status": "allowed"],
            scopedModelName: nil
        ))
    }

    func testQuotaCheckKeepsRowsItCannotSee() throws {
        let previous = ClaudeLimits.buckets(from: try ClaudeFixtures.decode(ClaudeFixtures.withSession), now: now)
        let fresh = ClaudeLimits.buckets(
            from: try XCTUnwrap(ClaudeUnifiedHeaders.response(from: ClaudeFixtures.unifiedHeaders, scopedModelName: nil)),
            now: now
        )

        let merged = ClaudeLimits.merged(fresh: fresh, previous: previous, now: now, previousFetchedAt: now)

        XCTAssertEqual(merged.map(\.kind), [.session, .weeklyAll, .weeklyScoped])
        XCTAssertEqual(merged.filter(\.isActive).count, 1)
    }

    func testQuotaCheckNeverRevivesAKeptRowThatResetMeanwhile() {
        let fetchedAt = now.addingTimeInterval(-3_600)
        let fable = LimitBucket(
            provider: .claude, kind: .weeklyScoped, scope: "model-name:fable", name: "Current week (Fable)",
            usedPercent: 100, resetAt: now.addingTimeInterval(-600), resetAfterSeconds: 0,
            limitWindowSeconds: 604_800, reached: true, isActive: true
        )

        let merged = ClaudeLimits.merged(fresh: [], previous: [fable], now: now, previousFetchedAt: fetchedAt)

        XCTAssertEqual(merged.map(\.remainingPercent), [100])
        XCTAssertEqual(merged.map(\.reached), [false])
        XCTAssertEqual(merged.map(\.isActive), [false])
    }

    func testRelabeledRewritesCachedNames() {
        XCTAssertEqual(ClaudeLimits.relabeled(cached(.session, "Current Session")).name, "Current session")
        XCTAssertEqual(ClaudeLimits.relabeled(cached(.session, "Session 5h")).name, "Current session")
        XCTAssertEqual(ClaudeLimits.relabeled(cached(.weeklyAll, "All Models")).name, "Current week (all models)")
        XCTAssertEqual(ClaudeLimits.relabeled(cached(.weeklyScoped, "Week · Fable")).name, "Current week (Fable)")
        XCTAssertEqual(ClaudeLimits.relabeled(cached(.weeklyScoped, "Fable")).name, "Current week (Fable)")
        XCTAssertEqual(ClaudeLimits.relabeled(cached(.weeklyScoped, "Pinned Model")).name, "Current week (one model)")
        XCTAssertEqual(
            ClaudeLimits.relabeled(cached(.weeklyScoped, "Current week (Fable)")).name,
            "Current week (Fable)"
        )
    }

    func testISODateParsesSixDigitFractionalSeconds() {
        let date = ISODate.parse("2026-08-08T23:40:00.397667+00:00")

        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_786_232_400.397, accuracy: 0.01)
        XCTAssertNotNil(ISODate.parse("2026-08-08T23:40:00Z"))
        XCTAssertNil(ISODate.parse(nil))
        XCTAssertNil(ISODate.parse("soon"))
    }

    @MainActor
    func testMenuBarPrefersTheActiveLimit() throws {
        let model = claudeModel(ClaudeFixtures.withSession)

        XCTAssertEqual(model.menuBarClaudeText, "68%")
        XCTAssertEqual(model.menuBarClaudeAccessibilityText, "Claude session limit, 68 percent left")
    }

    @MainActor
    func testMenuBarShowsTheWeeklyLimitWithoutASessionWindow() throws {
        let model = claudeModel(ClaudeFixtures.withoutSession)

        XCTAssertEqual(model.menuBarClaudeText, "25%")
        XCTAssertEqual(model.menuBarClaudeDisplay, "25%")
        XCTAssertEqual(model.menuBarClaudeAccessibilityText, "Claude weekly limit, 25 percent left")
        XCTAssertEqual(model.menuBarSegments.map(\.value), ["58%", "25%"])
    }

    @MainActor
    func testMenuBarFallsBackFromSessionToWeeklyToMostUsedModel() {
        let session = bucket(.session, used: 10)
        let weekly = bucket(.weeklyAll, used: 30)
        let fable = bucket(.weeklyScoped, used: 70, name: "Current week (Fable)")
        let sonnet = bucket(.weeklyScoped, used: 20, name: "Current week (Sonnet)")

        XCTAssertEqual(model(with: [weekly, session, fable]).menuBarClaudeText, "90%")
        XCTAssertEqual(model(with: [fable, weekly]).menuBarClaudeText, "70%")
        let scopedOnly = model(with: [sonnet, fable])
        XCTAssertEqual(scopedOnly.menuBarClaudeText, "30%")
        XCTAssertEqual(scopedOnly.menuBarClaudeAccessibilityText, "Claude weekly Fable limit, 30 percent left")
    }

    @MainActor
    func testCreditsNeverDriveTheMenuBar() throws {
        let model = claudeModel(ClaudeFixtures.credits)

        XCTAssertNil(model.menuBarClaudeText)
        XCTAssertEqual(model.menuBarClaudeDisplay, MenuBarSegment.placeholder)
    }

    @MainActor
    func testMenuBarShowsAFullWindowOnceItHasReset() {
        let reset = LimitBucket(
            provider: .claude, kind: .session, name: "Current session", usedPercent: 90,
            resetAt: Date().addingTimeInterval(-60), resetAfterSeconds: 0,
            limitWindowSeconds: 18_000, reached: true, isActive: true
        )

        XCTAssertEqual(model(with: [reset]).menuBarClaudeText, "100%")
    }

    @MainActor
    private func claudeModel(_ json: String) -> UsageModel {
        let buckets = (try? ClaudeFixtures.decode(json)).map { ClaudeLimits.buckets(from: $0, now: now) } ?? []
        return UsageModel(
            previewBuckets: [
                LimitBucket(
                    kind: .primary,
                    name: "Weekly Limit",
                    usedPercent: 42,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: 604_800,
                    reached: false
                )
            ],
            planType: "pro",
            lastUpdated: now,
            claudeBuckets: buckets,
            claudePlan: "Ultra",
            now: { [now] in now }
        )
    }

    @MainActor
    private func model(with claudeBuckets: [LimitBucket]) -> UsageModel {
        UsageModel(
            previewBuckets: [],
            planType: "pro",
            lastUpdated: now,
            claudeBuckets: claudeBuckets,
            menuBarProviders: [.claude]
        )
    }

    private func bucket(_ kind: LimitBucket.Kind, used: Int, name: String = "Window") -> LimitBucket {
        LimitBucket(
            provider: .claude,
            kind: kind,
            name: name,
            usedPercent: used,
            resetAt: nil,
            resetAfterSeconds: nil,
            limitWindowSeconds: 604_800,
            reached: false
        )
    }

    private func cached(_ kind: LimitBucket.Kind, _ name: String) -> LimitBucket {
        LimitBucket(
            provider: .claude,
            kind: kind,
            name: name,
            usedPercent: 1,
            resetAt: nil,
            resetAfterSeconds: nil,
            limitWindowSeconds: 18_000,
            reached: false
        )
    }
}
