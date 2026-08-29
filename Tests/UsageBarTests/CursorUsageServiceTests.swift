import Foundation
import XCTest
@testable import UsageBar

final class CursorUsageServiceTests: XCTestCase {
    private let periodURL = URL(string: "https://cursor.test/period")!
    private let sandURL = URL(string: "https://cursor.test/sand")!

    override func tearDown() {
        CursorStubURLProtocol.responses = [:]
        super.tearDown()
    }

    func testSandThrottleIsReportedWithoutFailingPeriodUsage() async throws {
        let requests = try await fetch(sand: .status(429))
        let usage = try await requests.period.value.get()
        let grokBot = await requests.grokBot.value

        XCTAssertEqual(usage.planUsage?.modelsPercentUsed, 12)
        guard case .throttled = grokBot else {
            return XCTFail("Expected the Sand throttle to remain visible to the caller")
        }
    }

    func testSandThrottleIsReportedWhenPeriodAlsoFails() async throws {
        let requests = try await fetch(period: .status(500), sand: .status(429))
        let usage = await requests.period.value
        let grokBot = await requests.grokBot.value

        guard case .failure(let error) = usage,
              case .httpStatus(let code) = error else {
            return XCTFail("Expected the period failure")
        }
        XCTAssertEqual(code, 500)
        guard case .throttled = grokBot else {
            return XCTFail("Expected the concurrent Sand throttle")
        }
    }

    func testSandFailuresAreReportedWithoutFailingPeriodUsage() async throws {
        for response in [
            CursorStubResponse.status(500),
            CursorStubResponse.ok("not-json"),
            CursorStubResponse.failure(.timedOut),
        ] {
            let requests = try await fetch(sand: response)
            let usage = try await requests.period.value.get()
            let grokBot = await requests.grokBot.value

            XCTAssertEqual(usage.planUsage?.modelsPercentUsed, 12)
            guard case .unavailable = grokBot else {
                return XCTFail("Expected the failed Sand refresh to preserve cached usage")
            }
        }
    }

    func testValidSandResponseIsDistinguishedFromFailure() async throws {
        let requests = try await fetch(sand: .ok("{}"))
        let grokBot = await requests.grokBot.value

        guard case .refreshed(let status) = grokBot else {
            return XCTFail("Expected a decoded Sand response")
        }
        XCTAssertNotNil(status)
    }

    func testDisabledSandFetchDoesNotSurfaceItsThrottle() async throws {
        let requests = try await fetch(sand: .status(429), includeGrokBot: false)
        let grokBot = await requests.grokBot.value

        guard case .unavailable = grokBot else {
            return XCTFail("Expected a blocked Sand refresh to preserve cached usage")
        }
    }

    func testPeriodUsageCompletesBeforeDelayedSand() async throws {
        let sandStarted = expectation(description: "Sand request started")
        let delay = CursorStubDelay(onHold: sandStarted.fulfill)
        defer { delay.release() }
        let requests = try await fetch(sand: .delayedOK("{}", delay: delay))

        await fulfillment(of: [sandStarted], timeout: 1)
        let usage = try await requests.period.value.get()

        XCTAssertEqual(usage.planUsage?.modelsPercentUsed, 12)
        XCTAssertTrue(delay.isHoldingResponse)

        delay.release()
        guard case .refreshed = await requests.grokBot.value else {
            return XCTFail("Expected Sand to finish after its response was released")
        }
    }

    func testSandBackoffWidensUntilAValidRefreshResetsIt() {
        let now = Date(timeIntervalSince1970: 1_786_400_000)
        var backoff = CursorGrokBotBackoff()

        backoff.update(after: .throttled, now: now)
        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(5 * 60))

        backoff.update(after: .unavailable, now: now)
        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(5 * 60))

        backoff.update(after: .throttled, now: now)
        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(15 * 60))

        backoff.update(after: .throttled, now: now)
        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(30 * 60))

        backoff.update(after: .throttled, now: now)
        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(60 * 60))

        backoff.update(after: .throttled, now: now)
        XCTAssertEqual(backoff.blockedUntil, now.addingTimeInterval(60 * 60))

        backoff.update(after: .refreshed(nil), now: now)
        XCTAssertNil(backoff.blockedUntil)
    }

    private func fetch(
        period: CursorStubResponse? = nil,
        sand: CursorStubResponse,
        includeGrokBot: Bool = true
    ) async throws -> CursorUsageRequests {
        CursorStubURLProtocol.responses = [
            periodURL.path: period ?? .ok("""
                {"planUsage":{"autoPercentUsed":12,"apiPercentUsed":3},"enabled":true}
                """),
            sandURL.path: sand,
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CursorStubURLProtocol.self]
        let service = CursorUsageService(
            endpoint: periodURL,
            grokBotEndpoint: sandURL,
            session: URLSession(configuration: configuration)
        )
        return await service.startFetch(
            credentials: CursorCredentials(accessToken: "test-token", membershipType: "pro"),
            includeGrokBot: includeGrokBot
        )
    }
}

private struct CursorStubResponse {
    let status: Int?
    let data: Data
    let error: URLError.Code?
    let delay: CursorStubDelay?

    static func ok(_ json: String) -> CursorStubResponse {
        CursorStubResponse(status: 200, data: Data(json.utf8), error: nil, delay: nil)
    }

    static func delayedOK(_ json: String, delay: CursorStubDelay) -> CursorStubResponse {
        CursorStubResponse(status: 200, data: Data(json.utf8), error: nil, delay: delay)
    }

    static func status(_ code: Int) -> CursorStubResponse {
        CursorStubResponse(status: code, data: Data(), error: nil, delay: nil)
    }

    static func failure(_ error: URLError.Code) -> CursorStubResponse {
        CursorStubResponse(status: nil, data: Data(), error: error, delay: nil)
    }
}

private final class CursorStubURLProtocol: URLProtocol {
    private static let store = CursorStubStore()

    static var responses: [String: CursorStubResponse] {
        get { store.value }
        set { store.value = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let stub = Self.responses[url.path] else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: URLError(error))
            return
        }
        if let delay = stub.delay {
            delay.hold { [self] in finishLoading(url: url, stub: stub) }
            return
        }
        finishLoading(url: url, stub: stub)
    }

    private func finishLoading(url: URL, stub: CursorStubResponse) {
        guard let status = stub.status,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CursorStubDelay: @unchecked Sendable {
    private let lock = NSLock()
    private let onHold: () -> Void
    private var completion: (() -> Void)?
    private var isReleased = false

    init(onHold: @escaping () -> Void) {
        self.onHold = onHold
    }

    var isHoldingResponse: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completion != nil
    }

    func hold(_ completion: @escaping () -> Void) {
        lock.lock()
        if isReleased {
            lock.unlock()
            completion()
            return
        }
        self.completion = completion
        lock.unlock()
        onHold()
    }

    func release() {
        lock.lock()
        isReleased = true
        let completion = completion
        self.completion = nil
        lock.unlock()
        completion?()
    }
}

private final class CursorStubStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: CursorStubResponse] = [:]

    var value: [String: CursorStubResponse] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
