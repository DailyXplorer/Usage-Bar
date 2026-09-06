import XCTest
@testable import UsageBar

final class BucketIdentityTests: XCTestCase {
    func testIdentitySurvivesRefreshDecodingAndRelabeling() throws {
        let cached = bucket(name: "Week · Opus")
        let refreshed = bucket(name: "Opus")
        let relabeled = ClaudeLimits.relabeled(cached)
        let decoded = try JSONDecoder().decode(
            LimitBucket.self,
            from: JSONEncoder().encode(cached)
        )

        XCTAssertEqual(cached.id, refreshed.id)
        XCTAssertEqual(cached.id, relabeled.id)
        XCTAssertEqual(cached.id, decoded.id)
        XCTAssertEqual(relabeled.name, "Opus")
    }

    func testIdentityChangesWithProviderKindScopeOrWindow() {
        let base = bucket()

        XCTAssertNotEqual(base.id, bucket(provider: .codex).id)
        XCTAssertNotEqual(base.id, bucket(kind: .weeklyAll).id)
        XCTAssertNotEqual(base.id, bucket(scope: "model:claude-sonnet-4-5").id)
        XCTAssertNotEqual(base.id, bucket(windowSeconds: 18_000).id)
    }

    func testLegacySnapshotWithoutScopeStillDecodes() throws {
        let legacy = """
        {
          "provider": "claude",
          "kind": "weeklyScoped",
          "name": "Opus",
          "usedPercent": 10,
          "reached": false
        }
        """
        let decoded = try JSONDecoder().decode(LimitBucket.self, from: Data(legacy.utf8))

        XCTAssertNil(decoded.scope)
        XCTAssertEqual(decoded.id, bucket(scope: nil, name: "Opus", windowSeconds: nil).id)
    }

    func testLegacyScopedBucketsDeriveDistinctScopesFromTheirNames() {
        let opus = ClaudeLimits.relabeled(
            bucket(scope: nil, name: "Week · Opus")
        )
        let sonnet = ClaudeLimits.relabeled(
            bucket(scope: nil, name: "Week · Sonnet")
        )

        XCTAssertEqual(opus.name, "Opus")
        XCTAssertEqual(sonnet.name, "Sonnet")
        XCTAssertEqual(opus.scope, "model-name:opus")
        XCTAssertEqual(sonnet.scope, "model-name:sonnet")
        XCTAssertNotEqual(opus.id, sonnet.id)
    }

    func testRelabelingPreservesModernScopedModelIdentity() {
        let modern = bucket(
            scope: "model:claude-opus-4-6",
            name: "Week · Opus"
        )
        let relabeled = ClaudeLimits.relabeled(modern)

        XCTAssertEqual(relabeled.scope, "model:claude-opus-4-6")
        XCTAssertEqual(relabeled.id, modern.id)
    }

    private func bucket(
        provider: LimitBucket.Provider = .claude,
        kind: LimitBucket.Kind = .weeklyScoped,
        scope: String? = "model:claude-opus-4-6",
        name: String = "Opus",
        windowSeconds: Int? = 604_800
    ) -> LimitBucket {
        LimitBucket(
            provider: provider,
            kind: kind,
            scope: scope,
            name: name,
            usedPercent: 10,
            resetAt: nil,
            resetAfterSeconds: nil,
            limitWindowSeconds: windowSeconds,
            reached: false
        )
    }
}
