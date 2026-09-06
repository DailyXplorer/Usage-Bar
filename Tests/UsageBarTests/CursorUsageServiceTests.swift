import Foundation
import XCTest
@testable import UsageBar

final class CursorUsageServiceTests: XCTestCase {
    private let periodURL = URL(string: "https://cursor.test/period")!
    private let sandURL = URL(string: "https://cursor.test/sand")!

    override func tearDown() {
        CursorStubURLProtocol.responses = [:]
        CursorStubURLProtocol.requestedPaths = []
        super.tearDown()
    }

    func testSandThrottleIsReportedWithoutFailingPeriodUsage() async throws {
        let service = makeService(sand: .status(429))
        async let period = service.fetchPeriodUsage(credentials: credentials)
        async let grok = service.fetchGrokBotUsage(credentials: credentials)
        let periodResult = try await period
        let grokResult = try await grok
        let usage = periodResult.0
        let grokBot = grokResult.0

        XCTAssertEqual(usage.planUsage?.modelsPercentUsed, 12)
        guard case .throttled = grokBot else {
            return XCTFail("Expected the Sand throttle to remain visible to the caller")
        }
    }

    func testSandThrottleIsReportedWhenPeriodAlsoFails() async throws {
        let service = makeService(period: .status(500), sand: .status(429))
        async let period = service.fetchPeriodUsage(credentials: credentials)
        async let grok = service.fetchGrokBotUsage(credentials: credentials)

        do {
            _ = try await period
            XCTFail("Expected the period failure")
        } catch CursorUsageError.httpStatus(let code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Expected the period HTTP failure, got \(error)")
        }
        let grokResult = try await grok
        let grokBot = grokResult.0
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
            let service = makeService(sand: response)
            async let period = service.fetchPeriodUsage(credentials: credentials)
            async let grok = service.fetchGrokBotUsage(credentials: credentials)
            let periodResult = try await period
            let grokResult = try await grok
            let usage = periodResult.0
            let grokBot = grokResult.0

            XCTAssertEqual(usage.planUsage?.modelsPercentUsed, 12)
            guard case .unavailable = grokBot else {
                return XCTFail("Expected the failed Sand refresh to preserve cached usage")
            }
        }
    }

    func testValidSandResponseIsDistinguishedFromFailure() async throws {
        let service = makeService(sand: .ok("{}"))
        let (grokBot, _) = try await service.fetchGrokBotUsage(credentials: credentials)

        guard case .refreshed(let status) = grokBot else {
            return XCTFail("Expected a decoded Sand response")
        }
        XCTAssertNotNil(status)
    }

    func testSandFetchCanRunWithoutPeriodUsage() async throws {
        let service = makeService(period: .status(500), sand: .ok("{}"))
        let (grokBot, _) = try await service.fetchGrokBotUsage(credentials: credentials)

        guard case .refreshed = grokBot else {
            return XCTFail("Expected Sand to refresh while period usage is blocked")
        }
        XCTAssertEqual(CursorStubURLProtocol.requestedPaths, [sandURL.path])
    }

    func testPeriodUsageCompletesBeforeDelayedSand() async throws {
        let sandStarted = expectation(description: "Sand request started")
        let delay = CursorStubDelay(onHold: sandStarted.fulfill)
        defer { delay.release() }
        let service = makeService(sand: .delayedOK("{}", delay: delay))
        async let period = service.fetchPeriodUsage(credentials: credentials)
        async let grok = service.fetchGrokBotUsage(credentials: credentials)

        await fulfillment(of: [sandStarted], timeout: 1)
        let usage = try await period

        XCTAssertEqual(usage.0.planUsage?.modelsPercentUsed, 12)
        XCTAssertTrue(delay.isHoldingResponse)

        delay.release()
        let (grokBot, _) = try await grok
        guard case .refreshed = grokBot else {
            return XCTFail("Expected Sand to finish after its response was released")
        }
    }

    func testRetryAfterIsReturnedByEachIndependentEndpoint() async throws {
        let service = makeService(
            period: .status(429, headers: ["Retry-After": "120"]),
            sand: .status(429, headers: ["Retry-After": "120"])
        )
        let before = Date()

        do {
            _ = try await service.fetchPeriodUsage(credentials: credentials)
            XCTFail("Expected period usage to be rate limited")
        } catch CursorUsageError.throttled(let retryAfter) {
            let retryAfter = try XCTUnwrap(retryAfter)
            XCTAssertGreaterThanOrEqual(retryAfter.timeIntervalSince(before), 119)
        } catch {
            XCTFail("Expected a period throttle, got \(error)")
        }

        let (grokBot, _) = try await service.fetchGrokBotUsage(credentials: credentials)
        guard case .throttled(let retryAfter) = grokBot else {
            return XCTFail("Expected Sand usage to be rate limited")
        }
        let retryDate = try XCTUnwrap(retryAfter)
        XCTAssertGreaterThanOrEqual(retryDate.timeIntervalSince(before), 119)
    }

    private var credentials: CursorCredentials {
        CursorCredentials(accessToken: "test-token", membershipType: "pro")
    }

    private func makeService(
        period: CursorStubResponse? = nil,
        sand: CursorStubResponse
    ) -> CursorUsageService {
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
        return service
    }
}

private struct CursorStubResponse {
    let status: Int?
    let data: Data
    let error: URLError.Code?
    let delay: CursorStubDelay?
    let headers: [String: String]

    static func ok(_ json: String) -> CursorStubResponse {
        CursorStubResponse(status: 200, data: Data(json.utf8), error: nil, delay: nil, headers: [:])
    }

    static func delayedOK(_ json: String, delay: CursorStubDelay) -> CursorStubResponse {
        CursorStubResponse(status: 200, data: Data(json.utf8), error: nil, delay: delay, headers: [:])
    }

    static func status(_ code: Int, headers: [String: String] = [:]) -> CursorStubResponse {
        CursorStubResponse(status: code, data: Data(), error: nil, delay: nil, headers: headers)
    }

    static func failure(_ error: URLError.Code) -> CursorStubResponse {
        CursorStubResponse(status: nil, data: Data(), error: error, delay: nil, headers: [:])
    }
}

private final class CursorStubURLProtocol: URLProtocol {
    private static let store = CursorStubStore()

    static var responses: [String: CursorStubResponse] {
        get { store.value }
        set { store.value = newValue }
    }

    static var requestedPaths: [String] {
        get { store.requestedPaths }
        set { store.requestedPaths = newValue }
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
        Self.store.appendRequestedPath(url.path)
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
            headerFields: stub.headers
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
    private var requestedPathStorage: [String] = []

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

    var requestedPaths: [String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return requestedPathStorage
        }
        set {
            lock.lock()
            requestedPathStorage = newValue
            lock.unlock()
        }
    }

    func appendRequestedPath(_ path: String) {
        lock.lock()
        requestedPathStorage.append(path)
        lock.unlock()
    }
}
