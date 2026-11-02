import Combine
import Foundation
import XCTest
@testable import UsageBar

final class UsageModelRefreshTests: XCTestCase {
    @MainActor
    func testRefreshSkipsHiddenEndpoints() async {
        let fixture = TestDefaultsFixture(providers: [.codex])
        defer { fixture.clear() }
        let defaults = fixture.defaults
        let calls = EndpointCallLog()
        let model = UsageModel(
            defaults: defaults,
            fetcher: UsageFetcher { endpoint in
                await calls.record(endpoint)
                return testCodexResult()
            },
            now: fixedNow,
            automaticallySchedules: false
        )

        model.refreshNow(force: true)

        let recordedInitialRequest = await calls.waitForCount(1)
        let endpoints = await calls.endpoints()
        let receivedCodex = await waitUntil { model.refreshStates[.codex]?.lastSuccess != nil }
        XCTAssertTrue(recordedInitialRequest)
        XCTAssertEqual(endpoints, [.codex])
        XCTAssertTrue(receivedCodex)
    }

    @MainActor
    func testMenuBarRedrawsWhenTheClaudeSessionResets() async throws {
        let fixture = TestDefaultsFixture(providers: [.claude])
        defer { fixture.clear() }
        let clock = TestClock(fixedNow())
        let gate = SleepGate()
        let model = UsageModel(
            defaults: fixture.defaults,
            fetcher: UsageFetcher { _ in try testClaudeResult(resetsAt: fixedNow().addingTimeInterval(120)) },
            now: { clock.date },
            automaticallySchedules: false,
            sleep: { delay in await gate.sleep(delay) }
        )
        var redraws = 0
        let observation = model.objectWillChange.sink { redraws += 1 }
        defer { observation.cancel() }

        model.refreshNow(force: true)
        let receivedClaude = await waitUntil { model.claudeAvailable && !model.isLoading }
        let scheduled = await gate.waitForSleeps()
        let displayBeforeReset = model.menuBarClaudeDisplay
        let redrawsBeforeReset = redraws
        clock.advance(by: 120)
        await gate.open()
        let redrawnAtReset = await waitUntil { redraws > redrawsBeforeReset }

        XCTAssertTrue(receivedClaude)
        XCTAssertEqual(scheduled, [120])
        XCTAssertEqual(displayBeforeReset, "75%")
        XCTAssertTrue(redrawnAtReset)
        XCTAssertEqual(model.menuBarClaudeDisplay, "100%")
    }

    @MainActor
    func testClaudeSessionRedrawWaitsInBoundedSteps() async throws {
        let fixture = TestDefaultsFixture(providers: [.claude])
        defer { fixture.clear() }
        let clock = TestClock(fixedNow())
        let gate = SleepGate()
        let model = UsageModel(
            defaults: fixture.defaults,
            fetcher: UsageFetcher { _ in try testClaudeResult(resetsAt: fixedNow().addingTimeInterval(5000)) },
            now: { clock.date },
            automaticallySchedules: false,
            sleep: { delay in await gate.sleep(delay) }
        )

        model.refreshNow(force: true)
        let firstStep = await gate.waitForSleeps(count: 1)
        clock.advance(by: 3600)
        await gate.open()
        let secondStep = await gate.waitForSleeps(count: 2)

        XCTAssertEqual(firstStep, [3600])
        XCTAssertEqual(secondStep, [3600, 1400])
        clock.advance(by: 1400)
        await gate.open()
    }

    @MainActor
    func testRefreshDoesNotOverlapAnInFlightEndpoint() async {
        let fixture = TestDefaultsFixture(providers: [.codex])
        defer { fixture.clear() }
        let defaults = fixture.defaults
        let slowFetch = SuspendedCodexFetch()
        let model = UsageModel(
            defaults: defaults,
            fetcher: UsageFetcher { endpoint in
                guard endpoint == .codex else { return testCodexResult() }
                return try await slowFetch.fetch()
            },
            now: fixedNow,
            automaticallySchedules: false
        )

        model.refreshNow(force: true)
        let startedInitialRequest = await slowFetch.waitForStarts(1)
        XCTAssertTrue(startedInitialRequest)

        model.refreshNow(force: true)
        model.refreshNow()

        let startCount = await slowFetch.startCount()
        XCTAssertEqual(startCount, 1)
        await slowFetch.release()
        let receivedCodex = await waitUntil { model.refreshStates[.codex]?.lastSuccess != nil }
        XCTAssertTrue(receivedCodex)
    }

    @MainActor
    func testFastProviderPublishesWhileAnotherProviderIsStillLoading() async throws {
        let fixture = TestDefaultsFixture(providers: [.codex, .claude])
        defer { fixture.clear() }
        let defaults = fixture.defaults
        let slowFetch = SuspendedCodexFetch()
        let model = UsageModel(
            defaults: defaults,
            fetcher: UsageFetcher { endpoint in
                switch endpoint {
                case .codex:
                    return try await slowFetch.fetch()
                case .claude:
                    return try testClaudeResult()
                default:
                    return testCodexResult()
                }
            },
            now: fixedNow,
            automaticallySchedules: false
        )

        model.refreshNow(force: true)

        let startedCodex = await slowFetch.waitForStarts(1)
        let receivedClaude = await waitUntil { model.claudeAvailable }
        XCTAssertTrue(startedCodex)
        XCTAssertTrue(receivedClaude)
        XCTAssertFalse(model.claudeBuckets.isEmpty)
        XCTAssertTrue(model.buckets.isEmpty)
        XCTAssertTrue(model.isLoading)

        await slowFetch.release()
        let receivedCodex = await waitUntil { model.refreshStates[.codex]?.lastSuccess != nil }
        XCTAssertTrue(receivedCodex)
    }

    @MainActor
    func testHiddenProviderKeepsItsInFlightRequestButDoesNotStartAnother() async throws {
        let fixture = TestDefaultsFixture(providers: [.codex, .claude])
        defer { fixture.clear() }
        let defaults = fixture.defaults
        let slowFetch = SuspendedCodexFetch()
        let model = UsageModel(
            defaults: defaults,
            fetcher: UsageFetcher { endpoint in
                switch endpoint {
                case .codex:
                    return try await slowFetch.fetch()
                case .claude:
                    return try testClaudeResult()
                default:
                    return testCodexResult()
                }
            },
            now: fixedNow,
            automaticallySchedules: false
        )

        model.refreshNow(force: true)
        let startedCodex = await slowFetch.waitForStarts(1)
        let receivedClaude = await waitUntil { model.claudeAvailable }
        XCTAssertTrue(startedCodex)
        XCTAssertTrue(receivedClaude)

        model.setVisibleInPopover(.codex, visible: false)
        model.refreshNow(force: true)
        await Task.yield()

        let startCount = await slowFetch.startCount()
        XCTAssertEqual(startCount, 1)

        await slowFetch.release()
        let receivedCodex = await waitUntil { model.refreshStates[.codex]?.lastSuccess != nil }
        XCTAssertTrue(receivedCodex)
    }

    @MainActor
    func testClaudeNotSignedInMessageAppearsWhileCodexIsStillLoading() async {
        let fixture = TestDefaultsFixture(providers: [.codex, .claude])
        defer { fixture.clear() }
        let defaults = fixture.defaults
        let slowFetch = SuspendedCodexFetch()
        let model = UsageModel(
            defaults: defaults,
            fetcher: UsageFetcher { endpoint in
                switch endpoint {
                case .codex:
                    return try await slowFetch.fetch()
                case .claude:
                    throw ClaudeUsageError.notSignedIn
                default:
                    return testCodexResult()
                }
            },
            now: fixedNow,
            automaticallySchedules: false
        )

        model.refreshNow(force: true)
        let startedCodex = await slowFetch.waitForStarts(1)
        let receivedClaudeFailure = await waitUntil {
            model.refreshStates[.claude]?.lastError != nil
        }
        XCTAssertTrue(startedCodex)
        XCTAssertTrue(receivedClaudeFailure)
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(
            model.sectionMessage(for: .claude),
            "No Claude Code session. Run claude in Terminal, then /login."
        )

        await slowFetch.release()
        let finishedCodex = await waitUntil { !model.isLoading }
        XCTAssertTrue(finishedCodex)
    }

    @MainActor
    func testAnotherProvidersSuccessCannotRefreshFailedSavedData() async throws {
        let fixture = TestDefaultsFixture(providers: [.codex, .claude])
        defer { fixture.clear() }
        let oldDate = fixedNow().addingTimeInterval(-60)
        var previous = UsageRefreshState()
        previous.succeed(at: oldDate, interval: UsageEndpoint.codex.policy.interval)
        let saved = LimitBucket(
            kind: .primary, name: "Current Session", usedPercent: 70,
            resetAt: nil, resetAfterSeconds: nil, limitWindowSeconds: 18_000, reached: false
        )
        UsageSnapshotStore.save(
            UsageSnapshot(
                codexBuckets: [saved], fetchedAt: oldDate,
                refreshStates: ["codex": previous]
            ),
            to: fixture.defaults
        )
        let model = UsageModel(
            defaults: fixture.defaults,
            fetcher: UsageFetcher { endpoint in
                if endpoint == .codex { throw UsageError.network("Test failure") }
                return try testClaudeResult()
            },
            now: fixedNow,
            automaticallySchedules: false
        )
        model.refreshNow(force: true)
        let receivedBoth = await waitUntil {
            model.refreshStates[.codex]?.lastError != nil
                && model.refreshStates[.claude]?.lastSuccess != nil
        }
        XCTAssertTrue(receivedBoth)
        XCTAssertEqual(model.refreshStates[.codex]?.lastSuccess, oldDate)
        XCTAssertEqual(model.refreshStates[.claude]?.lastSuccess, fixedNow())
        XCTAssertEqual(model.buckets.first?.usedPercent, 70)
        XCTAssertEqual(model.lastUpdated, fixedNow())
        XCTAssertTrue(model.freshnessMessage(for: .codex, at: fixedNow())?.hasPrefix("Saved data") == true)
    }

    @MainActor
    func testFreshnessMessageSwitchesToSavedDataAfterTheRefreshInterval() {
        let fixture = TestDefaultsFixture(providers: [.codex])
        defer { fixture.clear() }
        let defaults = fixture.defaults
        var state = UsageRefreshState()
        let completedAt = fixedNow()
        state.succeed(at: completedAt, interval: UsageEndpoint.codex.policy.interval)
        UsageSnapshotStore.save(
            UsageSnapshot(
                fetchedAt: completedAt,
                refreshStates: [UsageEndpoint.codex.rawValue: state]
            ),
            to: defaults
        )
        let model = UsageModel(
            defaults: defaults,
            fetcher: .live,
            now: fixedNow,
            automaticallySchedules: false
        )

        XCTAssertNil(model.freshnessMessage(for: .codex, at: completedAt))
        XCTAssertNil(
            model.freshnessMessage(for: .codex, at: completedAt.addingTimeInterval(UsageEndpoint.codex.policy.staleAfter))
        )
        XCTAssertTrue(
            model.freshnessMessage(
                for: .codex,
                at: completedAt.addingTimeInterval(UsageEndpoint.codex.policy.staleAfter + 2)
            )?.hasPrefix("Saved data from") == true
        )
    }

    @MainActor
    func testLegacySnapshotFreshnessStaysPendingWithoutAnEndpointSuccess() {
        let fixture = TestDefaultsFixture(providers: [.codex])
        defer { fixture.clear() }
        let defaults = fixture.defaults
        UsageSnapshotStore.save(
            UsageSnapshot(fetchedAt: fixedNow()),
            to: defaults
        )
        let model = UsageModel(
            defaults: defaults,
            fetcher: .live,
            now: fixedNow,
            automaticallySchedules: false
        )

        XCTAssertNil(model.refreshStates[.codex]?.lastSuccess)
        XCTAssertEqual(
            model.freshnessMessage(for: .codex, at: fixedNow()),
            "Saved data — refresh pending"
        )
    }

    @MainActor
    func testAutomaticSchedulerStartsAgainAtCompletionPlusThreeMinutes() async {
        let fixture = TestDefaultsFixture(providers: [.codex])
        defer { fixture.clear() }
        let defaults = fixture.defaults
        let clock = TestClock(fixedNow())
        let slowFetch = SuspendedCodexFetch()
        let sleeper = ControlledSleeper()
        let model = UsageModel(
            defaults: defaults,
            fetcher: UsageFetcher { endpoint in
                guard endpoint == .codex else { return testCodexResult() }
                return try await slowFetch.fetch()
            },
            now: { clock.date },
            automaticallySchedules: true,
            sleep: { delay in
                try await sleeper.sleep(for: delay)
            }
        )

        model.start()
        let startedInitialRequest = await slowFetch.waitForStarts(1)
        XCTAssertTrue(startedInitialRequest)

        clock.advance(by: 20)
        await slowFetch.release()

        let scheduledRefresh = await sleeper.waitForDelays(1)
        let delays = await sleeper.delays()
        XCTAssertTrue(scheduledRefresh)
        XCTAssertEqual(delays, [UsageEndpoint.codex.policy.interval])

        clock.advance(by: 179)
        model.refreshNow()
        let rescheduledTimer = await sleeper.waitForDelays(2)
        let prematureStartCount = await slowFetch.startCount()
        XCTAssertTrue(rescheduledTimer)
        XCTAssertEqual(prematureStartCount, 1)

        clock.advance(by: 1)
        let cancelledTimer = await sleeper.waitForPending(1)
        XCTAssertTrue(cancelledTimer)
        await sleeper.releaseNext()
        let startedDueRequest = await slowFetch.waitForStarts(2)
        XCTAssertTrue(startedDueRequest)

        await slowFetch.release()
        model.stop()
        await sleeper.cancelAll()
    }

    @MainActor
    func testSleepSuppressesRefreshUntilWakeForAStartedModel() async {
        let fixture = TestDefaultsFixture(providers: [.codex])
        defer { fixture.clear() }
        let defaults = fixture.defaults
        let calls = EndpointCallLog()
        let model = UsageModel(
            defaults: defaults,
            fetcher: UsageFetcher { endpoint in
                await calls.record(endpoint)
                return testCodexResult()
            },
            now: fixedNow,
            automaticallySchedules: false
        )

        model.setSleeping(true)
        model.start()
        model.refreshNow(force: true)
        await Task.yield()

        let sleepingCalls = await calls.count(for: .codex)
        XCTAssertEqual(sleepingCalls, 0)

        model.setSleeping(false)

        let wokeAndFetched = await calls.waitForCount(1)
        let receivedCodex = await waitUntil { model.refreshStates[.codex]?.lastSuccess != nil }
        XCTAssertTrue(wokeAndFetched)
        XCTAssertTrue(receivedCodex)
        model.stop()
    }

    @MainActor
    func testStopDropsTheResultOfAnInFlightRequest() async {
        let fixture = TestDefaultsFixture(providers: [.codex])
        defer { fixture.clear() }
        let defaults = fixture.defaults
        let slowFetch = SuspendedCodexFetch()
        let model = UsageModel(
            defaults: defaults,
            fetcher: UsageFetcher { endpoint in
                guard endpoint == .codex else { return testCodexResult() }
                return try await slowFetch.fetch()
            },
            now: fixedNow,
            automaticallySchedules: false
        )

        model.refreshNow(force: true)
        let startedRequest = await slowFetch.waitForStarts(1)
        XCTAssertTrue(startedRequest)

        model.stop()
        await slowFetch.release()

        let finishedRequest = await waitUntil { !model.isLoading }
        XCTAssertTrue(finishedRequest)
        XCTAssertNil(model.refreshStates[.codex]?.lastSuccess)
        XCTAssertTrue(model.buckets.isEmpty)
    }

    @MainActor
    func testThrottleCooldownPersistsAndBlocksAForcedRefreshAfterRestore() async {
        let fixture = TestDefaultsFixture(providers: [.codex])
        defer { fixture.clear() }
        let defaults = fixture.defaults
        let retryAfter = fixedNow().addingTimeInterval(600)
        let initialCalls = EndpointCallLog()
        let initial = UsageModel(
            defaults: defaults,
            fetcher: UsageFetcher { endpoint in
                await initialCalls.record(endpoint)
                throw UsageError.throttled(retryAfter: retryAfter)
            },
            now: fixedNow,
            automaticallySchedules: false
        )

        initial.refreshNow(force: true)

        let recordedThrottle = await initialCalls.waitForCount(1)
        let persistedThrottle = await waitUntil {
            initial.refreshStates[.codex]?.backoff.blockedUntil == retryAfter
        }
        XCTAssertTrue(recordedThrottle)
        XCTAssertTrue(persistedThrottle)
        XCTAssertEqual(
            UsageSnapshotStore.load(from: defaults)?.refreshStates[UsageEndpoint.codex.rawValue]?.backoff.blockedUntil,
            retryAfter
        )

        let restoredCalls = EndpointCallLog()
        let restored = UsageModel(
            defaults: defaults,
            fetcher: UsageFetcher { endpoint in
                await restoredCalls.record(endpoint)
                return testCodexResult()
            },
            now: fixedNow,
            automaticallySchedules: false
        )

        restored.refreshNow(force: true)
        await Task.yield()

        XCTAssertEqual(restored.refreshStates[.codex]?.backoff.blockedUntil, retryAfter)
        let restoredCodexCalls = await restoredCalls.count(for: .codex)
        XCTAssertEqual(restoredCodexCalls, 0)
    }

    @MainActor
    func testHidingFromTheMenuBarKeepsFetchingForThePopover() async {
        let fixture = TestDefaultsFixture(providers: [.codex, .claude])
        defer { fixture.clear() }
        let calls = EndpointCallLog()
        let model = UsageModel(
            defaults: fixture.defaults,
            fetcher: UsageFetcher { endpoint in
                await calls.record(endpoint)
                return endpoint == .claude ? try testClaudeResult() : testCodexResult()
            },
            now: fixedNow,
            automaticallySchedules: false
        )

        model.setVisibleInMenuBar(.claude, visible: false)
        model.refreshNow(force: true)

        let fetchedBoth = await calls.waitForCount(2)
        let claudeCalls = await calls.count(for: .claude)
        XCTAssertTrue(fetchedBoth)
        XCTAssertEqual(claudeCalls, 1)
        XCTAssertFalse(model.isVisibleInMenuBar(.claude))
        XCTAssertTrue(model.isVisibleInPopover(.claude))
    }

    @MainActor
    func testClaudePauseKeepsValuesAndSaysWhenItTriesAgain() async throws {
        let fixture = TestDefaultsFixture(providers: [.claude])
        defer { fixture.clear() }
        let clock = TestClock(fixedNow())
        let calls = EndpointCallLog()
        let responses = ResultQueue([
            .success(try testClaudeResult()),
            .failure(ClaudeUsageError.throttled(retryAfter: nil)),
        ])
        let model = UsageModel(
            defaults: fixture.defaults,
            fetcher: UsageFetcher { endpoint in
                await calls.record(endpoint)
                if endpoint == .claudeWhilePaused {
                    return .claude(ClaudeFetch(usage: nil, source: .claudeCode, dataDate: fixedNow()))
                }
                return try await responses.next()
            },
            now: { clock.date },
            automaticallySchedules: false
        )

        model.refreshNow(force: true)
        let firstDone = await waitUntil { model.refreshStates[.claude]?.lastSuccess != nil && !model.isLoading }
        clock.advance(by: 120)
        model.refreshNow(force: true)
        let paused = await waitUntil { model.claudePausedUntil(at: clock.date) != nil && !model.isLoading }

        XCTAssertTrue(firstDone)
        XCTAssertTrue(paused)
        XCTAssertEqual(model.claudeBuckets.map(\.usedPercent), [25])
        let time = ClockText.from(fixedNow(), relativeTo: clock.date)
        let next = ClockText.at(clock.date.addingTimeInterval(300), relativeTo: clock.date)
        XCTAssertEqual(
            model.sectionMessage(for: .claude),
            "Anthropic paused usage updates. Showing values from \(time). Next try \(next)."
        )
        XCTAssertNil(model.freshnessMessage(for: .claude, at: clock.date))

        clock.advance(by: 120)
        model.refreshNow(force: true)
        await Task.yield()
        let endpointCalls = await calls.count(for: .claude)
        XCTAssertEqual(endpointCalls, 2)
    }

    @MainActor
    func testWhilePausedTheQuotaCheckFollowsTheSetting() async throws {
        let fixture = TestDefaultsFixture(providers: [.claude])
        defer { fixture.clear() }
        let contexts = ContextLog()
        let model = UsageModel(
            defaults: fixture.defaults,
            fetcher: UsageFetcher(fetch: { endpoint, context in
                await contexts.record(endpoint, context)
                if endpoint == .claude {
                    throw ClaudeUsageError.throttled(retryAfter: fixedNow().addingTimeInterval(1800))
                }
                return .claude(ClaudeFetch(usage: nil, source: .claudeCode, dataDate: fixedNow()))
            }),
            now: fixedNow,
            automaticallySchedules: false
        )

        model.refreshNow(force: true)
        let paused = await waitUntil { model.claudePausedUntil(at: fixedNow()) != nil && !model.isLoading }
        model.refreshNow()
        let fallbackRan = await contexts.waitForCount(2)
        let first = await contexts.entries()

        XCTAssertTrue(paused)
        XCTAssertTrue(fallbackRan)
        XCTAssertEqual(first.map(\.0), [.claude, .claudeWhilePaused])
        XCTAssertEqual(first.last?.1.claudeQuotaCheck, false)
        XCTAssertFalse(model.claudeQuotaCheckEnabled)
    }

    @MainActor
    func testQuotaCheckResultUpdatesTheSessionAndKeepsModelRows() async throws {
        let fixture = TestDefaultsFixture(providers: [.claude])
        defer { fixture.clear() }
        let full = try ClaudeFixtures.decode(ClaudeFixtures.withSession)
        let probe = try XCTUnwrap(ClaudeUnifiedHeaders.response(from: [
            "anthropic-ratelimit-unified-5h-utilization": "0.5",
            "anthropic-ratelimit-unified-5h-reset": "1788010000",
        ], scopedModelName: nil))
        let responses = ResultQueue([
            .success(.claude(ClaudeFetch(usage: full, source: .usageEndpoint, dataDate: fixedNow()))),
            .failure(ClaudeUsageError.throttled(retryAfter: nil)),
        ])
        let clock = TestClock(fixedNow())
        let model = UsageModel(
            defaults: fixture.defaults,
            fetcher: UsageFetcher { endpoint in
                if endpoint == .claudeWhilePaused {
                    return .claude(ClaudeFetch(usage: probe, source: .quotaCheck, dataDate: fixedNow()))
                }
                return try await responses.next()
            },
            now: { clock.date },
            automaticallySchedules: false
        )

        model.refreshNow(force: true)
        _ = await waitUntil { !model.claudeBuckets.isEmpty && !model.isLoading }
        clock.advance(by: 61)
        model.refreshNow(force: true)
        _ = await waitUntil { model.claudePausedUntil(at: clock.date) != nil && !model.isLoading }
        model.refreshNow()
        let probed = await waitUntil { model.claudeBuckets.first?.usedPercent == 50 }

        XCTAssertTrue(probed)
        XCTAssertEqual(model.claudeBuckets.map(\.kind), [.session, .weeklyAll, .weeklyScoped])
    }

    @MainActor
    func testAnotherClaudeAccountLiftsThePause() async throws {
        let fixture = TestDefaultsFixture(providers: [.claude])
        defer { fixture.clear() }
        let usage = try ClaudeFixtures.decode(ClaudeFixtures.withSession)
        let responses = ResultQueue([
            .success(.claude(ClaudeFetch(usage: usage, source: .usageEndpoint, dataDate: fixedNow(), accountKey: "first"))),
            .failure(ClaudeUsageError.throttled(retryAfter: nil)),
        ])
        let clock = TestClock(fixedNow())
        let model = UsageModel(
            defaults: fixture.defaults,
            fetcher: UsageFetcher { endpoint in
                if endpoint == .claudeWhilePaused {
                    return .claude(ClaudeFetch(usage: nil, source: .claudeCode, dataDate: fixedNow(), accountKey: "second"))
                }
                return try await responses.next()
            },
            now: { clock.date },
            automaticallySchedules: false
        )

        model.refreshNow(force: true)
        _ = await waitUntil { !model.claudeBuckets.isEmpty && !model.isLoading }
        clock.advance(by: 61)
        model.refreshNow(force: true)
        let paused = await waitUntil { model.claudePausedUntil(at: clock.date) != nil && !model.isLoading }
        let pausedFor = model.refreshStates[.claude]?.backoff.scope
        model.refreshNow()
        let lifted = await waitUntil { model.claudePausedUntil(at: clock.date) == nil }

        XCTAssertTrue(paused)
        XCTAssertEqual(pausedFor, "first")
        XCTAssertTrue(lifted)
    }

    @MainActor
    func testFailedQuotaChecksWaitFifteenMinutesFromTheLastTry() async throws {
        let fixture = TestDefaultsFixture(providers: [.claude])
        defer { fixture.clear() }
        let calls = EndpointCallLog()
        let quotaChecks = ResultQueue([
            .failure(ClaudeUsageError.network),
            .failure(ClaudeUsageError.throttled(retryAfter: nil)),
        ])
        let clock = TestClock(fixedNow())
        let model = UsageModel(
            defaults: fixture.defaults,
            fetcher: UsageFetcher { endpoint in
                await calls.record(endpoint)
                if endpoint == .claude {
                    throw ClaudeUsageError.throttled(retryAfter: fixedNow().addingTimeInterval(3600))
                }
                return try await quotaChecks.next()
            },
            now: { clock.date },
            automaticallySchedules: false
        )
        model.claudeQuotaCheckEnabled = true

        model.refreshNow(force: true)
        _ = await waitUntil { model.claudePausedUntil(at: clock.date) != nil && !model.isLoading }
        model.refreshNow()
        _ = await calls.waitForCount(2)
        _ = await waitUntil { !model.isLoading }
        for (offset, expected) in [(61.0, 1), (899, 1), (900, 2), (1_200, 2), (1_799, 2), (1_800, 3)] {
            clock.date = fixedNow().addingTimeInterval(offset)
            model.refreshNow(force: true)
            await Task.yield()
            _ = await waitUntil { !model.isLoading }
            let quotaCheckCalls = await calls.count(for: .claudeWhilePaused)
            XCTAssertEqual(quotaCheckCalls, expected, "at +\(Int(offset))s")
        }
    }

    @MainActor
    func testEmptyClaudeResponseSaysSo() async throws {
        let fixture = TestDefaultsFixture(providers: [.claude])
        defer { fixture.clear() }
        let empty = try ClaudeFixtures.decode(#"{"five_hour":null,"seven_day":null}"#)
        let model = UsageModel(
            defaults: fixture.defaults,
            fetcher: UsageFetcher { _ in .claude(ClaudeFetch(usage: empty, source: .usageEndpoint, dataDate: fixedNow())) },
            now: fixedNow,
            automaticallySchedules: false
        )

        model.refreshNow(force: true)
        let received = await waitUntil { model.claudeAvailable && !model.isLoading }

        XCTAssertTrue(received)
        XCTAssertEqual(model.sectionMessage(for: .claude), "Claude returned no limits.")
    }

    @MainActor
    func testClaudeWaitsFifteenMinutesUnlessTheRequestNeverLeftTheMac() async {
        for (transport, retry) in [(URLError(.timedOut), 900.0), (URLError(.notConnectedToInternet), 60)] {
            let fixture = TestDefaultsFixture(providers: [.claude])
            defer { fixture.clear() }
            let model = UsageModel(
                defaults: fixture.defaults,
                fetcher: UsageFetcher { _ in throw ClaudeUsageError(transportError: transport) },
                now: fixedNow,
                automaticallySchedules: false
            )

            model.refreshNow(force: true)
            let scheduled = await waitUntil {
                !model.isLoading && model.refreshStates[.claude]?.nextRefresh != nil
            }

            XCTAssertTrue(scheduled)
            XCTAssertEqual(
                model.refreshStates[.claude]?.nextRefresh,
                fixedNow().addingTimeInterval(retry),
                "\(transport.code)"
            )
        }
    }

    @MainActor
    func testNetworkErrorRightAfterWakeStaysHiddenAndRetriesSoon() async {
        let fixture = TestDefaultsFixture(providers: [.codex])
        defer { fixture.clear() }
        let clock = TestClock(fixedNow())
        let model = UsageModel(
            defaults: fixture.defaults,
            fetcher: UsageFetcher { _ in throw UsageError.network("offline") },
            now: { clock.date },
            automaticallySchedules: false
        )
        model.start()
        _ = await waitUntil { !model.isLoading }
        let errorBeforeSleep = model.errorMessage
        model.setSleeping(true)
        clock.advance(by: 61)
        model.setSleeping(false)
        let failed = await waitUntil { !model.isLoading && model.refreshStates[.codex]?.nextRefresh == clock.date.addingTimeInterval(15) }

        XCTAssertTrue(failed)
        XCTAssertEqual(model.errorMessage, errorBeforeSleep)
        model.stop()
    }

    @MainActor
    func testNoFetchStartsWhileTheNetworkIsDown() async {
        let fixture = TestDefaultsFixture(providers: [.codex])
        defer { fixture.clear() }
        let calls = EndpointCallLog()
        let model = UsageModel(
            defaults: fixture.defaults,
            fetcher: UsageFetcher { endpoint in
                await calls.record(endpoint)
                return testCodexResult()
            },
            now: fixedNow,
            automaticallySchedules: false
        )
        model.setNetworkAvailable(false)
        model.start()
        await Task.yield()
        let offlineCalls = await calls.count(for: .codex)

        model.setNetworkAvailable(true)
        let fetched = await calls.waitForCount(1)

        XCTAssertEqual(offlineCalls, 0)
        XCTAssertTrue(fetched)
        model.stop()
    }

    @MainActor
    func testSleepDropsTheResultOfAnInFlightRequest() async {
        let fixture = TestDefaultsFixture(providers: [.codex])
        defer { fixture.clear() }
        let slowFetch = SuspendedCodexFetch()
        let model = UsageModel(
            defaults: fixture.defaults,
            fetcher: UsageFetcher { _ in try await slowFetch.fetch() },
            now: fixedNow,
            automaticallySchedules: false
        )
        model.start()
        _ = await slowFetch.waitForStarts(1)

        model.setSleeping(true)
        await slowFetch.release()
        await Task.yield()

        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.refreshStates[.codex]?.lastSuccess)
        model.stop()
    }

    @MainActor
    func testPopoverAsksToSignInWhenAProviderHasNoKey() {
        let model = UsageModel(
            previewBuckets: [],
            planType: "pro",
            lastUpdated: fixedNow(),
            menuBarProviders: [.codex],
            popoverProviders: [.codex, .opencode],
            opencodeAvailable: false
        )

        XCTAssertNil(model.sectionMessage(for: .opencode))
        XCTAssertEqual(model.popoverMessage(for: .opencode), OpenCodeUsageError.notSignedIn.localizedDescription)
        XCTAssertFalse(model.showsOpenCode)
    }

    @MainActor
    func testFooterSaysHowLongAgoTheLastUpdateWas() {
        let model = UsageModel(previewBuckets: [], planType: "pro", lastUpdated: fixedNow())

        XCTAssertEqual(model.updatedText(at: fixedNow().addingTimeInterval(20)), "Updated just now")
        XCTAssertEqual(model.updatedText(at: fixedNow().addingTimeInterval(130)), "Updated 2 min ago")
        XCTAssertEqual(model.updatedText(at: fixedNow().addingTimeInterval(7_300)), "Updated 2 h ago")
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(testWaitTimeout)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

private let testWaitTimeout: TimeInterval = 1

private let fixedNow: @Sendable () -> Date = {
    Date(timeIntervalSince1970: 1_788_000_000)
}

@MainActor
private final class TestDefaultsFixture {
    let suiteName: String
    let defaults: UserDefaults

    init(providers: Set<LimitBucket.Provider>) {
        suiteName = "UsageModelRefreshTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        ProviderPreferences(popover: providers, menuBar: providers).save(to: defaults)
    }

    func clear() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class TestClock {
    var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func advance(by seconds: TimeInterval) {
        date = date.addingTimeInterval(seconds)
    }
}

private func testCodexResult() -> UsageFetchResult {
    .codex(
        try! JSONDecoder().decode(
            UsageResponse.self,
            from: Data("""
            {"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,
             "primary_window":{"used_percent":10,"limit_window_seconds":18000}}}
            """.utf8)
        )
    )
}

private func testClaudeResult(resetsAt: Date? = nil) throws -> UsageFetchResult {
    let reset = resetsAt.map { #","resets_at":"\#(ISO8601DateFormatter().string(from: $0))""# } ?? ""
    let response = try JSONDecoder().decode(
        ClaudeUsageResponse.self,
        from: Data("""
        {"five_hour":{"utilization":25\(reset)}}
        """.utf8)
    )
    return .claude(ClaudeFetch(usage: response, source: .usageEndpoint, dataDate: fixedNow(), plan: "max"))
}

private func testCursorResult() throws -> UsageFetchResult {
    let response = try JSONDecoder().decode(
        CursorUsageResponse.self,
        from: Data("""
        {"planUsage":{"autoPercentUsed":12,"apiPercentUsed":3},"enabled":true}
        """.utf8)
    )
    return .cursor(CursorUsageSnapshot(period: response, sand: nil, planInfo: nil, membershipType: "pro"))
}

private actor SleepGate {
    private var delays: [TimeInterval] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(_ delay: TimeInterval) async {
        delays.append(delay)
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitForSleeps(count: Int = 1) async -> [TimeInterval] {
        let deadline = Date().addingTimeInterval(testWaitTimeout)
        while delays.count < count, Date() < deadline {
            await Task.yield()
        }
        return delays
    }

    func open() {
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor EndpointCallLog {
    private var recorded: [UsageEndpoint] = []

    func record(_ endpoint: UsageEndpoint) {
        recorded.append(endpoint)
    }

    func endpoints() -> [UsageEndpoint] {
        recorded
    }

    func count(for endpoint: UsageEndpoint) -> Int {
        recorded.filter { $0 == endpoint }.count
    }

    func waitForCount(_ expected: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(testWaitTimeout)
        while Date() < deadline {
            if recorded.count >= expected { return true }
            await Task.yield()
        }
        return recorded.count >= expected
    }
}

private actor SuspendedCodexFetch {
    private var starts = 0
    private var continuation: CheckedContinuation<UsageFetchResult, Error>?

    func fetch() async throws -> UsageFetchResult {
        starts += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func startCount() -> Int {
        starts
    }

    func waitForStarts(_ expected: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(testWaitTimeout)
        while Date() < deadline {
            if starts >= expected { return true }
            await Task.yield()
        }
        return starts >= expected
    }

    func release() {
        continuation?.resume(returning: testCodexResult())
        continuation = nil
    }
}

private actor ControlledSleeper {
    private var recordedDelays: [TimeInterval] = []
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var pendingOrder: [Int] = []
    private var nextIdentifier = 0

    func sleep(for delay: TimeInterval) async throws {
        let identifier = nextIdentifier
        nextIdentifier += 1
        recordedDelays.append(delay)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                continuations[identifier] = continuation
                pendingOrder.append(identifier)
            }
        }, onCancel: {
            Task { await self.cancel(identifier) }
        })
    }

    func delays() -> [TimeInterval] {
        recordedDelays
    }

    func waitForDelays(_ expected: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(testWaitTimeout)
        while Date() < deadline {
            if recordedDelays.count >= expected { return true }
            await Task.yield()
        }
        return recordedDelays.count >= expected
    }

    func releaseNext() {
        guard let identifier = pendingOrder.first,
              let continuation = removeContinuation(identifier) else {
            return
        }
        continuation.resume(returning: ())
    }

    func waitForPending(_ expected: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(testWaitTimeout)
        while Date() < deadline {
            if continuations.count == expected { return true }
            await Task.yield()
        }
        return continuations.count == expected
    }

    func cancelAll() {
        let pending = continuations.values
        continuations = [:]
        pendingOrder = []
        for continuation in pending {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func cancel(_ identifier: Int) {
        removeContinuation(identifier)?.resume(throwing: CancellationError())
    }

    private func removeContinuation(_ identifier: Int) -> CheckedContinuation<Void, Error>? {
        pendingOrder.removeAll { $0 == identifier }
        return continuations.removeValue(forKey: identifier)
    }
}

private actor ResultQueue {
    private var results: [Result<UsageFetchResult, Error>]

    init(_ results: [Result<UsageFetchResult, Error>]) {
        self.results = results
    }

    func next() throws -> UsageFetchResult {
        guard !results.isEmpty else { return testCodexResult() }
        return try results.removeFirst().get()
    }
}

private actor ContextLog {
    private var recorded: [(UsageEndpoint, UsageFetchContext)] = []

    func record(_ endpoint: UsageEndpoint, _ context: UsageFetchContext) {
        recorded.append((endpoint, context))
    }

    func entries() -> [(UsageEndpoint, UsageFetchContext)] {
        recorded
    }

    func waitForCount(_ expected: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(testWaitTimeout)
        while Date() < deadline {
            if recorded.count >= expected { return true }
            await Task.yield()
        }
        return recorded.count >= expected
    }
}
