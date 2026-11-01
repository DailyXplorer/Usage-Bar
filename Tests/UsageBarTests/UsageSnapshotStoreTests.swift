import XCTest
@testable import UsageBar

final class UsageSnapshotStoreTests: XCTestCase {
    private func bucket(resetAt: Date?, resetAfterSeconds: Int?) -> LimitBucket {
        LimitBucket(
            provider: .claude,
            kind: .weeklyAll,
            name: "All Models",
            usedPercent: 1,
            resetAt: resetAt,
            resetAfterSeconds: resetAfterSeconds,
            limitWindowSeconds: 604_800,
            reached: false
        )
    }

    func testSnapshotRoundTripsThroughUserDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        let snapshot = UsageSnapshot(
            codexBuckets: [
                LimitBucket(
                    kind: .additional,
                    scope: "additional.model_x.primary",
                    name: "Model X Weekly Limit",
                    usedPercent: 0,
                    resetAt: Date(timeIntervalSince1970: 1_786_402_800),
                    resetAfterSeconds: 600,
                    limitWindowSeconds: 604_800,
                    reached: false
                )
            ],
            codexPlan: "prolite",
            claudeBuckets: [bucket(resetAt: Date(timeIntervalSince1970: 1_786_402_800), resetAfterSeconds: 600)],
            claudePlan: "max",
            cursorBuckets: [
                LimitBucket(
                    provider: .cursor,
                    kind: .cursorModels,
                    name: "Cursor Models",
                    usedPercent: 12,
                    resetAt: Date(timeIntervalSince1970: 1_789_244_447),
                    resetAfterSeconds: 600,
                    limitWindowSeconds: 2_678_400,
                    reached: false
                )
            ],
            cursorPlan: "pro",
            opencodeBuckets: [
                LimitBucket(
                    provider: .opencode,
                    kind: .rolling,
                    name: "Current Session",
                    usedPercent: 4,
                    resetAt: Date().addingTimeInterval(600),
                    resetAfterSeconds: 600,
                    limitWindowSeconds: 18_000,
                    reached: false
                )
            ],
            opencodePlan: "Go",
            commandcodeBuckets: [
                LimitBucket(
                    provider: .commandcode,
                    kind: .rolling,
                    name: "Current Session",
                    usedPercent: 13,
                    resetAt: Date().addingTimeInterval(600),
                    resetAfterSeconds: 600,
                    limitWindowSeconds: CommandCodeLimits.rollingWindowSeconds,
                    reached: false
                )
            ],
            commandcodePlan: "individual-go",
            fetchedAt: Date(timeIntervalSince1970: 1_786_400_000)
        )
        UsageSnapshotStore.save(snapshot, to: defaults)

        let loaded = try XCTUnwrap(UsageSnapshotStore.load(from: defaults))
        XCTAssertEqual(loaded.codexPlan, "prolite")
        XCTAssertEqual(loaded.codexBuckets.map(\.kind), [.additional])
        XCTAssertEqual(loaded.codexBuckets.map(\.name), ["Model X Weekly Limit"])
        XCTAssertEqual(loaded.claudePlan, "max")
        XCTAssertEqual(loaded.claudeBuckets.count, 1)
        XCTAssertEqual(loaded.claudeBuckets[0].remainingPercent, 99)
        XCTAssertEqual(loaded.cursorPlan, "pro")
        XCTAssertEqual(loaded.cursorBuckets[0].remainingPercent, 88)
        XCTAssertNil(loaded.cursorBuckets[0].detail)
        XCTAssertEqual(loaded.opencodePlan, "Go")
        XCTAssertEqual(loaded.opencodeBuckets[0].remainingPercent, 96)
        XCTAssertEqual(loaded.commandcodePlan, "individual-go")
        XCTAssertEqual(loaded.commandcodeBuckets[0].remainingPercent, 87)
        XCTAssertEqual(loaded.fetchedAt, snapshot.fetchedAt)
    }

    func testLegacySnapshotWithoutCursorStillDecodes() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        let legacy = UsageSnapshot(
            claudeBuckets: [bucket(resetAt: Date(timeIntervalSince1970: 1_786_402_800), resetAfterSeconds: 600)],
            claudePlan: "max",
            fetchedAt: Date(timeIntervalSince1970: 1_786_400_000)
        )
        let data = try JSONEncoder().encode(legacy)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "cursorBuckets")
        object.removeValue(forKey: "cursorPlan")
        object.removeValue(forKey: "opencodeBuckets")
        object.removeValue(forKey: "opencodePlan")
        object.removeValue(forKey: "commandcodeBuckets")
        object.removeValue(forKey: "commandcodePlan")
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "lastUsageSnapshot")

        let loaded = try XCTUnwrap(UsageSnapshotStore.load(from: defaults))
        XCTAssertTrue(loaded.cursorBuckets.isEmpty)
        XCTAssertNil(loaded.cursorPlan)
        XCTAssertTrue(loaded.opencodeBuckets.isEmpty)
        XCTAssertNil(loaded.opencodePlan)
        XCTAssertTrue(loaded.commandcodeBuckets.isEmpty)
        XCTAssertNil(loaded.commandcodePlan)
        XCTAssertEqual(loaded.claudePlan, "max")
    }

    func testFreshInstallShowsDetectedProvidersOrCodexAndClaude() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let fallback = ProviderPreferences.load(from: defaults, detected: { [] })
        XCTAssertEqual(fallback.popover, [.codex, .claude])
        XCTAssertEqual(fallback.menuBar, [.codex, .claude])

        defaults.removePersistentDomain(forName: #function)
        let claudeOnly = ProviderPreferences.load(from: defaults, detected: { [.claude] })
        XCTAssertEqual(claudeOnly.popover, [.claude])
        XCTAssertEqual(claudeOnly.menuBar, [.claude])
    }

    func testOldMenuBarSettingMigratesToPopoverPlusDetectedProviders() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }
        defaults.set(["codex"], forKey: ProviderPreferences.menuBarKey)

        let migrated = ProviderPreferences.load(from: defaults, detected: { [.claude, .cursor] })

        XCTAssertEqual(migrated.menuBar, [.codex])
        XCTAssertEqual(migrated.popover, [.codex, .claude, .cursor])
        XCTAssertEqual(defaults.stringArray(forKey: ProviderPreferences.popoverKey), ["codex", "claude", "cursor"])
        let reloaded = ProviderPreferences.load(from: defaults, detected: { [] })
        XCTAssertEqual(reloaded, migrated)
    }

    func testMenuBarStaysASubsetOfThePopover() {
        var preferences = ProviderPreferences(popover: [.codex], menuBar: [.codex])

        preferences.setMenuBar(.claude, visible: true)
        XCTAssertEqual(preferences.popover, [.codex, .claude])
        XCTAssertEqual(preferences.menuBar, [.codex, .claude])

        preferences.setMenuBar(.claude, visible: false)
        XCTAssertEqual(preferences.popover, [.codex, .claude])
        XCTAssertEqual(preferences.menuBar, [.codex])

        preferences.setPopover(.codex, visible: false)
        XCTAssertEqual(preferences.popover, [.claude])
        XCTAssertEqual(preferences.menuBar, [.claude])
    }

    func testUnknownBucketKindDropsOnlyThatBucketAndKeepsThePause() throws {
        let blockedUntil = Date(timeIntervalSince1970: 1_786_400_600)
        let json = """
        {"fetchedAt": 0,
         "codexBuckets": [
           {"provider":"codex","kind":"spark","name":"Spark","usedPercent":3,"reached":false},
           {"provider":"codex","kind":"primary","name":"Weekly Limit","usedPercent":40,"reached":false}
         ],
         "refreshStates": {
           "claude": {"backoff": {"attempt": 2, "blockedUntil": \(blockedUntil.timeIntervalSinceReferenceDate)}},
           "codex": {"backoff": "broken"}
         }}
        """
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(snapshot.codexBuckets.map(\.kind), [.primary])
        XCTAssertEqual(snapshot.refreshStates["claude"]?.backoff.blockedUntil, blockedUntil)
        XCTAssertEqual(snapshot.refreshStates["claude"]?.backoff.attempt, 2)
    }

    func testRestoreCapsAPersistedPauseAtOneHour() {
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        var state = UsageRefreshState()
        state.throttle("Paused", retryAfter: nil, at: now, interval: 900)
        let farFuture = try? JSONDecoder().decode(
            ThrottleBackoff.self,
            from: Data(#"{"attempt":4,"blockedUntil":\#(now.addingTimeInterval(36_000).timeIntervalSinceReferenceDate)}"#.utf8)
        )
        state.backoff = farFuture ?? state.backoff

        let restored = UsageSnapshot(fetchedAt: now, refreshStates: ["claude": state]).refreshed(now: now)

        XCTAssertEqual(restored.refreshStates["claude"]?.backoff.blockedUntil, now.addingTimeInterval(3_600))
    }

    func testRestoreDropsBucketsWhoseWindowEndedLongAgo() {
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        let ancient = LimitBucket(
            provider: .opencode, kind: .rolling, name: "Rolling", usedPercent: 50,
            resetAt: now.addingTimeInterval(-60 * 24 * 3600), resetAfterSeconds: 0,
            limitWindowSeconds: 18_000, reached: false
        )
        let recent = LimitBucket(
            provider: .opencode, kind: .weekly, name: "Weekly", usedPercent: 50,
            resetAt: now.addingTimeInterval(-3600), resetAfterSeconds: 0,
            limitWindowSeconds: 604_800, reached: false
        )

        let restored = UsageSnapshot(opencodeBuckets: [ancient, recent], fetchedAt: now).refreshed(now: now)

        XCTAssertEqual(restored.opencodeBuckets.map(\.kind), [.weekly])
    }

    func testRefreshRewritesLegacyCodexTitles() {
        let snapshot = UsageSnapshot(
            codexBuckets: [
                LimitBucket(
                    kind: .primary,
                    name: "5h",
                    usedPercent: 12,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: 18_000,
                    reached: false
                ),
                LimitBucket(
                    kind: .secondary,
                    name: "weekly",
                    usedPercent: 40,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: 604_800,
                    reached: false
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_786_400_000)
        )

        let refreshed = snapshot.refreshed(now: Date(timeIntervalSince1970: 1_786_400_000))

        XCTAssertEqual(refreshed.codexBuckets.map(\.name), ["Current Session", "Weekly Limit"])
    }

    func testRefreshRewritesLegacyClaudeTitles() {
        let snapshot = UsageSnapshot(
            claudeBuckets: [
                LimitBucket(
                    provider: .claude,
                    kind: .session,
                    name: "Session 5h",
                    usedPercent: 100,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: 18_000,
                    reached: true
                ),
                LimitBucket(
                    provider: .claude,
                    kind: .weeklyAll,
                    name: "Week · All models",
                    usedPercent: 97,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: 604_800,
                    reached: false
                ),
                LimitBucket(
                    provider: .claude,
                    kind: .weeklyScoped,
                    name: "Week · Fable",
                    usedPercent: 100,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: 604_800,
                    reached: true
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_786_400_000)
        )

        let refreshed = snapshot.refreshed(now: Date(timeIntervalSince1970: 1_786_400_000))

        XCTAssertEqual(refreshed.claudeBuckets.map(\.name), [
            "Current session",
            "Current week (all models)",
            "Current week (Fable)",
        ])
    }

    func testRefreshRewritesLegacyOpenCodeRollingTitle() {
        let snapshot = UsageSnapshot(
            opencodeBuckets: [
                LimitBucket(
                    provider: .opencode,
                    kind: .rolling,
                    name: "Rolling 5h",
                    usedPercent: 4,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: OpenCodeLimits.rollingWindowSeconds,
                    reached: false
                )
            ],
            opencodePlan: "Go",
            fetchedAt: Date(timeIntervalSince1970: 1_786_400_000)
        )

        let refreshed = snapshot.refreshed(now: Date(timeIntervalSince1970: 1_786_400_000))

        XCTAssertEqual(refreshed.opencodeBuckets.map(\.name), [OpenCodeLimits.rollingDisplayName])
        XCTAssertEqual(refreshed.opencodePlan, OpenCodeLimits.planName)
    }

    func testRefreshRestoresGoBadgeWhenCachedPlanWasCleared() {
        let snapshot = UsageSnapshot(
            opencodeBuckets: [
                LimitBucket(
                    provider: .opencode,
                    kind: .rolling,
                    name: "Current Session",
                    usedPercent: 4,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: OpenCodeLimits.rollingWindowSeconds,
                    reached: false
                )
            ],
            opencodePlan: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_786_400_000)
        )

        let refreshed = snapshot.refreshed(now: Date(timeIntervalSince1970: 1_786_400_000))

        XCTAssertEqual(refreshed.opencodePlan, OpenCodeLimits.planName)
    }

    func testRefreshRewritesLegacyCommandCodeRollingTitle() {
        let snapshot = UsageSnapshot(
            commandcodeBuckets: [
                LimitBucket(
                    provider: .commandcode,
                    kind: .rolling,
                    name: "Rolling 5h",
                    usedPercent: 13,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: CommandCodeLimits.rollingWindowSeconds,
                    reached: false
                )
            ],
            commandcodePlan: "individual-go",
            fetchedAt: Date(timeIntervalSince1970: 1_786_400_000)
        )

        let refreshed = snapshot.refreshed(now: Date(timeIntervalSince1970: 1_786_400_000))

        XCTAssertEqual(refreshed.commandcodeBuckets.map(\.name), [CommandCodeLimits.rollingDisplayName])
        XCTAssertEqual(refreshed.commandcodePlan, "individual-go")
    }

    @MainActor
    func testRestorePersistsCanonicalClaudeTitles() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let fetchedAt = Date(timeIntervalSince1970: 1_786_400_000)
        UsageSnapshotStore.save(
            UsageSnapshot(
                claudeBuckets: [
                    LimitBucket(
                        provider: .claude,
                        kind: .session,
                        name: "Session 5h",
                        usedPercent: 100,
                        resetAt: nil,
                        resetAfterSeconds: nil,
                        limitWindowSeconds: 18_000,
                        reached: true
                    ),
                    LimitBucket(
                        provider: .claude,
                        kind: .weeklyAll,
                        name: "Week · All models",
                        usedPercent: 97,
                        resetAt: nil,
                        resetAfterSeconds: nil,
                        limitWindowSeconds: 604_800,
                        reached: false
                    ),
                    LimitBucket(
                        provider: .claude,
                        kind: .weeklyScoped,
                        name: "Week · Fable",
                        usedPercent: 100,
                        resetAt: nil,
                        resetAfterSeconds: nil,
                        limitWindowSeconds: 604_800,
                        reached: true
                    ),
                ],
                claudePlan: "max",
                fetchedAt: fetchedAt
            ),
            to: defaults
        )

        let model = UsageModel(defaults: defaults)
        XCTAssertEqual(model.claudeBuckets.map(\.name), [
            "Current session",
            "Current week (all models)",
            "Current week (Fable)",
        ])

        let persisted = try XCTUnwrap(UsageSnapshotStore.load(from: defaults))
        XCTAssertEqual(persisted.claudeBuckets.map(\.name), [
            "Current session",
            "Current week (all models)",
            "Current week (Fable)",
        ])
        XCTAssertEqual(persisted.fetchedAt, fetchedAt)
        XCTAssertEqual(persisted.claudePlan, "max")
    }

    @MainActor
    func testRestoreKeepsOpenCodeGoBadgeAndRelabelsRolling() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let fetchedAt = Date(timeIntervalSince1970: 1_786_400_000)
        UsageSnapshotStore.save(
            UsageSnapshot(
                opencodeBuckets: [
                    LimitBucket(
                        provider: .opencode,
                        kind: .rolling,
                        name: "Rolling 5h",
                        usedPercent: 4,
                        resetAt: Date().addingTimeInterval(600),
                        resetAfterSeconds: 600,
                        limitWindowSeconds: OpenCodeLimits.rollingWindowSeconds,
                        reached: false
                    )
                ],
                opencodePlan: "Go",
                fetchedAt: fetchedAt
            ),
            to: defaults
        )

        let model = UsageModel(defaults: defaults)
        XCTAssertEqual(model.opencodePlan, OpenCodeLimits.planName)
        XCTAssertEqual(model.opencodeBuckets.map(\.name), [OpenCodeLimits.rollingDisplayName])

        let persisted = try XCTUnwrap(UsageSnapshotStore.load(from: defaults))
        XCTAssertEqual(persisted.opencodePlan, OpenCodeLimits.planName)
        XCTAssertEqual(persisted.opencodeBuckets.map(\.name), [OpenCodeLimits.rollingDisplayName])
        XCTAssertEqual(persisted.fetchedAt, fetchedAt)
    }

    @MainActor
    func testRestoreKeepsCommandCodePlanAndRelabelsRolling() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let fetchedAt = Date(timeIntervalSince1970: 1_786_400_000)
        UsageSnapshotStore.save(
            UsageSnapshot(
                commandcodeBuckets: [
                    LimitBucket(
                        provider: .commandcode,
                        kind: .rolling,
                        name: "Rolling 5h",
                        usedPercent: 13,
                        resetAt: Date().addingTimeInterval(600),
                        resetAfterSeconds: 600,
                        limitWindowSeconds: CommandCodeLimits.rollingWindowSeconds,
                        reached: false
                    )
                ],
                commandcodePlan: "individual-go",
                fetchedAt: fetchedAt
            ),
            to: defaults
        )

        let model = UsageModel(defaults: defaults)
        XCTAssertEqual(model.commandcodePlan, "individual-go")
        XCTAssertEqual(model.commandcodeBuckets.map(\.name), [CommandCodeLimits.rollingDisplayName])

        let persisted = try XCTUnwrap(UsageSnapshotStore.load(from: defaults))
        XCTAssertEqual(persisted.commandcodePlan, "individual-go")
        XCTAssertEqual(persisted.commandcodeBuckets.map(\.name), [CommandCodeLimits.rollingDisplayName])
        XCTAssertEqual(persisted.fetchedAt, fetchedAt)
    }

    func testCountdownIsRecomputedOnLoad() {
        let resetAt = Date(timeIntervalSince1970: 1_786_402_800)
        let snapshot = UsageSnapshot(
            claudeBuckets: [bucket(resetAt: resetAt, resetAfterSeconds: 999_999)],
            fetchedAt: resetAt.addingTimeInterval(-7_200)
        )

        let refreshed = snapshot.refreshed(now: resetAt.addingTimeInterval(-1_800))

        XCTAssertEqual(refreshed.claudeBuckets[0].resetAfterSeconds, 1_800)
    }

    func testCountdownFloorsAtZeroOnceResetHasPassed() {
        let resetAt = Date(timeIntervalSince1970: 1_786_402_800)
        let snapshot = UsageSnapshot(
            claudeBuckets: [bucket(resetAt: resetAt, resetAfterSeconds: 600)],
            fetchedAt: resetAt
        )

        let refreshed = snapshot.refreshed(now: resetAt.addingTimeInterval(3_600))

        XCTAssertEqual(refreshed.claudeBuckets[0].resetAfterSeconds, 0)
    }

    func testBackoffWidensThenResets() {
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        var backoff = ThrottleBackoff()
        XCTAssertFalse(backoff.isBlocked)

        backoff.recordThrottle(now: now)
        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(5 * 60))

        backoff.recordThrottle(now: now)
        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(15 * 60))

        backoff.reset()
        XCTAssertFalse(backoff.isBlocked)
        XCTAssertNil(backoff.blockedUntil)
    }

    func testRetryAfterIsHonouredButNeverLongerThanOneHour() {
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        var backoff = ThrottleBackoff()

        backoff.recordThrottle(now: now, retryAfter: now.addingTimeInterval(120))
        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(120))

        backoff.reset()
        backoff.recordThrottle(now: now, retryAfter: now.addingTimeInterval(99_999_999))
        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(3_600))
    }

    func testBackoffCapsAtTheLongestStep() {
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        var backoff = ThrottleBackoff()
        for _ in 0..<10 {
            backoff.recordThrottle(now: now)
        }

        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(60 * 60))
    }
}
