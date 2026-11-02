import XCTest
@testable import UsageBar

final class CommandCodeLimitsTests: XCTestCase {
    private func goSnapshot(
        fiveHourUsed: Double = 0.4,
        fiveHourCap: Double = 3,
        fiveHourExceeded: Bool = false,
        fiveHourResetAt: Double = 1_786_638_458_000,
        weeklyUsed: Double = 1.2,
        weeklyCap: Double = 6,
        weeklyExceeded: Bool = false,
        weeklyResetAt: Double = 1_786_800_000_000,
        monthlyRemaining: Double? = 8.5,
        monthlyUsed: Double? = 1.5,
        planId: String? = "individual-go",
        limited: Bool? = true,
        currentPeriodEnd: String? = "2026-09-13T06:06:01.287Z"
    ) -> CommandCodeUsageSnapshot {
        CommandCodeUsageSnapshot(
            planId: planId,
            subscriptionStatus: "active",
            currentPeriodEnd: currentPeriodEnd,
            credits: CommandCodeCreditsResponse.Credits(
                monthlyCredits: monthlyRemaining,
                purchasedCredits: 0,
                freeCredits: 0
            ),
            windowLimits: CommandCodeCreditsResponse.WindowLimits(
                limited: limited,
                fiveHour: CommandCodeWindow(
                    used: fiveHourUsed,
                    cap: fiveHourCap,
                    exceeded: fiveHourExceeded,
                    resetAt: fiveHourResetAt
                ),
                weekly: CommandCodeWindow(
                    used: weeklyUsed,
                    cap: weeklyCap,
                    exceeded: weeklyExceeded,
                    resetAt: weeklyResetAt
                )
            ),
            monthlyUsed: monthlyUsed
        )
    }

    func testBucketsMatchCommandCodeGoWindows() {
        let now = Date(timeIntervalSince1970: 1_786_632_000)
        let buckets = CommandCodeLimits.buckets(from: goSnapshot(), now: now)

        XCTAssertEqual(LimitBucket.Provider.commandcode.title, "Command Code")
        XCTAssertEqual(buckets.map(\.kind), [.rolling, .weekly, .monthly])
        XCTAssertEqual(buckets.map(\.displayName), [
            CommandCodeLimits.rollingDisplayName,
            CommandCodeLimits.weeklyDisplayName,
            CommandCodeLimits.monthlyDisplayName,
        ])
        XCTAssertEqual(CommandCodeLimits.rollingDisplayName, "Current Session")
        XCTAssertEqual(CommandCodeLimits.weeklyDisplayName, "Weekly Limit")
        XCTAssertEqual(CommandCodeLimits.monthlyDisplayName, "Monthly Limit")
        XCTAssertEqual(buckets.map(\.usedPercent), [13, 20, 15])
        XCTAssertEqual(buckets.map(\.remainingPercent), [87, 80, 85])
        XCTAssertEqual(buckets.map(\.limitWindowSeconds), [
            CommandCodeLimits.rollingWindowSeconds,
            CommandCodeLimits.weeklyWindowSeconds,
            CommandCodeLimits.monthlyWindowSeconds,
        ])
        XCTAssertTrue(buckets.allSatisfy { $0.provider == .commandcode })
        XCTAssertTrue(buckets.allSatisfy { $0.reached == false })
        XCTAssertEqual(buckets[0].resetAfterSeconds, 6_458)
        XCTAssertEqual(
            buckets[0].resetAt,
            Date(timeIntervalSince1970: 1_786_638_458)
        )
    }

    func testResetAtInSecondsIsNotTreatedAsMilliseconds() {
        let now = Date(timeIntervalSince1970: 1_786_632_000)
        let buckets = CommandCodeLimits.buckets(
            from: goSnapshot(fiveHourResetAt: 1_786_638_458),
            now: now
        )

        XCTAssertEqual(buckets[0].resetAt, Date(timeIntervalSince1970: 1_786_638_458))
        XCTAssertEqual(buckets[0].resetAfterSeconds, 6_458)
    }

    func testZeroResetAtOmitsCountdown() {
        let buckets = CommandCodeLimits.buckets(from: goSnapshot(fiveHourResetAt: 0))

        XCTAssertNil(buckets[0].resetAt)
        XCTAssertNil(buckets[0].resetAfterSeconds)
    }

    func testExceededWindowIsMarkedReached() {
        let buckets = CommandCodeLimits.buckets(
            from: goSnapshot(fiveHourUsed: 3, fiveHourExceeded: true)
        )

        XCTAssertEqual(buckets[0].reached, true)
        XCTAssertEqual(buckets[0].usedPercent, 100)
        XCTAssertEqual(buckets[0].remainingPercent, 0)
        XCTAssertEqual(buckets[1].reached, false)
    }

    func testCapExhaustedWithoutExceededFlagStillReaches() {
        let buckets = CommandCodeLimits.buckets(
            from: goSnapshot(fiveHourUsed: 3, fiveHourCap: 3, fiveHourExceeded: false)
        )

        XCTAssertEqual(buckets[0].reached, true)
        XCTAssertEqual(buckets[0].usedPercent, 100)
    }

    func testMissingOrZeroCapsAreSkipped() {
        var snapshot = goSnapshot()
        snapshot.windowLimits = CommandCodeCreditsResponse.WindowLimits(
            limited: true,
            fiveHour: CommandCodeWindow(used: 1, cap: 0, exceeded: false, resetAt: 1),
            weekly: nil
        )

        XCTAssertEqual(
            CommandCodeLimits.buckets(from: snapshot).map(\.kind),
            [.monthly]
        )
    }

    func testPercentIsFlooredToMatchTheDashboard() {
        let buckets = CommandCodeLimits.buckets(
            from: goSnapshot(
                fiveHourUsed: 0.147,
                fiveHourCap: 3,
                weeklyUsed: 0,
                weeklyCap: 6,
                monthlyRemaining: 0.09,
                monthlyUsed: 9.91
            )
        )

        XCTAssertEqual(buckets.map(\.usedPercent), [4, 0, 99])
    }

    func testMonthlyBarCountsRemainingAbovePlanCreditsAsUnused() {
        let buckets = CommandCodeLimits.buckets(
            from: goSnapshot(monthlyRemaining: 15, monthlyUsed: nil)
        )

        XCTAssertEqual(buckets[2].kind, .monthly)
        XCTAssertEqual(buckets[2].usedPercent, 0)
        XCTAssertFalse(buckets[2].reached)
    }

    func testMonthlyBarReachesWhenIncludedCreditsAreGone() {
        let buckets = CommandCodeLimits.buckets(
            from: goSnapshot(monthlyRemaining: 0, monthlyUsed: 10)
        )

        XCTAssertEqual(buckets[2].usedPercent, 100)
        XCTAssertTrue(buckets[2].reached)
    }

    func testProviderPlanShowsItsMonthlyPoolLikeTheCLI() {
        let snapshot = goSnapshot(monthlyRemaining: 6, monthlyUsed: nil, planId: "individual-provider", limited: false)
        let buckets = CommandCodeLimits.buckets(from: snapshot)

        XCTAssertEqual(buckets.map(\.kind), [.monthly])
        XCTAssertEqual(buckets[0].usedPercent, 60)
        XCTAssertEqual(CommandCodeLimits.displayName(for: snapshot.planId), "Provider")
    }

    func testExhaustedActivePlanShowsReachedBarWithoutSummary() {
        let monthly = CommandCodeLimits.buckets(from: goSnapshot(monthlyRemaining: 0, monthlyUsed: nil)).last

        XCTAssertEqual(monthly?.kind, .monthly)
        XCTAssertEqual(monthly?.reached, true)
    }

    func testUnlimitedAccountsHideOnlyTheRollingWindows() {
        XCTAssertEqual(CommandCodeLimits.buckets(from: goSnapshot(limited: false)).map(\.kind), [.monthly])
    }

    @MainActor
    func testUnlimitedAccountWithNothingToShowStaysSignedIn() async throws {
        let suiteName = "CommandCodeLimitsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        ProviderPreferences(popover: [.commandcode], menuBar: [.commandcode]).save(to: defaults)
        let snapshot = goSnapshot(monthlyRemaining: nil, monthlyUsed: nil, limited: false)
        let model = UsageModel(
            defaults: defaults,
            fetcher: UsageFetcher { _ in .commandcode(snapshot) },
            automaticallySchedules: false,
            detectedProviders: { [] }
        )
        model.refreshNow(force: true)
        for _ in 0..<200 where model.isLoading {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(model.commandcodeBuckets.isEmpty)
        XCTAssertEqual(model.popoverMessage(for: .commandcode), "Command Code returned no limits.")
        XCTAssertNotEqual(model.popoverMessage(for: .commandcode), CommandCodeUsageError.notSignedIn.localizedDescription)
    }

    func testMonthlyPoolIncludesPurchasedAndFreeCreditsAsTheCLIDoes() {
        var snapshot = goSnapshot(monthlyUsed: nil)
        snapshot.credits = CommandCodeCreditsResponse.Credits(monthlyCredits: 5, purchasedCredits: 4, freeCredits: 1)

        XCTAssertEqual(CommandCodeLimits.buckets(from: snapshot).last?.usedPercent, 33)
    }

    func testInactiveSubscriptionUsesSpentPlusPoolAsTotal() {
        var snapshot = goSnapshot(monthlyRemaining: 3, monthlyUsed: 1)
        snapshot.subscriptionStatus = "past_due"

        XCTAssertEqual(CommandCodeLimits.buckets(from: snapshot).last?.usedPercent, 25)
    }

    func testSummaryReadsTotalCostWithTotalMonthlyCreditsFallback() throws {
        let current = try JSONDecoder().decode(CommandCodeSummaryResponse.self, from: Data(#"{"totalCost":2.5,"totalCount":143}"#.utf8))
        let legacy = try JSONDecoder().decode(CommandCodeSummaryResponse.self, from: Data(#"{"totalMonthlyCredits":"3"}"#.utf8))

        XCTAssertEqual(current.spent, 2.5)
        XCTAssertEqual(legacy.spent, 3)
    }

    func testOrgSpendLimitsBecomeRows() throws {
        let whoami = try JSONDecoder().decode(CommandCodeWhoamiResponse.self, from: Data("""
        {"org":{"id":"org_x"},"orgLimits":[
          {"scope":"model","model":"model-x","modelLabel":"Model X","limit":20,"spent":5.5,"exceeded":false,"resetInterval":"monthly","resetAt":"2026-12-01T00:00:00Z"},
          {"scope":"org","limit":0,"spent":1,"resetInterval":"total"},
          {"scope":"org","spent":"broken"}
        ]}
        """.utf8))
        var snapshot = goSnapshot()
        snapshot.orgLimits = whoami.orgLimits
        let rows = CommandCodeLimits.buckets(from: snapshot, now: Date(timeIntervalSince1970: 1_793_000_000))
            .filter { $0.kind == .other }

        XCTAssertEqual(whoami.orgLimits.count, 2)
        XCTAssertEqual(rows.map(\.name), ["Model X spend limit", "Org-wide spend limit"])
        XCTAssertEqual(rows[0].usedPercent, 27)
        XCTAssertEqual(rows[0].detail, "$5.50 of $20.00/mo")
        XCTAssertEqual(rows[0].resetAt, ISODate.parse("2026-12-01T00:00:00Z"))
        XCTAssertTrue(rows[1].reached)
        XCTAssertEqual(rows[1].detail, "$1.00 of $0.00")
        XCTAssertNotEqual(rows[0].id, rows[1].id)
    }

    func testSubscriptionDatesAcceptNumbers() throws {
        let response = try JSONDecoder().decode(CommandCodeSubscriptionsResponse.self, from: Data("""
        {"data":{"planId":"individual-go-v1","status":"active","currentPeriodStart":1790000000000,"currentPeriodEnd":"2026-11-13T00:00:00Z"}}
        """.utf8))

        XCTAssertEqual(ISODate.parse(response.data?.currentPeriodStart), Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(response.data?.currentPeriodEnd, "2026-11-13T00:00:00Z")
    }

    func testErrorTextHasNoStatusCodesOrExceptionText() {
        let errors: [CommandCodeUsageError] = [
            .notSignedIn, .invalidKey, .throttled(retryAfter: nil),
            .network("The request timed out."), .httpStatus(500), .decoding("keyNotFound"),
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.contains("500"), text)
            XCTAssertFalse(text.contains("HTTP"), text)
            XCTAssertFalse(text.contains("timed out"), text)
            XCTAssertFalse(text.contains("keyNotFound"), text)
        }
    }

    func testCanonicalPlanIdsDoNotCollapseShorterPrefixes() {
        XCTAssertEqual(CommandCodeLimits.canonicalPlanId(from: "individual-go"), "individual-go")
        XCTAssertEqual(CommandCodeLimits.canonicalPlanId(from: "individual-goat"), "individual-goat")
        XCTAssertEqual(CommandCodeLimits.canonicalPlanId(from: "individual-pro"), "individual-pro")
        XCTAssertEqual(CommandCodeLimits.canonicalPlanId(from: "individual-pro-v1"), "individual-pro-v1")
        XCTAssertEqual(
            CommandCodeLimits.canonicalPlanId(from: "individual-provider"),
            "individual-provider"
        )
        XCTAssertEqual(CommandCodeLimits.canonicalPlanId(from: "individual-go-v1"), "individual-go-v1")
        XCTAssertEqual(CommandCodeLimits.canonicalPlanId(from: "individual_pro_v1_annual"), "individual-pro-v1")
        XCTAssertEqual(CommandCodeLimits.displayName(for: "individual-goat"), "GOAT")
        XCTAssertEqual(CommandCodeLimits.displayName(for: "individual-max"), "Max")
        XCTAssertEqual(CommandCodeLimits.displayName(for: "individual-ultra"), "Ultra")
        XCTAssertEqual(CommandCodeLimits.displayName(for: "teams-pro"), "Teams Pro")
        XCTAssertEqual(CommandCodeLimits.monthlyCredits(for: "individual-provider"), 15)
        XCTAssertEqual(CommandCodeLimits.monthlyCredits(for: "individual-go"), 10)
        XCTAssertEqual(CommandCodeLimits.monthlyCredits(for: "individual-pro-v1"), 80)
    }

    func testRelabeledRewritesCachedRollingTitle() {
        let cached = LimitBucket(
            provider: .commandcode,
            kind: .rolling,
            name: "Rolling 5h",
            usedPercent: 4,
            resetAt: nil,
            resetAfterSeconds: nil,
            limitWindowSeconds: CommandCodeLimits.rollingWindowSeconds,
            reached: false
        )

        XCTAssertEqual(
            CommandCodeLimits.relabeled(cached).name,
            CommandCodeLimits.rollingDisplayName
        )
        XCTAssertEqual(
            CommandCodeLimits.relabeled(
                LimitBucket(
                    provider: .commandcode,
                    kind: .weekly,
                    name: "Week",
                    usedPercent: 3,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: CommandCodeLimits.weeklyWindowSeconds,
                    reached: false
                )
            ).name,
            CommandCodeLimits.weeklyDisplayName
        )
    }

    func testCreditsResponseDecodesLiveCamelCase() throws {
        let payload = """
        {
          "credits": {
            "monthlyCredits": 8.5,
            "purchasedCredits": 2,
            "freeCredits": 0
          },
          "windowLimits": {
            "limited": true,
            "exceeded": null,
            "fiveHour": {"used": 0.4, "cap": 3, "exceeded": false, "resetAt": 1786638458000},
            "weekly": {"used": 1.2, "cap": 6, "exceeded": false, "resetAt": 1786800000000}
          }
        }
        """
        let response = try JSONDecoder().decode(
            CommandCodeCreditsResponse.self,
            from: Data(payload.utf8)
        )

        XCTAssertEqual(response.credits?.monthlyCredits, 8.5)
        XCTAssertEqual(response.windowLimits?.fiveHour?.cap, 3)
        XCTAssertEqual(response.windowLimits?.weekly?.used, 1.2)
        XCTAssertEqual(response.windowLimits?.limited, true)
    }

    func testCreditsResponseSurvivesWronglyTypedWindowFields() throws {
        let payload = """
        {
          "credits": {"monthlyCredits": 8.5},
          "windowLimits": {
            "limited": "true",
            "fiveHour": "soon",
            "weekly": {"used": 1.2, "cap": 6, "exceeded": false, "resetAt": 1786800000000}
          }
        }
        """
        let response = try JSONDecoder().decode(CommandCodeCreditsResponse.self, from: Data(payload.utf8))

        XCTAssertEqual(response.credits?.monthlyCredits, 8.5)
        XCTAssertEqual(response.windowLimits?.limited, true)
        XCTAssertNil(response.windowLimits?.fiveHour)
        XCTAssertEqual(response.windowLimits?.weekly?.cap, 6)

        let broken = try JSONDecoder().decode(
            CommandCodeCreditsResponse.self,
            from: Data(#"{"credits": {"monthlyCredits": 8.5, "windowLimits": 3}, "windowLimits": []}"#.utf8)
        )
        XCTAssertEqual(broken.credits?.monthlyCredits, 8.5)
        XCTAssertNil(broken.windowLimits)
    }

    func testCreditsResponseDecodesNestedWindowLimitsAndStringNumbers() throws {
        let payload = """
        {
          "credits": {
            "monthlyCredits": "8.5",
            "purchasedCredits": 2,
            "windowLimits": {
              "limited": true,
              "fiveHour": {"used": "0.4", "cap": "3", "exceeded": "false", "resetAt": "1786638458000"},
              "weekly": {"used": 1.2, "cap": 6, "exceeded": false, "resetAt": 1786800000000}
            }
          }
        }
        """
        let response = try JSONDecoder().decode(
            CommandCodeCreditsResponse.self,
            from: Data(payload.utf8)
        )

        XCTAssertEqual(response.credits?.monthlyCredits, 8.5)
        XCTAssertEqual(response.windowLimits?.fiveHour?.used, 0.4)
        XCTAssertEqual(response.windowLimits?.fiveHour?.cap, 3)
        XCTAssertEqual(response.windowLimits?.fiveHour?.exceeded, false)
        XCTAssertEqual(response.windowLimits?.fiveHour?.resetAt, 1_786_638_458_000)
        XCTAssertEqual(response.windowLimits?.weekly?.used, 1.2)
        XCTAssertEqual(response.windowLimits?.limited, true)

        let buckets = CommandCodeLimits.buckets(
            from: CommandCodeUsageSnapshot(
                planId: "individual-go",
                subscriptionStatus: "active",
                credits: response.credits,
                windowLimits: response.windowLimits,
                monthlyUsed: nil
            )
        )
        XCTAssertEqual(buckets.map(\.kind), [.rolling, .weekly, .monthly])
        XCTAssertEqual(buckets.map(\.usedPercent), [13, 20, 12])
    }

    func testNestedWindowLimitsAreUsedWhenRootWindowsAreMissing() {
        let snapshot = CommandCodeUsageSnapshot(
            planId: "individual-go",
            credits: CommandCodeCreditsResponse.Credits(
                monthlyCredits: 8.5,
                windowLimits: CommandCodeCreditsResponse.WindowLimits(
                    limited: true,
                    fiveHour: CommandCodeWindow(
                        used: 0.4,
                        cap: 3,
                        exceeded: false,
                        resetAt: 1_786_638_458_000
                    ),
                    weekly: CommandCodeWindow(
                        used: 1.2,
                        cap: 6,
                        exceeded: false,
                        resetAt: 1_786_800_000_000
                    )
                )
            ),
            windowLimits: nil,
            monthlyUsed: 1.5
        )

        XCTAssertEqual(
            CommandCodeLimits.buckets(from: snapshot).map(\.kind),
            [.rolling, .weekly, .monthly]
        )
    }

    func testMonthlyUsedFallsBackToIncludedRemainingWhenSummaryOmitsCredits() {
        let buckets = CommandCodeLimits.buckets(
            from: goSnapshot(monthlyRemaining: 8.5, monthlyUsed: nil)
        )

        XCTAssertEqual(buckets[2].kind, .monthly)
        XCTAssertEqual(buckets[2].usedPercent, 15)
        XCTAssertFalse(buckets[2].reached)
    }

    func testOmittedMonthlyCreditsDoesNotMarkTheBarReached() {
        let buckets = CommandCodeLimits.buckets(
            from: goSnapshot(monthlyRemaining: nil, monthlyUsed: 1.5)
        )

        XCTAssertEqual(buckets[2].kind, .monthly)
        XCTAssertEqual(buckets[2].usedPercent, 15)
        XCTAssertFalse(buckets[2].reached)
    }

    func testMonthlyBarIsSkippedWhenRemainingAndUsedAreUnknown() {
        XCTAssertEqual(
            CommandCodeLimits.buckets(
                from: goSnapshot(monthlyRemaining: nil, monthlyUsed: nil)
            ).map(\.kind),
            [.rolling, .weekly]
        )
    }

    func testCreditsResponseIgnoresBooleanExceededOnWindowLimits() throws {
        let payload = """
        {
          "credits": {"monthlyCredits": 8.5},
          "windowLimits": {
            "limited": true,
            "exceeded": true,
            "fiveHour": {"used": 0.4, "cap": 3, "resetAt": 1786638458000}
          }
        }
        """
        let response = try JSONDecoder().decode(
            CommandCodeCreditsResponse.self,
            from: Data(payload.utf8)
        )

        XCTAssertEqual(response.windowLimits?.limited, true)
        XCTAssertEqual(response.windowLimits?.fiveHour?.cap, 3)
    }

    func testLoadCredentialsPrefersCommandCodeApiKeyEnv() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("auth.json")
        try Data(#"{ "apiKey": "file-key" }"#.utf8).write(to: file)

        let credentials = try CommandCodeUsageService.loadCredentials(
            from: [file],
            environment: ["COMMAND_CODE_API_KEY": " env-key "]
        )
        XCTAssertEqual(credentials.apiKey, "env-key")
    }

    func testLoadCredentialsFallsBackToUnspacedEnvName() throws {
        let credentials = try CommandCodeUsageService.loadCredentials(
            from: [],
            environment: ["COMMANDCODE_API_KEY": "alt-key"]
        )
        XCTAssertEqual(credentials.apiKey, "alt-key")
    }

    func testLoadCredentialsReadsAuthFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("auth.json")
        try Data(#"{ "apiKey": "sk-test", "email": "user@example.com" }"#.utf8).write(to: file)

        let credentials = try CommandCodeUsageService.loadCredentials(from: [file])
        XCTAssertEqual(credentials.apiKey, "sk-test")
    }

    func testLoadCredentialsThrowsWhenNoKeyExists() {
        XCTAssertThrowsError(try CommandCodeUsageService.loadCredentials(from: [])) { error in
            guard case CommandCodeUsageError.notSignedIn = error else {
                return XCTFail("expected notSignedIn, got \(error)")
            }
        }
    }

    func testAuthFileCandidateIsHomeCommandcode() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        XCTAssertEqual(
            CommandCodeUsageService.authFileCandidates(home: home).map(\.path),
            ["/Users/tester/.commandcode/auth.json"]
        )
    }

    @MainActor
    func testMenuBarUsesRollingWindow() {
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
            commandcodeBuckets: CommandCodeLimits.buckets(from: goSnapshot()),
            commandcodePlan: "individual-go",
            menuBarProviders: [.codex, .commandcode]
        )

        XCTAssertEqual(model.menuBarText, "99%")
        XCTAssertEqual(model.menuBarCommandCodeText, "87%")
        XCTAssertEqual(model.commandcodeRolling?.kind, .rolling)
        XCTAssertEqual(model.menuBarSegments.map(\.value), ["99%", "87%"])
        XCTAssertEqual(
            PlanBadgeLabel.text(for: "individual-go", provider: .commandcode),
            "Go"
        )
    }

    @MainActor
    func testMissingKeyOmitsCommandCodeFromTheMenu() {
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
            planType: "pro",
            lastUpdated: Date(),
            menuBarProviders: [.codex, .commandcode],
            errorMessage: "ChatGPT is unreachable.",
            commandcodeAvailable: false
        )

        XCTAssertFalse(model.showsCommandCode)
        XCTAssertNil(model.sectionMessage(for: .commandcode))
        XCTAssertEqual(model.menuBarSegments.map(\.value), ["99%"])
        XCTAssertFalse(model.menuBarAccessibilityLabel.contains("Command Code"))
    }

    @MainActor
    func testMenuBarDoesNotUseWeeklyOrMonthlyAsRolling() {
        var snapshot = goSnapshot()
        snapshot.windowLimits = CommandCodeCreditsResponse.WindowLimits(
            limited: true,
            fiveHour: nil,
            weekly: CommandCodeWindow(
                used: 1.2,
                cap: 6,
                exceeded: false,
                resetAt: 1_786_800_000_000
            )
        )
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
            commandcodeBuckets: CommandCodeLimits.buckets(from: snapshot),
            menuBarProviders: [.codex, .commandcode]
        )

        XCTAssertNil(model.commandcodeRolling)
        XCTAssertNil(model.menuBarCommandCodeText)
        XCTAssertEqual(model.menuBarCommandCodeDisplay, MenuBarSegment.placeholder)
        XCTAssertEqual(model.menuBarSegments.map(\.value), ["99%", MenuBarSegment.placeholder])
        XCTAssertTrue(model.showsCommandCode)
    }

    @MainActor
    func testSignedInCommandCodeWithoutWindowsDoesNotLookSignedOut() {
        let model = UsageModel(
            previewBuckets: [],
            planType: "pro",
            lastUpdated: Date(),
            menuBarProviders: [.commandcode],
            commandcodeAvailable: true
        )

        XCTAssertEqual(model.sectionMessage(for: .commandcode), "Command Code returned no limits.")
    }

    func testSummaryThrottleKeepsCreditsWindows() async throws {
        try await assertSummaryFailureKeepsCreditsWindows(status: 429)
    }

    func testSummaryInvalidKeyKeepsCreditsWindows() async throws {
        try await assertSummaryFailureKeepsCreditsWindows(status: 401)
    }

    private func assertSummaryFailureKeepsCreditsWindows(status: Int) async throws {
        defer { CommandCodeStubURLProtocol.responses = [:] }
        CommandCodeStubURLProtocol.responses = [
            "/alpha/whoami": .ok(#"{ "org": { "id": null } }"#),
            "/alpha/billing/subscriptions": .ok("""
            {
              "data": {
                "planId": "individual-go",
                "status": "active",
                "currentPeriodStart": "2026-08-13T06:06:01Z",
                "currentPeriodEnd": "2026-09-13T06:06:01Z"
              }
            }
            """),
            "/alpha/billing/credits": .ok("""
            {
              "credits": { "monthlyCredits": 8.5, "purchasedCredits": 2, "freeCredits": 0 },
              "windowLimits": {
                "limited": true,
                "fiveHour": {"used": 0.4, "cap": 3, "exceeded": false, "resetAt": 1786638458000},
                "weekly": {"used": 1.2, "cap": 6, "exceeded": false, "resetAt": 1786800000000}
              }
            }
            """),
            "/alpha/usage/summary": .status(status),
        ]

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommandCodeStubURLProtocol.self]
        let service = CommandCodeUsageService(
            baseURL: URL(string: "https://commandcode.test")!,
            session: URLSession(configuration: configuration)
        )
        let (usage, credentials) = try await service.fetchUsage(
            from: [],
            environment: ["COMMAND_CODE_API_KEY": "sk-test"]
        )

        XCTAssertEqual(credentials.apiKey, "sk-test")
        XCTAssertNil(usage.monthlyUsed)
        XCTAssertEqual(
            CommandCodeLimits.buckets(from: usage).map(\.kind),
            [.rolling, .weekly, .monthly]
        )
        XCTAssertEqual(
            CommandCodeLimits.buckets(from: usage).map(\.usedPercent),
            [13, 20, 12]
        )
    }
}

private struct CommandCodeStubBody {
    let status: Int
    let data: Data

    static func ok(_ json: String) -> CommandCodeStubBody {
        CommandCodeStubBody(status: 200, data: Data(json.utf8))
    }

    static func status(_ code: Int) -> CommandCodeStubBody {
        CommandCodeStubBody(status: code, data: Data())
    }
}

private final class CommandCodeStubURLProtocol: URLProtocol {
    private static let store = CommandCodeStubStore()

    static var responses: [String: CommandCodeStubBody] {
        get { store.value }
        set { store.value = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let stub = Self.responses[url.path],
              let response = HTTPURLResponse(
                url: url,
                statusCode: stub.status,
                httpVersion: nil,
                headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CommandCodeStubStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: CommandCodeStubBody] = [:]

    var value: [String: CommandCodeStubBody] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
