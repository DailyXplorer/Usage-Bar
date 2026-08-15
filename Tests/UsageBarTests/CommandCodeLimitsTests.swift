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
        monthlyRemaining: Double = 8.5,
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
                exceeded: nil,
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
        XCTAssertEqual(CommandCodeLimits.rollingDisplayName, "Current session")
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
            exceeded: nil,
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

    func testMonthlyBarUsesPlanCreditsAndIgnoresPurchasedExtras() {
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

    func testPayAsYouGoAccountsAreHidden() {
        let snapshot = goSnapshot(planId: "individual-provider")

        XCTAssertTrue(CommandCodeLimits.shouldHide(snapshot))
        XCTAssertTrue(CommandCodeLimits.buckets(from: snapshot).isEmpty)
        XCTAssertNil(CommandCodeLimits.displayName(for: snapshot.planId))
    }

    func testUnlimitedAccountsAreHidden() {
        XCTAssertTrue(CommandCodeLimits.shouldHide(goSnapshot(limited: false)))
        XCTAssertTrue(CommandCodeLimits.buckets(from: goSnapshot(limited: false)).isEmpty)
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
        XCTAssertEqual(CommandCodeLimits.displayName(for: "individual-max"), "Max 10x")
        XCTAssertEqual(CommandCodeLimits.displayName(for: "individual-ultra"), "Max 20x")
        XCTAssertEqual(CommandCodeLimits.displayName(for: "teams-pro"), "Team Pro")
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
                credits: response.credits,
                windowLimits: response.windowLimits,
                monthlyUsed: nil
            )
        )
        XCTAssertEqual(buckets.map(\.kind), [.rolling, .weekly, .monthly])
        XCTAssertEqual(buckets.map(\.usedPercent), [13, 20, 15])
    }

    func testNestedWindowLimitsAreUsedWhenRootWindowsAreMissing() {
        let snapshot = CommandCodeUsageSnapshot(
            planId: "individual-go",
            credits: CommandCodeCreditsResponse.Credits(
                monthlyCredits: 8.5,
                windowLimits: CommandCodeCreditsResponse.WindowLimits(
                    limited: true,
                    exceeded: nil,
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
            exceeded: nil,
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
        XCTAssertEqual(model.menuBarCommandCodeDisplay, "–")
        XCTAssertEqual(model.menuBarSegments.map(\.value), ["99%", "–"])
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
}
