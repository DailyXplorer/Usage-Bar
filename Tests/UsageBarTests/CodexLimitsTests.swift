import XCTest
@testable import UsageBar

final class CodexLimitsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_400_000)
    private let sparkResetAt = 1_786_718_196

    func testSparkBarFollowsWeeklyWindow() throws {
        let buckets = CodexLimits.buckets(from: try decode(sparkPayload()), now: now)

        XCTAssertEqual(buckets.map(\.kind), [.primary, .spark])
        XCTAssertEqual(buckets.map(\.name), ["weekly", CodexLimits.sparkDisplayName])
        XCTAssertEqual(buckets.map(\.usedPercent), [42, 0])
        XCTAssertEqual(buckets.map(\.remainingPercent), [58, 100])
        XCTAssertEqual(buckets[1].resetAt, Date(timeIntervalSince1970: TimeInterval(sparkResetAt)))
        XCTAssertEqual(buckets[1].resetAfterSeconds, sparkResetAt - Int(now.timeIntervalSince1970))
        XCTAssertFalse(buckets[1].reached)
    }

    func testSparkUsesItsOwnLimitReached() throws {
        let payload = """
        {
          "plan_type": "prolite",
          "rate_limit": {
            "limit_reached": true,
            "primary_window": {
              "used_percent": 100,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 1000,
              "reset_at": 1786718196
            }
          },
          "additional_rate_limits": [{
            "limit_name": "GPT-5.3-Codex-Spark",
            "metered_feature": "codex_bengalfox",
            "rate_limit": {
              "limit_reached": false,
              "primary_window": {"used_percent": 3, "reset_at": 1786718196}
            }
          }]
        }
        """
        let buckets = CodexLimits.buckets(from: try decode(payload), now: now)

        XCTAssertTrue(buckets[0].reached)
        XCTAssertFalse(buckets[1].reached)
        XCTAssertEqual(buckets[1].usedPercent, 3)
    }

    func testEmptyAdditionalLimitsHideSpark() throws {
        let payload = """
        {
          "plan_type": "prolite",
          "rate_limit": {
            "primary_window": {
              "used_percent": 10,
              "limit_window_seconds": 604800
            }
          },
          "additional_rate_limits": []
        }
        """
        let buckets = CodexLimits.buckets(from: try decode(payload), now: now)

        XCTAssertEqual(buckets.map(\.kind), [.primary])
    }

    func testMissingAdditionalLimitsHideSpark() throws {
        let payload = """
        {
          "plan_type": "prolite",
          "rate_limit": {
            "primary_window": {
              "used_percent": 10,
              "limit_window_seconds": 604800
            }
          }
        }
        """
        let buckets = CodexLimits.buckets(from: try decode(payload), now: now)

        XCTAssertEqual(buckets.map(\.kind), [.primary])
        XCTAssertNil(try decode(payload).additionalRateLimits)
    }

    func testUnrelatedExtraLimitsAreIgnored() throws {
        let payload = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 10,
              "limit_window_seconds": 604800
            }
          },
          "additional_rate_limits": [{
            "limit_name": "Something else",
            "metered_feature": "codex_other",
            "rate_limit": {"primary_window": {"used_percent": 90}}
          }]
        }
        """
        let buckets = CodexLimits.buckets(from: try decode(payload), now: now)

        XCTAssertEqual(buckets.map(\.kind), [.primary])
    }

    func testSparkMatchesLimitNameWhenMeteredFeatureIsMissing() throws {
        let payload = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 10,
              "limit_window_seconds": 604800
            }
          },
          "additional_rate_limits": [{
            "limit_name": "GPT-5.3-Codex-Spark",
            "rate_limit": {"primary_window": {"used_percent": 8, "reset_at": 1786718196}}
          }]
        }
        """
        let buckets = CodexLimits.buckets(from: try decode(payload), now: now)

        XCTAssertEqual(buckets.map(\.kind), [.primary, .spark])
        XCTAssertEqual(buckets[1].usedPercent, 8)
    }

    @MainActor
    func testMenuBarStaysOnWeeklyWindow() throws {
        let buckets = CodexLimits.buckets(from: try decode(sparkPayload()), now: now)
        let model = UsageModel(
            previewBuckets: buckets,
            planType: "prolite",
            lastUpdated: now
        )

        XCTAssertEqual(model.menuBarText, "58%")
        XCTAssertEqual(model.buckets.map(\.kind), [.primary, .spark])
    }

    private func sparkPayload() -> String {
        """
        {
          "plan_type": "prolite",
          "rate_limit": {
            "limit_reached": false,
            "primary_window": {
              "used_percent": 42,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 1000,
              "reset_at": 1786718196
            }
          },
          "additional_rate_limits": [{
            "limit_name": "GPT-5.3-Codex-Spark",
            "metered_feature": "codex_bengalfox",
            "rate_limit": {
              "primary_window": {"used_percent": 0, "reset_at": 1786718196}
            }
          }]
        }
        """
    }

    private func decode(_ payload: String) throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: Data(payload.utf8))
    }
}
