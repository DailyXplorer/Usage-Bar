import XCTest
@testable import UsageBar

final class UsageSnapshotStoreTests: XCTestCase {
    private func bucket(resetAt: Date?, resetAfterSeconds: Int?) -> LimitBucket {
        LimitBucket(
            provider: .claude,
            kind: .weeklyAll,
            name: "All models",
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
                    name: "Current session",
                    usedPercent: 4,
                    resetAt: Date(timeIntervalSince1970: 1_786_634_858),
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
                    name: "Current session",
                    usedPercent: 13,
                    resetAt: Date(timeIntervalSince1970: 1_786_638_458),
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

    func testMenuBarPreferencesDefaultToCodexAndClaude() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        XCTAssertEqual(MenuBarPreferences.load(from: defaults), [.codex, .claude])

        MenuBarPreferences.save([.cursor, .codex], to: defaults)
        XCTAssertEqual(MenuBarPreferences.load(from: defaults), [.codex, .cursor])
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
            "All models",
            "Fable",
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
                    name: "Current session",
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
            "All models",
            "Fable",
        ])

        let persisted = try XCTUnwrap(UsageSnapshotStore.load(from: defaults))
        XCTAssertEqual(persisted.claudeBuckets.map(\.name), [
            "Current session",
            "All models",
            "Fable",
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
                        resetAt: Date(timeIntervalSince1970: 1_786_634_858),
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
                        resetAt: Date(timeIntervalSince1970: 1_786_638_458),
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

    func testBackoffCapsAtTheLongestStep() {
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        var backoff = ThrottleBackoff()
        for _ in 0..<10 {
            backoff.recordThrottle(now: now)
        }

        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(60 * 60))
    }
}
