import Foundation
import XCTest
@testable import UsageBar

final class UsageAlertsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)
    private let week = 7 * 24 * 60 * 60

    func testCrossingTwentyPercentLeftWarnsOnceInThePeriod() {
        let resetAt = now.addingTimeInterval(2 * 86_400)
        var ledger = UsageAlertLedger()

        let above = evaluate([weekly(used: 75, resetAt: resetAt)], ledger: ledger)
        ledger = above.ledger
        let crossed = evaluate([weekly(used: 82, resetAt: resetAt)], ledger: ledger)
        ledger = crossed.ledger
        let again = evaluate([weekly(used: 85, resetAt: resetAt)], ledger: ledger)

        XCTAssertEqual(above.alerts, [])
        XCTAssertEqual(crossed.alerts.map(\.kind), [.low])
        XCTAssertEqual(crossed.alerts.first?.title, "Claude weekly limit: 18% left")
        XCTAssertEqual(crossed.alerts.first?.body, "Resets \(ClockText.at(resetAt, relativeTo: now)).")
        XCTAssertEqual(again.alerts, [])
    }

    func testFivePercentLeftStaysQuietThenTheLimitReachedNotifiesOnce() {
        let resetAt = now.addingTimeInterval(3_600)
        var ledger = evaluate([session(used: 82, resetAt: resetAt)], ledger: UsageAlertLedger()).ledger

        let fivePercent = evaluate([session(used: 95, resetAt: resetAt)], ledger: ledger)
        ledger = fivePercent.ledger
        let reached = evaluate([session(used: 100, resetAt: resetAt, reached: true)], ledger: ledger)
        ledger = reached.ledger
        let stillReached = evaluate([session(used: 100, resetAt: resetAt, reached: true)], ledger: ledger)

        XCTAssertEqual(fivePercent.alerts, [])
        XCTAssertEqual(reached.alerts.map(\.kind), [.reached])
        XCTAssertEqual(reached.alerts.first?.title, "Codex 5-hour limit reached")
        XCTAssertEqual(reached.alerts.first?.body, "Resets \(ClockText.at(resetAt, relativeTo: now)).")
        XCTAssertEqual(stillReached.alerts, [])
    }

    func testTheProvidersLimitReachedStatusNotifiesEvenBelowOneHundredPercent() {
        let result = evaluate(
            [session(used: 97, resetAt: now.addingTimeInterval(3_600), reached: true)],
            ledger: UsageAlertLedger()
        )

        XCTAssertEqual(result.alerts.map(\.kind), [.reached])
    }

    func testResetAfterAWarningNotifiesWhenFreshDataShowsTheNextPeriod() {
        let firstReset = now.addingTimeInterval(3_600)
        let warned = evaluate([weekly(used: 90, resetAt: firstReset)], ledger: UsageAlertLedger())
        let later = now.addingTimeInterval(2 * 3_600)
        let nextReset = firstReset.addingTimeInterval(TimeInterval(week))

        let waiting = evaluate([weekly(used: 90, resetAt: firstReset)], ledger: warned.ledger, at: later)
        let fresh = evaluate([weekly(used: 2, resetAt: nextReset)], ledger: waiting.ledger, at: later)
        let quiet = evaluate([weekly(used: 3, resetAt: nextReset)], ledger: fresh.ledger, at: later)

        XCTAssertEqual(waiting.alerts, [])
        XCTAssertEqual(fresh.alerts.map(\.kind), [.reset])
        XCTAssertEqual(fresh.alerts.first?.title, "Claude weekly limit has reset")
        XCTAssertEqual(fresh.alerts.first?.body, "")
        XCTAssertEqual(quiet.alerts, [])
        XCTAssertTrue(quiet.ledger.records.isEmpty)
    }

    func testABillingCycleOfAnotherLengthIsStillTheSameWindow() {
        let day = 86_400
        func cursorModels(used: Int, cycleDays: Int, resetAt: Date) -> LimitBucket {
            LimitBucket(provider: .cursor, kind: .cursorModels, name: "Cursor Models", usedPercent: used, resetAt: resetAt,
                        resetAfterSeconds: Int(resetAt.timeIntervalSince(now)), limitWindowSeconds: cycleDays * day,
                        reached: false)
        }
        let januaryEnd = now.addingTimeInterval(TimeInterval(day))
        let februaryEnd = januaryEnd.addingTimeInterval(TimeInterval(28 * day))
        let marchEnd = februaryEnd.addingTimeInterval(TimeInterval(31 * day))

        let january = evaluate([cursorModels(used: 85, cycleDays: 31, resetAt: januaryEnd)], ledger: UsageAlertLedger())
        let february = evaluate(
            [cursorModels(used: 90, cycleDays: 28, resetAt: februaryEnd)],
            ledger: january.ledger,
            at: januaryEnd.addingTimeInterval(60)
        )
        let march = evaluate(
            [cursorModels(used: 4, cycleDays: 31, resetAt: marchEnd)],
            ledger: february.ledger,
            at: februaryEnd.addingTimeInterval(60)
        )

        XCTAssertEqual(january.alerts.map(\.title), ["Cursor Cursor Models monthly limit: 15% left"])
        XCTAssertEqual(february.alerts.map(\.kind), [.reset, .low])
        XCTAssertEqual(february.alerts.first?.title, "Cursor Cursor Models monthly limit has reset")
        XCTAssertEqual(march.alerts.map(\.kind), [.reset])
        XCTAssertTrue(march.ledger.records.isEmpty)
    }

    func testAnIdleWindowWithoutAResetTimeAfterItsPeriodCountsAsReset() {
        let firstReset = now.addingTimeInterval(3_600)
        let warned = evaluate([session(used: 85, resetAt: firstReset)], ledger: UsageAlertLedger())
        let later = now.addingTimeInterval(2 * 3_600)
        var idle = session(used: 0, resetAt: firstReset)
        idle = LimitBucket(kind: idle.kind, name: idle.name, usedPercent: 0, resetAt: nil,
                           resetAfterSeconds: nil, limitWindowSeconds: idle.limitWindowSeconds, reached: false)

        let beforeEnd = evaluate([idle], ledger: warned.ledger)
        let afterEnd = evaluate([idle], ledger: warned.ledger, at: later)

        XCTAssertEqual(beforeEnd.alerts, [])
        XCTAssertEqual(beforeEnd.ledger.records.count, 1)
        XCTAssertEqual(afterEnd.alerts.map(\.title), ["Codex 5-hour limit has reset"])
        XCTAssertTrue(afterEnd.ledger.records.isEmpty)
    }

    func testResetIsSilentWithoutAWarningOrWhenTurnedOff() {
        let firstReset = now.addingTimeInterval(3_600)
        let nextReset = firstReset.addingTimeInterval(TimeInterval(week))
        let later = now.addingTimeInterval(2 * 3_600)
        let unwarned = evaluate([weekly(used: 40, resetAt: firstReset)], ledger: UsageAlertLedger())
        var noResets = UsageAlertPreferences()
        noResets.notifiesOnReset = false
        let warned = evaluate([weekly(used: 90, resetAt: firstReset)], ledger: UsageAlertLedger(), preferences: noResets)

        let afterUnwarned = evaluate([weekly(used: 1, resetAt: nextReset)], ledger: unwarned.ledger, at: later)
        let afterDisabled = evaluate(
            [weekly(used: 1, resetAt: nextReset)],
            ledger: warned.ledger,
            preferences: noResets,
            at: later
        )

        XCTAssertEqual(afterUnwarned.alerts, [])
        XCTAssertEqual(afterDisabled.alerts, [])
    }

    func testAResetTimeThatDriftsByMinutesStaysTheSamePeriod() {
        let resetAt = now.addingTimeInterval(3_600)
        let warned = evaluate([session(used: 90, resetAt: resetAt)], ledger: UsageAlertLedger())

        let drifted = evaluate([session(used: 91, resetAt: resetAt.addingTimeInterval(90))], ledger: warned.ledger)

        XCTAssertEqual(drifted.alerts, [])
    }

    func testRaisingTheThresholdAfterAWarningDoesNotRepeatIt() {
        let resetAt = now.addingTimeInterval(86_400)
        let warnedAtTwenty = evaluate([weekly(used: 82, resetAt: resetAt)], ledger: UsageAlertLedger())
        var thirty = UsageAlertPreferences()
        thirty.warnAtPercentLeft = 30

        let raised = evaluate([weekly(used: 83, resetAt: resetAt)], ledger: warnedAtTwenty.ledger, preferences: thirty)

        XCTAssertEqual(raised.alerts, [])
    }

    func testLoweringTheThresholdWarnsAgainWhenTheNewOneIsCrossed() {
        let resetAt = now.addingTimeInterval(86_400)
        var fifty = UsageAlertPreferences()
        fifty.warnAtPercentLeft = 50
        let warnedAtFifty = evaluate([weekly(used: 55, resetAt: resetAt)], ledger: UsageAlertLedger(), preferences: fifty)
        var ten = UsageAlertPreferences()
        ten.warnAtPercentLeft = 10

        let aboveTen = evaluate([weekly(used: 80, resetAt: resetAt)], ledger: warnedAtFifty.ledger, preferences: ten)
        let belowTen = evaluate([weekly(used: 92, resetAt: resetAt)], ledger: aboveTen.ledger, preferences: ten)

        XCTAssertEqual(warnedAtFifty.alerts.map(\.title), ["Claude weekly limit: 45% left"])
        XCTAssertEqual(aboveTen.alerts, [])
        XCTAssertEqual(belowTen.alerts.map(\.title), ["Claude weekly limit: 8% left"])
    }

    func testTurningWarningsOffSilencesLowAndReached() {
        var off = UsageAlertPreferences()
        off.warnsWhenLow = false

        let result = evaluate(
            [session(used: 100, resetAt: now.addingTimeInterval(600), reached: true), weekly(used: 90, resetAt: now.addingTimeInterval(600))],
            ledger: UsageAlertLedger(),
            preferences: off
        )

        XCTAssertEqual(result.alerts, [])
    }

    func testAWindowWaitingForFreshDataAfterItsResetNeverNotifies() {
        let result = evaluate([weekly(used: 95, resetAt: now.addingTimeInterval(-60))], ledger: UsageAlertLedger())

        XCTAssertEqual(result.alerts, [])
    }

    func testCreditAndSpendRowsNeverNotify() {
        let resetAt = now.addingTimeInterval(86_400)
        let rows = [
            LimitBucket(kind: .spendLimit, scope: "spend-control", name: "Monthly Credit Limit", usedPercent: 99,
                        resetAt: resetAt, resetAfterSeconds: 86_400, limitWindowSeconds: nil, reached: false),
            LimitBucket(kind: .balance, scope: "credits", name: "Credits", usedPercent: 0,
                        resetAt: nil, resetAfterSeconds: nil, limitWindowSeconds: nil, reached: false, detail: "5 credits"),
            LimitBucket(provider: .claude, kind: .credit, name: "Credit", usedPercent: 100,
                        resetAt: resetAt, resetAfterSeconds: 86_400, limitWindowSeconds: nil, reached: true),
        ]

        XCTAssertEqual(evaluate(rows, provider: .codex, ledger: UsageAlertLedger()).alerts, [])
        XCTAssertEqual(evaluate(rows, provider: .claude, ledger: UsageAlertLedger()).alerts, [])
    }

    func testCursorAndCommandCodeSpendRowsAreSpendLimitsNotWindows() throws {
        let cursor = try JSONDecoder().decode(
            CursorUsageResponse.self,
            from: Data("""
            {"billingCycleStart":"2026-11-01T00:00:00.000Z","billingCycleEnd":"2026-12-01T00:00:00.000Z",
             "spendLimitUsage":{"individualLimit":2000,"individualUsed":1990},"enabled":true}
            """.utf8)
        )
        let sand = try JSONDecoder().decode(
            CursorSandUsageStatus.self,
            from: Data(#"{"isUnified":true,"usagePercent":40,"nextResetTimestampUtc":"2026-11-08T00:00:00Z"}"#.utf8)
        )
        let rows = CursorLimits.layout(
            for: CursorUsageSnapshot(period: cursor, sand: sand, planInfo: nil, membershipType: "pro"),
            now: Date(timeIntervalSince1970: 1_793_570_400)
        ).buckets

        XCTAssertEqual(rows.filter { !$0.isTimeWindow }.map(\.name), [CursorLimits.additionalUsageDisplayName])
    }

    func testEveryProviderFamilyNamesItsWindow() {
        let resetAt = now.addingTimeInterval(3_600)
        let rows: [(LimitBucket, String)] = [
            (session(used: 90, resetAt: resetAt), "Codex 5-hour limit: 10% left"),
            (LimitBucket(kind: .additional, scope: "additional.spark.primary", name: "GPT-5.3-Codex-Spark 5-Hour Limit",
                         usedPercent: 90, resetAt: resetAt, resetAfterSeconds: 3_600, limitWindowSeconds: 18_000, reached: false),
             "Codex GPT-5.3-Codex-Spark 5-hour limit: 10% left"),
            (LimitBucket(provider: .claude, kind: .session, name: "Current session", usedPercent: 90, resetAt: resetAt,
                         resetAfterSeconds: 3_600, limitWindowSeconds: 18_000, reached: false),
             "Claude 5-hour limit: 10% left"),
            (LimitBucket(provider: .claude, kind: .weeklyScoped, scope: "model:Fable", name: "Current week (Fable)",
                         usedPercent: 90, resetAt: resetAt, resetAfterSeconds: 3_600, limitWindowSeconds: week, reached: false),
             "Claude Fable weekly limit: 10% left"),
            (LimitBucket(provider: .cursor, kind: .weekly, name: "Weekly usage", usedPercent: 90, resetAt: resetAt,
                         resetAfterSeconds: 3_600, limitWindowSeconds: week, reached: false),
             "Cursor weekly limit: 10% left"),
            (LimitBucket(provider: .cursor, kind: .grokBot, name: "Grok Bot", usedPercent: 90, resetAt: resetAt,
                         resetAfterSeconds: 3_600, limitWindowSeconds: week, reached: false),
             "Cursor Grok Bot weekly limit: 10% left"),
            (LimitBucket(provider: .opencode, kind: .monthly, name: "Monthly Limit", usedPercent: 90, resetAt: resetAt,
                         resetAfterSeconds: 3_600, limitWindowSeconds: 30 * 86_400, reached: false),
             "OpenCode monthly limit: 10% left"),
            (LimitBucket(provider: .commandcode, kind: .rolling, name: "Current Session", usedPercent: 90, resetAt: resetAt,
                         resetAfterSeconds: 3_600, limitWindowSeconds: 18_000, reached: false),
             "Command Code 5-hour limit: 10% left"),
        ]

        for (bucket, title) in rows {
            let result = evaluate([bucket], provider: bucket.provider, ledger: UsageAlertLedger())
            XCTAssertEqual(result.alerts.map(\.title), [title])
        }
    }

    func testPassedPeriodsArePrunedFromTheLedger() {
        let resetAt = now.addingTimeInterval(3_600)
        let warned = evaluate([weekly(used: 90, resetAt: resetAt)], ledger: UsageAlertLedger())

        let gone = evaluate([], ledger: warned.ledger, at: resetAt.addingTimeInterval(60))
        let longGone = evaluate([], provider: .codex, ledger: warned.ledger, at: resetAt.addingTimeInterval(9 * 86_400))
        let otherProvider = evaluate([], provider: .codex, ledger: warned.ledger, at: resetAt.addingTimeInterval(60))

        XCTAssertEqual(warned.ledger.records.count, 1)
        XCTAssertTrue(gone.ledger.records.isEmpty)
        XCTAssertTrue(longGone.ledger.records.isEmpty)
        XCTAssertEqual(otherProvider.ledger.records.count, 1)
    }

    func testPrintsEveryNotificationText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let resetLow = now.addingTimeInterval(3 * 86_400)
        let resetReached = now.addingTimeInterval(2 * 3_600)
        let samples = [
            UsageAlerts.alert(.low, for: weekly(used: 80, resetAt: resetLow), now: now),
            UsageAlerts.alert(.reached, for: session(used: 100, resetAt: resetReached, reached: true), now: now),
            UsageAlerts.alert(.reset, for: weekly(used: 0, resetAt: resetLow), now: now),
        ]
        for alert in samples {
            print("NOTIFICATION \(alert.kind.rawValue): title=\"\(alert.title)\" body=\"\(alert.body)\"")
        }
        XCTAssertEqual(samples.map(\.title), [
            "Claude weekly limit: 20% left",
            "Codex 5-hour limit reached",
            "Claude weekly limit has reset",
        ])
    }

    @MainActor
    func testNoDuplicateAfterRelaunch() async {
        let defaults = makeDefaults()
        let notifier = FakeNotifier(permission: .granted)
        let resetAt = now.addingTimeInterval(86_400)
        await UsageAlertCenter(defaults: defaults, notifier: notifier)
            .receive(provider: .claude, buckets: [weekly(used: 85, resetAt: resetAt)], at: now)?.value

        let relaunched = UsageAlertCenter(defaults: defaults, notifier: notifier)
        let task = relaunched.receive(provider: .claude, buckets: [weekly(used: 86, resetAt: resetAt)], at: now.addingTimeInterval(300))
        await task?.value

        XCTAssertNil(task)
        XCTAssertEqual(notifier.posted.map(\.title), ["Claude weekly limit: 15% left"])
    }

    @MainActor
    func testPermissionIsAskedWhenTheFirstNotificationIsDue() async {
        let notifier = FakeNotifier(permission: .notDetermined, answer: .granted)
        let center = UsageAlertCenter(defaults: makeDefaults(), notifier: notifier)

        center.receive(provider: .claude, buckets: [weekly(used: 40, resetAt: now.addingTimeInterval(86_400))], at: now)
        let requestsBeforeDue = notifier.requests
        await center.receive(provider: .claude, buckets: [weekly(used: 85, resetAt: now.addingTimeInterval(86_400))], at: now)?.value

        XCTAssertEqual(requestsBeforeDue, 0)
        XCTAssertEqual(notifier.requests, 1)
        XCTAssertEqual(center.permission, .granted)
        XCTAssertEqual(notifier.posted.count, 1)
    }

    @MainActor
    func testDeniedPermissionPostsNothingAndSettingsCanSayIt() async {
        let notifier = FakeNotifier(permission: .denied)
        let center = UsageAlertCenter(defaults: makeDefaults(), notifier: notifier)

        await center.receive(provider: .claude, buckets: [weekly(used: 85, resetAt: now.addingTimeInterval(86_400))], at: now)?.value

        XCTAssertEqual(notifier.posted, [])
        XCTAssertEqual(center.permission, .denied)
    }

    @MainActor
    func testTurningAToggleOnAsksForPermission() async {
        let defaults = makeDefaults()
        var off = UsageAlertPreferences()
        off.warnsWhenLow = false
        off.save(to: defaults)
        let notifier = FakeNotifier(permission: .notDetermined, answer: .granted)
        let center = UsageAlertCenter(defaults: defaults, notifier: notifier)

        center.preferences.warnsWhenLow = true
        let asked = await waitUntil { notifier.requests == 1 }

        XCTAssertTrue(asked)
        XCTAssertTrue(UsageAlertPreferences.load(from: defaults).warnsWhenLow)
    }

    @MainActor
    func testClickingANotificationOpensThePopover() {
        let notifier = FakeNotifier(permission: .granted)
        let center = UsageAlertCenter(defaults: makeDefaults(), notifier: notifier)
        var opened = 0
        center.openPopover = { opened += 1 }

        notifier.onOpen?()

        XCTAssertEqual(opened, 1)
    }

    @MainActor
    func testFreshCodexDataNotifies() async {
        let notifier = FakeNotifier(permission: .granted)
        let model = makeModel(providers: [.codex], notifier: notifier) { _ in codexResult(used: 85) }

        model.refreshNow(force: true)
        let posted = await waitUntil { notifier.posted.count == 1 }

        XCTAssertTrue(posted)
        XCTAssertEqual(notifier.posted.first?.title, "Codex weekly limit: 15% left")
    }

    @MainActor
    func testAProviderHiddenFromThePopoverNeverNotifies() async {
        let notifier = FakeNotifier(permission: .granted)
        let gate = ReleaseGate()
        let model = makeModel(providers: [.codex, .claude], notifier: notifier) { endpoint in
            await gate.wait()
            return endpoint == .codex ? codexResult(used: 85) : claudeResult(used: 90, dataDate: self.now)
        }

        model.refreshNow(force: true)
        model.setVisibleInMenuBar(.claude, visible: false)
        model.setVisibleInPopover(.claude, visible: false)
        await gate.open()
        let received = await waitUntil { model.claudeAvailable && !model.isLoading && !notifier.posted.isEmpty }
        await settle()

        XCTAssertTrue(received)
        XCTAssertFalse(model.isVisibleInPopover(.claude))
        XCTAssertFalse(model.claudeBuckets.isEmpty)
        XCTAssertEqual(notifier.posted.map(\.title), ["Codex weekly limit: 15% left"])
    }

    @MainActor
    func testStaleClaudeDataNeverNotifies() async {
        let notifier = FakeNotifier(permission: .granted)
        let model = makeModel(providers: [.claude], notifier: notifier) { _ in
            claudeResult(used: 95, dataDate: self.now.addingTimeInterval(-2 * 3_600), source: .claudeCode)
        }

        model.refreshNow(force: true)
        let received = await waitUntil { model.claudeAvailable && !model.isLoading }
        await settle()

        XCTAssertTrue(received)
        XCTAssertFalse(model.hasFreshData(for: .claude, at: now))
        XCTAssertEqual(notifier.posted, [])
    }

    @MainActor
    func testDataArrivingWhileClaudeIsPausedNeverNotifies() async {
        let notifier = FakeNotifier(permission: .granted)
        let calls = CallCounter()
        let defaults = makeDefaults()
        defaults.set(true, forKey: UsageModel.claudeQuotaCheckKey)
        let model = makeModel(providers: [.claude], defaults: defaults, notifier: notifier) { endpoint in
            if endpoint == .claudeWhilePaused {
                await calls.increment()
                return claudeResult(used: 99, dataDate: self.now, source: .quotaCheck)
            }
            throw ClaudeUsageError.throttled(retryAfter: nil)
        }

        model.refreshNow(force: true)
        let paused = await waitUntil { model.claudePausedUntil(at: self.now) != nil && !model.isLoading }
        model.refreshNow(force: true)
        let checked = await waitUntil { model.claudeAvailable && !model.isLoading }
        await settle()
        let quotaChecks = await calls.value

        XCTAssertTrue(paused)
        XCTAssertTrue(checked)
        XCTAssertEqual(quotaChecks, 1)
        XCTAssertEqual(model.claudeBuckets.first?.usedPercent, 99)
        XCTAssertEqual(notifier.posted, [])
    }

    @MainActor
    func testAClaudeReplyWithoutUsageNeverNotifiesFromSavedValues() async {
        let defaults = makeDefaults()
        var state = UsageRefreshState()
        state.succeed(at: now.addingTimeInterval(-60), interval: UsageEndpoint.claude.policy.interval)
        UsageSnapshotStore.save(
            UsageSnapshot(
                claudeBuckets: [weekly(used: 90, resetAt: now.addingTimeInterval(86_400))],
                fetchedAt: now.addingTimeInterval(-60),
                refreshStates: [UsageEndpoint.claude.rawValue: state]
            ),
            to: defaults
        )
        let notifier = FakeNotifier(permission: .granted)
        let model = makeModel(providers: [.claude], defaults: defaults, notifier: notifier) { _ in
            .claude(ClaudeFetch(usage: nil, source: .claudeCode, dataDate: self.now))
        }

        model.refreshNow(force: true)
        let received = await waitUntil { model.refreshStates[.claude]?.lastAttempt != nil && !model.isLoading }
        await settle()

        XCTAssertTrue(received)
        XCTAssertEqual(model.claudeBuckets.first?.remainingPercent, 10)
        XCTAssertTrue(model.hasFreshData(for: .claude, at: now))
        XCTAssertEqual(notifier.posted, [])
    }

    private func evaluate(
        _ buckets: [LimitBucket],
        provider: LimitBucket.Provider? = nil,
        ledger: UsageAlertLedger,
        preferences: UsageAlertPreferences = UsageAlertPreferences(),
        at date: Date? = nil
    ) -> (alerts: [UsageAlert], ledger: UsageAlertLedger) {
        UsageAlerts.evaluate(
            provider: provider ?? buckets.first?.provider ?? .claude,
            buckets: buckets,
            preferences: preferences,
            ledger: ledger,
            now: date ?? now
        )
    }

    private func weekly(used: Int, resetAt: Date) -> LimitBucket {
        LimitBucket(
            provider: .claude,
            kind: .weeklyAll,
            name: "Current week (all models)",
            usedPercent: used,
            resetAt: resetAt,
            resetAfterSeconds: Int(resetAt.timeIntervalSince(now)),
            limitWindowSeconds: week,
            reached: used >= 100
        )
    }

    private func session(used: Int, resetAt: Date, reached: Bool = false) -> LimitBucket {
        LimitBucket(
            kind: .primary,
            name: WindowLabels.currentSession,
            usedPercent: used,
            resetAt: resetAt,
            resetAfterSeconds: Int(resetAt.timeIntervalSince(now)),
            limitWindowSeconds: 18_000,
            reached: reached
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "UsageAlertsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    @MainActor
    private func makeModel(
        providers: Set<LimitBucket.Provider>,
        defaults: UserDefaults? = nil,
        notifier: FakeNotifier,
        fetch: @escaping @Sendable (UsageEndpoint) async throws -> UsageFetchResult
    ) -> UsageModel {
        let defaults = defaults ?? makeDefaults()
        ProviderPreferences(popover: providers, menuBar: providers).save(to: defaults)
        let now = now
        return UsageModel(
            defaults: defaults,
            fetcher: UsageFetcher(fetch),
            now: { now },
            automaticallySchedules: false,
            alerts: UsageAlertCenter(defaults: defaults, notifier: notifier)
        )
    }

    @MainActor
    private func settle() async {
        for _ in 0..<100 {
            await Task.yield()
        }
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

@MainActor
private final class FakeNotifier: UsageNotifying {
    var onOpen: (() -> Void)?
    private(set) var posted: [UsageAlert] = []
    private(set) var requests = 0
    private var current: NotificationPermission
    private let answer: NotificationPermission

    init(permission: NotificationPermission, answer: NotificationPermission = .denied) {
        current = permission
        self.answer = answer
    }

    func permission() async -> NotificationPermission { current }

    func requestPermission() async -> NotificationPermission {
        requests += 1
        current = answer
        return current
    }

    func post(_ alert: UsageAlert) {
        posted.append(alert)
    }
}

private actor ReleaseGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        released = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor CallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private func codexResult(used: Int) -> UsageFetchResult {
    .codex(
        try! JSONDecoder().decode(
            UsageResponse.self,
            from: Data("""
            {"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,
             "primary_window":{"used_percent":\(used),"limit_window_seconds":604800,"reset_after_seconds":86400}}}
            """.utf8)
        )
    )
}

private func claudeResult(used: Int, dataDate: Date, source: ClaudeFetch.Source = .usageEndpoint) -> UsageFetchResult {
    let resetsAt = ISO8601DateFormatter().string(from: dataDate.addingTimeInterval(86_400))
    let response = try! JSONDecoder().decode(
        ClaudeUsageResponse.self,
        from: Data("""
        {"seven_day":{"utilization":\(used),"resets_at":"\(resetsAt)"}}
        """.utf8)
    )
    return .claude(ClaudeFetch(usage: response, source: source, dataDate: dataDate))
}
