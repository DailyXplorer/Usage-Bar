import Foundation
import XCTest
@testable import UsageBar

final class PaceForecastTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)
    private let week = 7 * 24 * 60 * 60
    private let hour: TimeInterval = 3_600

    func testEarlyInTheWindowThereIsNoForecast() {
        let resetAt = now.addingTimeInterval(TimeInterval(week) * 0.96)

        XCTAssertNil(PaceForecast.timeToExhaustion(windowSeconds: week, usedPercent: 40, resetAt: resetAt, now: now))
    }

    func testLowUsageHasNoForecast() {
        let resetAt = now.addingTimeInterval(TimeInterval(week) * 0.9)

        XCTAssertNil(PaceForecast.timeToExhaustion(windowSeconds: week, usedPercent: 2, resetAt: resetAt, now: now))
    }

    func testOnPaceHasNoForecast() {
        let resetAt = now.addingTimeInterval(84 * hour)

        XCTAssertNil(PaceForecast.timeToExhaustion(windowSeconds: week, usedPercent: 40, resetAt: resetAt, now: now))
        XCTAssertNil(PaceForecast.timeToExhaustion(windowSeconds: week, usedPercent: 50, resetAt: resetAt, now: now))
    }

    func testRunsOutBeforeTheReset() throws {
        let resetAt = now.addingTimeInterval(84 * hour)

        let seconds = try XCTUnwrap(
            PaceForecast.timeToExhaustion(windowSeconds: week, usedPercent: 75, resetAt: resetAt, now: now)
        )

        XCTAssertEqual(seconds, 28 * hour, accuracy: 1)
    }

    func testUnknownLengthHasNoForecast() {
        let resetAt = now.addingTimeInterval(hour)

        XCTAssertNil(PaceForecast.timeToExhaustion(windowSeconds: nil, usedPercent: 90, resetAt: resetAt, now: now))
        XCTAssertNil(PaceForecast.timeToExhaustion(windowSeconds: week, usedPercent: 90, resetAt: nil, now: now))
    }

    func testAReachedOrPassedWindowHasNoForecast() {
        XCTAssertNil(PaceForecast.timeToExhaustion(windowSeconds: week, usedPercent: 100, resetAt: now.addingTimeInterval(hour), now: now))
        XCTAssertNil(PaceForecast.timeToExhaustion(windowSeconds: week, usedPercent: 90, resetAt: now.addingTimeInterval(-60), now: now))
    }

    func testCodexRowShowsTheForecast() throws {
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data("""
        {"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,
         "primary_window":{"used_percent":90,"limit_window_seconds":18000,"reset_after_seconds":9000},
         "secondary_window":{"used_percent":20,"limit_window_seconds":604800,"reset_after_seconds":302400}}}
        """.utf8))
        let rows = CodexLimits.buckets(from: usage, now: now)

        XCTAssertEqual(rows.map { PaceForecast.text(for: $0, at: now) }, ["Runs out in ~16m at this pace", nil])
    }

    func testClaudeRowShowsTheForecast() throws {
        let resetsAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(84 * hour))
        let usage = try ClaudeFixtures.decode("""
        {"five_hour":null,"seven_day":{"utilization":75.0,"resets_at":"\(resetsAt)"}}
        """)
        let rows = ClaudeLimits.buckets(from: usage, now: now)

        XCTAssertEqual(rows.map { PaceForecast.text(for: $0, at: now) }, ["Runs out in ~1d 4h at this pace"])
    }

    func testCursorRowShowsTheForecastFromItsPeriod() throws {
        let iso = ISO8601DateFormatter()
        let sand = """
        {"currentPeriodStart":"\(iso.string(from: now.addingTimeInterval(-2 * 86_400)))","nextResetTimestampUtc":"\(iso.string(from: now.addingTimeInterval(5 * 86_400)))","usagePercent":50,"isUnified":true}
        """
        let snapshot = CursorUsageSnapshot(
            period: try JSONDecoder().decode(CursorUsageResponse.self, from: Data(#"{"enabled":true}"#.utf8)),
            sand: try JSONDecoder().decode(CursorSandUsageStatus.self, from: Data(sand.utf8)),
            planInfo: nil,
            membershipType: nil
        )
        let rows = CursorLimits.layout(for: snapshot, now: now).buckets

        XCTAssertEqual(rows.map { PaceForecast.text(for: $0, at: now) }, ["Runs out in ~2d 0h at this pace"])
    }

    func testOpenCodeRowShowsTheForecast() throws {
        let payload = """
        {"usage":{"rolling":{"status":"ok","percent":60,"resetsAt":"\(ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * hour)))"}}}
        """
        let rows = OpenCodeLimits.buckets(from: try JSONDecoder().decode(OpenCodeUsageResponse.self, from: Data(payload.utf8)), now: now)

        XCTAssertEqual(rows.map { PaceForecast.text(for: $0, at: now) }, ["Runs out in ~1h 20m at this pace"])
    }

    func testCommandCodeRowsShowTheForecastOnlyWhenAheadOfPace() {
        let millis = { (offset: TimeInterval) in (self.now.timeIntervalSince1970 + offset) * 1_000 }
        let snapshot = CommandCodeUsageSnapshot(
            planId: "individual-pro",
            subscriptionStatus: "active",
            currentPeriodEnd: nil,
            credits: nil,
            windowLimits: CommandCodeCreditsResponse.WindowLimits(
                limited: true,
                fiveHour: CommandCodeWindow(used: 3, cap: 4, exceeded: false, resetAt: millis(2 * hour)),
                weekly: CommandCodeWindow(used: 3, cap: 12, exceeded: false, resetAt: millis(3 * 86_400))
            ),
            monthlyUsed: nil
        )
        let rows = CommandCodeLimits.buckets(from: snapshot, now: now)

        XCTAssertEqual(rows.map { PaceForecast.text(for: $0, at: now) }, ["Runs out in ~1h 0m at this pace", nil])
    }

    func testCreditRowsNeverForecast() {
        let spend = LimitBucket(
            kind: .spendLimit,
            scope: CodexLimits.spendLimitScope,
            name: CodexLimits.spendLimitDisplayName,
            usedPercent: 90,
            resetAt: now.addingTimeInterval(hour),
            resetAfterSeconds: 3_600,
            limitWindowSeconds: 30 * 86_400,
            reached: false
        )

        XCTAssertNil(PaceForecast.text(for: spend, at: now))
    }
}
