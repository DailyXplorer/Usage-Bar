import Foundation
import XCTest
@testable import UsageBar

final class SharedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) {
        current = date
    }

    var date: Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

actor ScriptedFetches {
    private var results: [UsageEndpoint: [Result<UsageFetchResult, Error>]] = [:]
    private(set) var contexts: [(UsageEndpoint, UsageFetchContext)] = []

    func queue(_ endpoint: UsageEndpoint, _ result: Result<UsageFetchResult, Error>) {
        results[endpoint, default: []].append(result)
    }

    func next(_ endpoint: UsageEndpoint, _ context: UsageFetchContext) throws -> UsageFetchResult {
        contexts.append((endpoint, context))
        guard var queue = results[endpoint], !queue.isEmpty else { throw URLError(.notConnectedToInternet) }
        let result = queue.removeFirst()
        results[endpoint] = queue
        return try result.get()
    }

    func held(_ endpoint: UsageEndpoint) -> [String?] {
        contexts.filter { $0.0 == endpoint }.map { $0.1.heldKeyFingerprint }
    }
}

@MainActor
func makeClaudeModel(clock: SharedClock, defaults: UserDefaults, claudeCodeFile: URL) -> UsageModel {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ClaudeStubProtocol.self]
    let credentials = ClaudeCredentials(
        accessToken: "token-1",
        subscriptionType: "max",
        rateLimitTier: "default_claude_max_20x",
        expiresAt: nil,
        refreshToken: "refresh"
    )
    let service = ClaudeUsageService(
        credentials: ClaudeCredentialProvider(
            usable: { credentials },
            afterRejection: { _ in credentials },
            withoutRenewal: { credentials }
        ),
        session: URLSession(configuration: configuration),
        claudeCodeFile: claudeCodeFile,
        defaults: defaults,
        now: { clock.date }
    )
    ProviderPreferences(popover: [.claude], menuBar: [.claude]).save(to: defaults)
    return UsageModel(
        defaults: defaults,
        fetcher: UsageFetcher { endpoint, context in
            switch endpoint {
            case .claude:
                return .claude(try await service.fetchUsage(ownDataDate: context.dataDate))
            case .claudeWhilePaused:
                return .claude(try await service.fetchWhilePaused(
                    ownDataDate: context.dataDate,
                    quotaCheck: false,
                    scopedModelName: nil
                ))
            default:
                throw URLError(.notConnectedToInternet)
            }
        },
        now: { clock.date },
        automaticallySchedules: false
    )
}

@MainActor
final class RejectedUsageRequestsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUpWithError() throws {
        suiteName = "RejectedUsageRequestsTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RejectedUsageRequestsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ClaudeStubProtocol.reset()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        ClaudeStubProtocol.reset()
    }

    func testNonEnvelope403AdvancesTheBackoffLadderAndASuccessResetsIt() async throws {
        let clock = SharedClock(Date(timeIntervalSince1970: 1_793_500_000))
        ClaudeStubProtocol.respond(status: 403, json: "{}")
        ClaudeStubProtocol.respond(status: 500, json: "{}")
        ClaudeStubProtocol.respond(status: 403, json: "{}", headers: ["Retry-After": "7200"])
        ClaudeStubProtocol.respond(json: ClaudeFixtures.withSession)
        let model = claudeModel(clock: clock)

        model.refreshNow(force: true)
        let first = await waitUntil { model.refreshStates[.claude]?.backoff.attempt == 1 && !model.isLoading }
        XCTAssertTrue(first)
        let firstPause = try XCTUnwrap(model.refreshStates[.claude]?.backoff.blockedUntil)
        XCTAssertEqual(firstPause, clock.date.addingTimeInterval(300))
        XCTAssertEqual(
            model.sectionMessage(for: .claude)?.hasPrefix("Anthropic paused usage updates."),
            true
        )
        XCTAssertFalse(model.sectionMessage(for: .claude)?.contains("/login") == true)

        clock.advance(by: 301)
        model.refreshNow(force: true)
        let second = await waitUntil { model.refreshStates[.claude]?.backoff.attempt == 2 && !model.isLoading }
        XCTAssertTrue(second)
        XCTAssertEqual(
            model.refreshStates[.claude]?.backoff.blockedUntil,
            clock.date.addingTimeInterval(ThrottleBackoff.maximumPause)
        )

        clock.advance(by: ThrottleBackoff.maximumPause + 1)
        model.refreshNow(force: true)
        let recovered = await waitUntil { model.refreshStates[.claude]?.backoff.attempt == 0 && !model.isLoading }
        XCTAssertTrue(recovered)
        XCTAssertNil(model.refreshStates[.claude]?.backoff.blockedUntil)
        XCTAssertFalse(model.claudeBuckets.isEmpty)
        XCTAssertNil(model.claudeErrorMessage)
    }

    func testEnvelope403ShowsTheErrorTypeAndDoesNotPause() async throws {
        let clock = SharedClock(Date(timeIntervalSince1970: 1_793_500_000))
        ClaudeStubProtocol.respond(status: 403, json: #"{"error":{"type":"permission_error"}}"#)
        let model = claudeModel(clock: clock)

        model.refreshNow(force: true)
        let failed = await waitUntil { model.claudeErrorMessage != nil && !model.isLoading }

        XCTAssertTrue(failed)
        XCTAssertTrue(model.claudeErrorMessage?.contains("permission_error") == true)
        XCTAssertTrue(model.claudeErrorMessage?.contains("/login") == true)
        XCTAssertEqual(model.refreshStates[.claude]?.backoff.attempt, 0)
        XCTAssertNil(model.claudePausedUntil(at: clock.date))
        XCTAssertEqual(ClaudeStubProtocol.requests.map { $0.url?.path }, ["/api/oauth/usage"])
    }

    func testProfilePlanReachesTheBadgeAfterAThrottledUsageCall() async throws {
        let clock = SharedClock(Date(timeIntervalSince1970: 1_793_500_000))
        ClaudeStubProtocol.respond(status: 403, json: "{}")
        ClaudeStubProtocol.respond(json: #"{"organization":{"plan_display_name":"Ultra"}}"#)
        let model = claudeModel(clock: clock)

        model.refreshNow(force: true)
        let planShown = await waitUntil { model.claudePlan != nil && !model.isLoading }

        XCTAssertTrue(planShown)
        XCTAssertEqual(model.claudePlan, "Ultra")
        XCTAssertEqual(PlanBadgeLabel.text(for: model.claudePlan ?? "", provider: .claude), "Ultra")
    }

    func testProfileIsFetchedByThePausedRefreshWithoutTouchingTheUsageEndpoint() async throws {
        let clock = SharedClock(Date(timeIntervalSince1970: 1_793_500_000))
        ClaudeStubProtocol.respond(status: 403, json: "{}")
        ClaudeStubProtocol.respond(status: 500, json: "{}")
        let model = claudeModel(clock: clock)
        model.refreshNow(force: true)
        let paused = await waitUntil { model.claudePausedUntil(at: clock.date) != nil && !model.isLoading }
        XCTAssertTrue(paused)
        ClaudeProfilePlanCache(
            accountKey: ClaudeAccountKey.make("refresh"),
            planName: "Max",
            checkedAt: clock.date.addingTimeInterval(-25 * 3600)
        ).save(to: defaults)
        ClaudeStubProtocol.respond(json: #"{"organization":{"plan_display_name":"Ultra"}}"#)

        clock.advance(by: 120)
        model.refreshNow(force: true)
        let planShown = await waitUntil { model.claudePlan == "Ultra" && !model.isLoading }

        XCTAssertTrue(planShown)
        XCTAssertEqual(
            ClaudeStubProtocol.requests.map { $0.url?.path },
            ["/api/oauth/usage", "/api/oauth/profile", "/api/oauth/profile"]
        )
    }

    func testOneRejectedKeyIsNotSignedOut() async throws {
        for provider in [LimitBucket.Provider.opencode, .commandcode] {
            let fixture = try scriptedModel(provider: provider)
            await fixture.script.queue(fixture.endpoint, .success(try fixture.success()))
            await fixture.script.queue(fixture.endpoint, .failure(fixture.rejection("key-a")))

            try await fixture.refresh()
            XCTAssertFalse(fixture.model.buckets(for: provider).isEmpty)
            fixture.clock.advance(by: 301)
            try await fixture.refresh()

            XCTAssertFalse(fixture.model.isSignedOut(provider))
            XCTAssertFalse(fixture.model.buckets(for: provider).isEmpty, "\(provider)")
            XCTAssertTrue(fixture.model.sectionMessage(for: provider)?.contains("rejected the key") == true)
            XCTAssertEqual(fixture.model.refreshStates[fixture.endpoint]?.keyRejection?.count, 1)
        }
    }

    func testTwoRejectionsOfTheSameKeySignTheProviderOut() async throws {
        let expected: [LimitBucket.Provider: String] = [
            .opencode: "Signed out of OpenCode Go: the saved key no longer works. Run /connect in OpenCode, or hide OpenCode Go in Settings.",
            .commandcode: "Signed out of Command Code: the saved key no longer works. Run cmd login in Terminal, or hide Command Code in Settings.",
        ]
        for (provider, message) in expected {
            let fixture = try scriptedModel(provider: provider)
            await fixture.script.queue(fixture.endpoint, .success(try fixture.success()))
            await fixture.script.queue(fixture.endpoint, .failure(fixture.rejection("key-a")))
            await fixture.script.queue(fixture.endpoint, .failure(fixture.rejection("key-a")))

            try await fixture.refresh()
            fixture.clock.advance(by: 301)
            try await fixture.refresh()
            fixture.clock.advance(by: 301)
            try await fixture.refresh()

            let model = fixture.model
            XCTAssertTrue(model.isSignedOut(provider), "\(provider)")
            XCTAssertTrue(model.buckets(for: provider).isEmpty)
            XCTAssertNil(model.plan(for: provider))
            XCTAssertEqual(model.sectionMessage(for: provider), message)
            XCTAssertEqual(model.popoverMessage(for: provider), message)
            let segment = try XCTUnwrap(model.menuBarSegments.first { $0.provider == provider })
            XCTAssertEqual(segment.value, MenuBarSegment.placeholder)
            let saved = try XCTUnwrap(UsageSnapshotStore.load(from: defaults))
            XCTAssertTrue((provider == .opencode ? saved.opencodeBuckets : saved.commandcodeBuckets).isEmpty)
            XCTAssertEqual(saved.refreshStates[fixture.endpoint.rawValue]?.keyRejection?.count, 2)
        }
    }

    func testRejectionsOfDifferentKeysDoNotAddUp() async throws {
        let fixture = try scriptedModel(provider: .opencode)
        await fixture.script.queue(fixture.endpoint, .failure(fixture.rejection("key-a")))
        await fixture.script.queue(fixture.endpoint, .failure(fixture.rejection("key-b")))

        try await fixture.refresh()
        fixture.clock.advance(by: 301)
        try await fixture.refresh()

        XCTAssertFalse(fixture.model.isSignedOut(.opencode))
        XCTAssertEqual(fixture.model.refreshStates[.opencode]?.keyRejection?.count, 1)
    }

    func testSignedOutProviderIsHeldForAnHourThenRetriedAndRecoversOnSuccess() async throws {
        let fixture = try scriptedModel(provider: .opencode)
        for _ in 0..<2 { await fixture.script.queue(fixture.endpoint, .failure(fixture.rejection("key-a"))) }
        await fixture.script.queue(fixture.endpoint, .failure(OpenCodeUsageError.keyOnHold))
        await fixture.script.queue(fixture.endpoint, .failure(fixture.rejection("key-a")))
        await fixture.script.queue(fixture.endpoint, .success(try fixture.success()))
        let signedOutMessage = OpenCodeUsageError.signedOut.localizedDescription

        try await fixture.refresh()
        fixture.clock.advance(by: 301)
        try await fixture.refresh()
        XCTAssertTrue(fixture.model.isSignedOut(.opencode))

        fixture.clock.advance(by: 301)
        try await fixture.refresh()
        XCTAssertEqual(fixture.model.sectionMessage(for: .opencode), signedOutMessage)
        XCTAssertEqual(fixture.model.refreshStates[.opencode]?.keyRejection?.count, 2)

        fixture.clock.advance(by: KeyRejection.retryInterval)
        try await fixture.refresh()
        XCTAssertTrue(fixture.model.isSignedOut(.opencode))
        XCTAssertEqual(fixture.model.refreshStates[.opencode]?.keyRejection?.count, 3)

        fixture.clock.advance(by: 301)
        try await fixture.refresh()

        let fingerprints = await fixture.script.held(.opencode)
        XCTAssertEqual(fingerprints, [nil, nil, "key-a", nil, "key-a"])
        XCTAssertFalse(fixture.model.isSignedOut(.opencode))
        XCTAssertNil(fixture.model.refreshStates[.opencode]?.keyRejection)
        XCTAssertFalse(fixture.model.buckets(for: .opencode).isEmpty)
        XCTAssertNil(fixture.model.opencodeErrorMessage)
    }

    func testSignedOutStateSurvivesARelaunch() async throws {
        let fixture = try scriptedModel(provider: .commandcode)
        for _ in 0..<2 { await fixture.script.queue(fixture.endpoint, .failure(fixture.rejection("key-a"))) }
        try await fixture.refresh()
        fixture.clock.advance(by: 301)
        try await fixture.refresh()

        let relaunched = UsageModel(
            defaults: defaults,
            fetcher: UsageFetcher { _ in throw URLError(.notConnectedToInternet) },
            now: { fixture.clock.date },
            automaticallySchedules: false
        )

        XCTAssertTrue(relaunched.isSignedOut(.commandcode))
        XCTAssertTrue(relaunched.commandcodeBuckets.isEmpty)
        XCTAssertEqual(
            relaunched.sectionMessage(for: .commandcode),
            CommandCodeUsageError.signedOut.localizedDescription
        )
    }

    func testRefreshStateWithoutAKeyRejectionStillDecodes() throws {
        let legacy = Data(#"{"lastError":"x","backoff":{"attempt":0}}"#.utf8)

        let state = try JSONDecoder().decode(UsageRefreshState.self, from: legacy)

        XCTAssertNil(state.keyRejection)
        XCTAssertEqual(state.lastError, "x")
    }

    func testPersistedRejectionHoldsNothingButTheFingerprint() throws {
        var state = UsageRefreshState()
        state.rejectKey(fingerprint: "0123456789abcdef", at: Date(timeIntervalSince1970: 1_793_500_000))

        let text = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)

        XCTAssertTrue(text.contains("0123456789abcdef"))
        XCTAssertFalse(text.lowercased().contains("apikey"))
    }

    private func claudeModel(clock: SharedClock) -> UsageModel {
        makeClaudeModel(clock: clock, defaults: defaults, claudeCodeFile: directory.appendingPathComponent(".claude.json"))
    }

    private struct ScriptedModel {
        let model: UsageModel
        let script: ScriptedFetches
        let clock: SharedClock
        let provider: LimitBucket.Provider
        let endpoint: UsageEndpoint
        let success: () throws -> UsageFetchResult
        let rejection: (String) -> Error
        let refresh: () async throws -> Void
    }

    private func scriptedModel(provider: LimitBucket.Provider) throws -> ScriptedModel {
        let clock = SharedClock(Date(timeIntervalSince1970: 1_793_500_000))
        let script = ScriptedFetches()
        defaults.removePersistentDomain(forName: suiteName)
        ProviderPreferences(popover: [provider], menuBar: [provider]).save(to: defaults)
        let model = UsageModel(
            defaults: defaults,
            fetcher: UsageFetcher { endpoint, context in try await script.next(endpoint, context) },
            now: { clock.date },
            automaticallySchedules: false
        )
        let endpoint: UsageEndpoint = provider == .opencode ? .opencode : .commandcode
        let success: () throws -> UsageFetchResult = {
            let date = clock.date
            if provider == .opencode {
                let iso = ISO8601DateFormatter().string(from: date.addingTimeInterval(3 * 3_600))
                let payload = #"{"usage":{"rolling":{"status":"ok","percent":18,"resetsAt":"\#(iso)"}}}"#
                return .opencode(try JSONDecoder().decode(OpenCodeUsageResponse.self, from: Data(payload.utf8)))
            }
            return .commandcode(CommandCodeUsageSnapshot(
                planId: "individual-pro",
                subscriptionStatus: "active",
                currentPeriodEnd: ISO8601DateFormatter().string(from: date.addingTimeInterval(16 * 86_400)),
                credits: CommandCodeCreditsResponse.Credits(monthlyCredits: 21, purchasedCredits: 0, freeCredits: 0),
                windowLimits: CommandCodeCreditsResponse.WindowLimits(
                    limited: true,
                    fiveHour: CommandCodeWindow(
                        used: 1.2,
                        cap: 4,
                        exceeded: false,
                        resetAt: (date.timeIntervalSince1970 + 7_200) * 1_000
                    ),
                    weekly: nil
                ),
                monthlyUsed: 9
            ))
        }
        let rejection: (String) -> Error = { fingerprint in
            provider == .opencode
                ? OpenCodeUsageError.invalidKey(fingerprint: fingerprint)
                : CommandCodeUsageError.invalidKey(fingerprint: fingerprint)
        }
        let refresh: () async throws -> Void = { [self] in
            model.refreshNow(force: true)
            let done = await waitUntil {
                !model.isLoading && model.refreshStates[endpoint]?.lastAttempt == clock.date
            }
            XCTAssertTrue(done)
        }
        return ScriptedModel(
            model: model,
            script: script,
            clock: clock,
            provider: provider,
            endpoint: endpoint,
            success: success,
            rejection: rejection,
            refresh: refresh
        )
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
