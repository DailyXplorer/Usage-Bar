import XCTest
@testable import UsageBar

final class RetryAfterTests: XCTestCase {
    func testParsesDelayAndHTTPDate() throws {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(RetryAfter.date(from: " 120 ", now: now), now.addingTimeInterval(120))
        XCTAssertEqual(RetryAfter.date(from: "Thu, 01 Jan 1970 00:10:00 GMT", now: now), now.addingTimeInterval(600))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com")!, statusCode: 429,
            httpVersion: nil, headerFields: ["Retry-After": "90"]
        ))
        XCTAssertEqual(RetryAfter.date(from: response, now: now), now.addingTimeInterval(90))
    }

    func testInvalidHeadersDoNotOverrideBackoff() {
        for value in [nil, "", "garbage", "-1", "1.5", "inf", "nan"] as [String?] {
            XCTAssertNil(RetryAfter.date(from: value))
        }
    }

    func testServerDeadlineAndRepeatedThrottleNeverShortenExistingCooldown() {
        let now = Date(timeIntervalSince1970: 0)
        var backoff = ThrottleBackoff()
        backoff.recordThrottle(now: now, retryAfter: now.addingTimeInterval(7200))
        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(7200))
        backoff.recordThrottle(now: now.addingTimeInterval(1), retryAfter: now)
        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(7200))
        backoff.reset()
        backoff.recordThrottle(now: now, retryAfter: now.addingTimeInterval(1))
        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(300))
    }
}
