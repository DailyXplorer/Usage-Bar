import Foundation
import XCTest
@testable import UsageBar

final class CommandCodeUsageServiceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_788_652_800)

    override func tearDown() {
        CommandCodeUsageServiceStubURLProtocol.reset()
        super.tearDown()
    }

    func testAccountCacheExpiresAfterThirtyMinutesWhileCreditsKeepRefreshing() async throws {
        let clock = CommandCodeUsageServiceTestClock(start)
        let periodStart = "2026-09-01T00:00:00Z"
        let periodEnd = "2026-09-06T02:00:00Z"
        CommandCodeUsageServiceStubURLProtocol.configure { request in
            self.standardResponse(
                for: request,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
        }
        let service = makeService(clock: clock)

        _ = try await fetchUsage(service, key: "key-one")
        clock.advance(by: 1_799)
        _ = try await fetchUsage(service, key: "key-one")

        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/whoami"), 1)
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/billing/subscriptions"), 1)
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/billing/credits"), 2)
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/usage/summary"), 2)

        clock.advance(by: 1)
        _ = try await fetchUsage(service, key: "key-one")

        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/whoami"), 2)
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/billing/subscriptions"), 2)
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/billing/credits"), 3)
    }

    func testAccountCacheUsesTTLWhenPeriodEndedInThePast() async throws {
        try await assertAccountCacheUsesTTL(periodEnd: start.addingTimeInterval(-1))
    }

    func testAccountCacheUsesTTLWhenPeriodEndsNow() async throws {
        try await assertAccountCacheUsesTTL(periodEnd: start)
    }

    private func assertAccountCacheUsesTTL(periodEnd: Date) async throws {
        let clock = CommandCodeUsageServiceTestClock(start)
        let periodEndString = ISO8601DateFormatter().string(from: periodEnd)
        CommandCodeUsageServiceStubURLProtocol.configure { request in
            self.standardResponse(
                for: request,
                periodStart: "2026-09-01T00:00:00Z",
                periodEnd: periodEndString
            )
        }
        let service = makeService(clock: clock)

        _ = try await fetchUsage(service, key: "key-one")
        clock.advance(by: 1_799)
        _ = try await fetchUsage(service, key: "key-one")

        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/whoami"), 1)
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/billing/subscriptions"), 1)
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/billing/credits"), 2)

        clock.advance(by: 1)
        _ = try await fetchUsage(service, key: "key-one")

        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/whoami"), 2)
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/billing/subscriptions"), 2)
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/billing/credits"), 3)
    }

    func testChangedKeyInvalidatesCachedIdentityAndUsesItsOrganization() async throws {
        let clock = CommandCodeUsageServiceTestClock(start)
        CommandCodeUsageServiceStubURLProtocol.configure { request in
            let key = request.value(forHTTPHeaderField: "Authorization")
            let organization = key == "Bearer key-two" ? "org-two" : "org-one"
            return self.standardResponse(
                for: request,
                organization: organization,
                periodStart: "2026-09-01T00:00:00Z",
                periodEnd: "2026-09-06T02:00:00Z"
            )
        }
        let service = makeService(clock: clock)

        _ = try await fetchUsage(service, key: "key-one")
        clock.advance(by: 1)
        _ = try await fetchUsage(service, key: "key-two")

        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/whoami"), 2)
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/billing/subscriptions"), 2)
        let organizationRequests = CommandCodeUsageServiceStubURLProtocol.requests(for: "/alpha/billing/credits")
        XCTAssertEqual(organizationRequests.count, 2)
        XCTAssertEqual(queryValue(named: "orgId", in: organizationRequests[0]), "org-one")
        XCTAssertEqual(queryValue(named: "orgId", in: organizationRequests[1]), "org-two")
        XCTAssertEqual(organizationRequests[1].value(forHTTPHeaderField: "Authorization"), "Bearer key-two")
    }

    func testPeriodEndBoundsAccountCacheAndRefreshesSummaryContext() async throws {
        let clock = CommandCodeUsageServiceTestClock(start)
        let rollover = start.addingTimeInterval(60)
        let oldPeriodStart = "2026-09-01T00:00:00Z"
        let newPeriodStart = "2026-09-06T01:00:00Z"
        CommandCodeUsageServiceStubURLProtocol.configure { request in
            let usesNewPeriod = clock.date >= rollover
            let periodStart = usesNewPeriod ? newPeriodStart : oldPeriodStart
            let periodEnd = usesNewPeriod ? "2026-09-06T02:00:00Z" : "2026-09-06T00:01:00Z"
            return self.standardResponse(
                for: request,
                periodStart: periodStart,
                periodEnd: periodEnd,
                summaryUsed: usesNewPeriod ? 1 : 9
            )
        }
        let service = makeService(clock: clock)

        let oldUsage = try await fetchUsage(service, key: "key-one")
        clock.advance(by: 60)
        let newUsage = try await fetchUsage(service, key: "key-one")

        XCTAssertEqual(oldUsage.monthlyUsed, 9)
        XCTAssertEqual(newUsage.monthlyUsed, 1)
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/billing/subscriptions"), 2)
        let summaries = CommandCodeUsageServiceStubURLProtocol.requests(for: "/alpha/usage/summary")
        XCTAssertEqual(queryValue(named: "since", in: summaries[0]), oldPeriodStart)
        XCTAssertEqual(queryValue(named: "since", in: summaries[1]), newPeriodStart)
    }

    func testSummaryRetryAfterBlocksOnlyTheOptionalSummaryRequest() async throws {
        let clock = CommandCodeUsageServiceTestClock(start)
        CommandCodeUsageServiceStubURLProtocol.configure { request in
            if request.url?.path == "/alpha/usage/summary" {
                if clock.date < self.start.addingTimeInterval(1_200) {
                    return .status(429, headers: ["Retry-After": "1200"])
                }
                return .ok(#"{ "totalMonthlyCredits": 3 }"#)
            }
            return self.standardResponse(
                for: request,
                periodStart: "2026-09-01T00:00:00Z",
                periodEnd: "2026-09-06T02:00:00Z"
            )
        }
        let service = makeService(clock: clock)

        let throttledUsage = try await fetchUsage(service, key: "key-one")
        clock.advance(by: 300)
        let cooldownUsage = try await fetchUsage(service, key: "key-one")

        XCTAssertNil(throttledUsage.monthlyUsed)
        XCTAssertNil(cooldownUsage.monthlyUsed)
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/usage/summary"), 1)
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/billing/credits"), 2)

        clock.advance(by: 900)
        let refreshedUsage = try await fetchUsage(service, key: "key-one")

        XCTAssertEqual(refreshedUsage.monthlyUsed, 3)
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/usage/summary"), 2)
    }

    func testSummaryFailureUsesCurrentCreditsInsteadOfAnOldSummary() async throws {
        let clock = CommandCodeUsageServiceTestClock(start)
        CommandCodeUsageServiceStubURLProtocol.configure { request in
            if request.url?.path == "/alpha/usage/summary", clock.date > self.start {
                return .status(500)
            }
            return self.standardResponse(
                for: request,
                periodStart: "2026-09-01T00:00:00Z",
                periodEnd: "2026-09-06T02:00:00Z",
                summaryUsed: 9
            )
        }
        let service = makeService(clock: clock)
        let first = try await fetchUsage(service, key: "key-one")
        XCTAssertEqual(first.monthlyUsed, 9)
        clock.advance(by: 180)
        let next = try await fetchUsage(service, key: "key-one")
        XCTAssertNil(next.monthlyUsed)
        XCTAssertEqual(CommandCodeLimits.buckets(from: next).first { $0.kind == .monthly }?.usedPercent, 20)
    }

    func testCreditsThrottlePreservesTheServerDeadline() async throws {
        let clock = CommandCodeUsageServiceTestClock(start)
        CommandCodeUsageServiceStubURLProtocol.configure { request in
            if request.url?.path == "/alpha/billing/credits" {
                return .status(429, headers: ["Retry-After": "1200"])
            }
            return self.standardResponse(
                for: request,
                periodStart: "2026-09-01T00:00:00Z",
                periodEnd: "2026-09-06T02:00:00Z"
            )
        }
        do {
            _ = try await fetchUsage(makeService(clock: clock), key: "key-one")
            XCTFail("Expected a throttle")
        } catch CommandCodeUsageError.throttled(let retryAfter) {
            XCTAssertEqual(retryAfter, start.addingTimeInterval(1200))
        }
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/usage/summary"), 0)
    }

    func testGenericSummaryFailureUsesThreeMinuteCooldown() async throws {
        let clock = CommandCodeUsageServiceTestClock(start)
        CommandCodeUsageServiceStubURLProtocol.configure { request in
            if request.url?.path == "/alpha/usage/summary" {
                return clock.date < self.start.addingTimeInterval(180)
                    ? .status(500)
                    : .ok(#"{ "totalMonthlyCredits": 2 }"#)
            }
            return self.standardResponse(
                for: request,
                periodStart: "2026-09-01T00:00:00Z",
                periodEnd: "2026-09-06T02:00:00Z"
            )
        }
        let service = makeService(clock: clock)

        _ = try await fetchUsage(service, key: "key-one")
        clock.advance(by: 179)
        _ = try await fetchUsage(service, key: "key-one")
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/usage/summary"), 1)

        clock.advance(by: 1)
        let refreshedUsage = try await fetchUsage(service, key: "key-one")
        XCTAssertEqual(refreshedUsage.monthlyUsed, 2)
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/usage/summary"), 2)
    }

    func testInvalidKeyClearsTheAccountCache() async throws {
        let clock = CommandCodeUsageServiceTestClock(start)
        CommandCodeUsageServiceStubURLProtocol.configure { request in
            if request.url?.path == "/alpha/billing/credits",
               clock.date == self.start.addingTimeInterval(1) {
                return .status(401)
            }
            return self.standardResponse(
                for: request,
                periodStart: "2026-09-01T00:00:00Z",
                periodEnd: "2026-09-06T02:00:00Z"
            )
        }
        let service = makeService(clock: clock)

        _ = try await fetchUsage(service, key: "key-one")
        clock.advance(by: 1)
        do {
            _ = try await fetchUsage(service, key: "key-one")
            XCTFail("Expected an invalid key")
        } catch {
            guard case CommandCodeUsageError.invalidKey = error else {
                return XCTFail("Expected invalid key, got \(error)")
            }
        }

        clock.advance(by: 1)
        _ = try await fetchUsage(service, key: "key-one")
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/whoami"), 2)
        XCTAssertEqual(CommandCodeUsageServiceStubURLProtocol.requestCount(for: "/alpha/billing/subscriptions"), 2)
    }

    private func makeService(clock: CommandCodeUsageServiceTestClock) -> CommandCodeUsageService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommandCodeUsageServiceStubURLProtocol.self]
        return CommandCodeUsageService(
            baseURL: URL(string: "https://commandcode.test")!,
            session: URLSession(configuration: configuration),
            now: { clock.date }
        )
    }

    private func fetchUsage(
        _ service: CommandCodeUsageService,
        key: String
    ) async throws -> CommandCodeUsageSnapshot {
        try await service.fetchUsage(
            from: [],
            environment: ["COMMAND_CODE_API_KEY": key]
        ).usage
    }

    private func standardResponse(
        for request: URLRequest,
        organization: String = "org-one",
        periodStart: String,
        periodEnd: String,
        summaryUsed: Double = 2
    ) -> CommandCodeUsageServiceStubResponse {
        switch request.url?.path {
        case "/alpha/whoami":
            return .ok("{ \"org\": { \"id\": \"\(organization)\" } }")
        case "/alpha/billing/subscriptions":
            return .ok("""
            {
              "data": {
                "planId": "individual-go",
                "status": "active",
                "currentPeriodStart": "\(periodStart)",
                "currentPeriodEnd": "\(periodEnd)"
              }
            }
            """)
        case "/alpha/billing/credits":
            return .ok("""
            {
              "credits": { "monthlyCredits": 8 },
              "windowLimits": { "limited": true }
            }
            """)
        case "/alpha/usage/summary":
            return .ok("{ \"totalMonthlyCredits\": \(summaryUsed) }")
        default:
            return .status(404)
        }
    }

    private func queryValue(named name: String, in request: URLRequest) -> String? {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }
}

private struct CommandCodeUsageServiceStubResponse {
    let status: Int
    let data: Data
    let headers: [String: String]

    static func ok(_ json: String) -> CommandCodeUsageServiceStubResponse {
        CommandCodeUsageServiceStubResponse(status: 200, data: Data(json.utf8), headers: [:])
    }

    static func status(
        _ code: Int,
        headers: [String: String] = [:]
    ) -> CommandCodeUsageServiceStubResponse {
        CommandCodeUsageServiceStubResponse(status: code, data: Data(), headers: headers)
    }
}

private final class CommandCodeUsageServiceStubURLProtocol: URLProtocol {
    private static let store = CommandCodeUsageServiceStubStore()

    static func configure(
        responseProvider: @escaping (URLRequest) -> CommandCodeUsageServiceStubResponse
    ) {
        store.configure(responseProvider: responseProvider)
    }

    static func reset() {
        store.reset()
    }

    static func requestCount(for path: String) -> Int {
        requests(for: path).count
    }

    static func requests(for path: String) -> [URLRequest] {
        store.requests.filter { $0.url?.path == path }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let response = Self.store.response(for: request),
              let url = request.url,
              let http = HTTPURLResponse(
                url: url,
                statusCode: response.status,
                httpVersion: nil,
                headerFields: response.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CommandCodeUsageServiceStubStore: @unchecked Sendable {
    private let lock = NSLock()
    private var responseProvider: ((URLRequest) -> CommandCodeUsageServiceStubResponse)?
    private var recordedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func configure(
        responseProvider: @escaping (URLRequest) -> CommandCodeUsageServiceStubResponse
    ) {
        lock.lock()
        self.responseProvider = responseProvider
        recordedRequests = []
        lock.unlock()
    }

    func reset() {
        lock.lock()
        responseProvider = nil
        recordedRequests = []
        lock.unlock()
    }

    func response(for request: URLRequest) -> CommandCodeUsageServiceStubResponse? {
        lock.lock()
        recordedRequests.append(request)
        let responseProvider = responseProvider
        lock.unlock()
        return responseProvider?(request)
    }
}

private final class CommandCodeUsageServiceTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var date: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}
