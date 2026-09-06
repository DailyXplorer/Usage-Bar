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

        model.setVisibleInMenuBar(.codex, visible: false)
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
            "No Claude Code session. Run `claude`, then `/login`."
        )

        await slowFetch.release()
        let finishedCodex = await waitUntil { !model.isLoading }
        XCTAssertTrue(finishedCodex)
    }

    @MainActor
    func testCursorRefreshContinuesWhileGrokBotIsRateLimited() async throws {
        let fixture = TestDefaultsFixture(providers: [.cursor])
        defer { fixture.clear() }
        let defaults = fixture.defaults
        let calls = EndpointCallLog()
        let retryAfter = fixedNow().addingTimeInterval(600)
        let model = UsageModel(
            defaults: defaults,
            fetcher: UsageFetcher { endpoint in
                await calls.record(endpoint)
                switch endpoint {
                case .cursor:
                    return try testCursorResult()
                case .cursorGrokBot:
                    throw CursorUsageError.throttled(retryAfter: retryAfter)
                default:
                    return testCodexResult()
                }
            },
            now: fixedNow,
            automaticallySchedules: false
        )

        model.refreshNow(force: true)

        let refreshedCursorAndThrottledGrok = await waitUntil {
            model.refreshStates[.cursor]?.lastSuccess != nil
                && model.refreshStates[.cursorGrokBot]?.backoff.blockedUntil != nil
        }
        XCTAssertTrue(refreshedCursorAndThrottledGrok)
        XCTAssertEqual(model.refreshStates[.cursorGrokBot]?.backoff.blockedUntil, retryAfter)

        model.refreshNow(force: true)

        let recordedSecondCursorRequest = await calls.waitForCount(3)
        let cursorCalls = await calls.count(for: .cursor)
        let grokCalls = await calls.count(for: .cursorGrokBot)
        XCTAssertTrue(recordedSecondCursorRequest)
        XCTAssertEqual(cursorCalls, 2)
        XCTAssertEqual(grokCalls, 1)
    }

    @MainActor
    func testAnotherProvidersSuccessCannotRefreshFailedSavedData() async throws {
        let fixture = TestDefaultsFixture(providers: [.codex, .claude])
        defer { fixture.clear() }
        let oldDate = fixedNow().addingTimeInterval(-60)
        var previous = UsageRefreshState()
        previous.succeed(at: oldDate)
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
        XCTAssertEqual(model.lastUpdated, oldDate)
        XCTAssertTrue(model.freshnessMessage(for: .codex, at: fixedNow())?.hasPrefix("Saved data") == true)
    }

    @MainActor
    func testGrokRefreshContinuesWhileCursorPeriodIsRateLimited() async {
        let fixture = TestDefaultsFixture(providers: [.cursor])
        defer { fixture.clear() }
        let calls = EndpointCallLog()
        let model = UsageModel(
            defaults: fixture.defaults,
            fetcher: UsageFetcher { endpoint in
                await calls.record(endpoint)
                if endpoint == .cursor {
                    throw CursorUsageError.throttled(retryAfter: fixedNow().addingTimeInterval(600))
                }
                return .cursorGrokBot(.refreshed(nil), CursorCredentials(accessToken: "test", membershipType: "pro"))
            },
            now: fixedNow,
            automaticallySchedules: false
        )
        model.refreshNow(force: true)
        let receivedBoth = await waitUntil {
            model.refreshStates[.cursor]?.lastError != nil
                && model.refreshStates[.cursorGrokBot]?.lastSuccess != nil
        }
        XCTAssertTrue(receivedBoth)
        model.refreshNow(force: true)
        let refreshedGrok = await calls.waitForCount(3)
        XCTAssertTrue(refreshedGrok)
        let periodCount = await calls.count(for: .cursor)
        let grokCount = await calls.count(for: .cursorGrokBot)
        XCTAssertEqual(periodCount, 1)
        XCTAssertEqual(grokCount, 2)
    }

    @MainActor
    func testFreshnessMessageSwitchesToSavedDataAfterTheRefreshInterval() {
        let fixture = TestDefaultsFixture(providers: [.codex])
        defer { fixture.clear() }
        let defaults = fixture.defaults
        var state = UsageRefreshState()
        let completedAt = fixedNow()
        state.succeed(at: completedAt)
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

        XCTAssertTrue(
            model.freshnessMessage(for: .codex, at: completedAt)?.hasPrefix("Updated at") == true
        )
        XCTAssertTrue(
            model.freshnessMessage(
                for: .codex,
                at: completedAt.addingTimeInterval(UsageRefreshState.interval + 2)
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
        XCTAssertEqual(delays, [UsageRefreshState.interval])

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
        MenuBarPreferences.save(providers, to: defaults)
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
        UsageResponse(
            planType: "pro",
            rateLimit: RateLimitStatus(
                allowed: true,
                limitReached: false,
                primaryWindow: RateLimitWindow(
                    usedPercent: 10,
                    limitWindowSeconds: 18_000,
                    resetAfterSeconds: 600,
                    resetAt: nil
                ),
                secondaryWindow: nil
            ),
            rateLimitReachedType: nil,
            rateLimitResetCredits: nil,
            additionalRateLimits: nil
        )
    )
}

private func testClaudeResult() throws -> UsageFetchResult {
    let response = try JSONDecoder().decode(
        ClaudeUsageResponse.self,
        from: Data("""
        {"five_hour":{"utilization":25}}
        """.utf8)
    )
    return .claude(
        response,
        ClaudeCredentials(
            accessToken: "token",
            subscriptionType: "max",
            rateLimitTier: nil,
            expiresAt: nil
        )
    )
}

private func testCursorResult() throws -> UsageFetchResult {
    let response = try JSONDecoder().decode(
        CursorUsageResponse.self,
        from: Data("""
        {"planUsage":{"autoPercentUsed":12,"apiPercentUsed":3},"enabled":true}
        """.utf8)
    )
    return .cursor(
        response,
        CursorCredentials(accessToken: "token", membershipType: "pro")
    )
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
