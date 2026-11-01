import Foundation
import XCTest
@testable import UsageBar

final class CursorUsageServiceTests: XCTestCase {
    private let baseURL = URL(string: "https://cursor.test/aiserver.v1.DashboardService/")!
    private let legacyPeriod = #"{"planUsage":{"autoPercentUsed":12,"apiPercentUsed":3},"enabled":true}"#
    private let legacySand = #"{"usagePercent":20,"hasNonZeroIncludedLimit":true}"#
    private let unifiedSand = #"{"usagePercent":37.5,"isUnified":true,"cursorPlanName":"Ultra","nextResetTimestampUtc":"2026-11-04T09:00:00Z"}"#
    private let weeklyPlan = #"{"planInfo":{"includedUsagePeriod":"INCLUDED_USAGE_PERIOD_WEEKLY","includedUsageResetsAt":"1893952000000"}}"#

    override func tearDown() {
        CursorStubURLProtocol.reset()
        super.tearDown()
    }

    func testUnifiedAccountSkipsPlanInfo() async throws {
        let service = makeService(responses: [
            "GetCurrentPeriodUsage": .ok(legacyPeriod),
            "GetSandUsageStatus": .ok(unifiedSand),
        ])

        let snapshot = try await service.fetchUsage()

        XCTAssertEqual(snapshot.sand?.isUnified, true)
        XCTAssertNil(snapshot.planInfo)
        XCTAssertEqual(CursorStubURLProtocol.count(for: "GetPlanInfo"), 0)
    }

    func testLegacyAccountReadsPlanInfoOnceWhileCached() async throws {
        let service = makeService(responses: [
            "GetCurrentPeriodUsage": .ok(legacyPeriod),
            "GetSandUsageStatus": .ok(legacySand),
            "GetPlanInfo": .ok(weeklyPlan),
        ])

        let first = try await service.fetchUsage()
        let second = try await service.fetchUsage()

        XCTAssertEqual(first.planInfo?.weeklyResetAt, Date(timeIntervalSince1970: 1_893_952_000))
        XCTAssertNotNil(second.planInfo)
        XCTAssertEqual(CursorStubURLProtocol.count(for: "GetPlanInfo"), 1)
        XCTAssertEqual(CursorStubURLProtocol.count(for: "GetSandUsageStatus"), 2)
    }

    func testPlanInfoFailureFallsBackToBillingCycle() async throws {
        let service = makeService(responses: [
            "GetCurrentPeriodUsage": .ok(legacyPeriod),
            "GetSandUsageStatus": .ok(legacySand),
            "GetPlanInfo": .status(500),
        ])

        let snapshot = try await service.fetchUsage()

        XCTAssertNil(snapshot.planInfo)
        XCTAssertEqual(snapshot.period.planUsage?.modelsPercentUsed, 12)
    }

    func testMissingSandEndpointLeavesLegacyPools() async throws {
        let service = makeService(responses: [
            "GetCurrentPeriodUsage": .ok(legacyPeriod),
            "GetSandUsageStatus": .status(404),
            "GetPlanInfo": .ok("{}"),
        ])

        let snapshot = try await service.fetchUsage()

        XCTAssertNil(snapshot.sand)
        XCTAssertEqual(CursorLimits.layout(for: snapshot).buckets.map(\.kind), [.cursorModels, .otherModels])
    }

    func testSandClientErrorKeepsLegacyPools() async throws {
        let service = makeService(responses: [
            "GetCurrentPeriodUsage": .ok(legacyPeriod),
            "GetSandUsageStatus": .status(403),
            "GetPlanInfo": .ok("{}"),
        ])

        let snapshot = try await service.fetchUsage()

        XCTAssertNil(snapshot.sand)
        XCTAssertEqual(CursorLimits.layout(for: snapshot).buckets.map(\.kind), [.cursorModels, .otherModels])
    }

    func testSandServerErrorFailsTheFetchInsteadOfShowingTheWrongLayout() async {
        let service = makeService(responses: [
            "GetCurrentPeriodUsage": .ok(legacyPeriod),
            "GetSandUsageStatus": .status(503),
        ])

        do {
            _ = try await service.fetchUsage()
            XCTFail("Expected the Sand failure")
        } catch CursorUsageError.httpStatus(let code) {
            XCTAssertEqual(code, 503)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testThrottleKeepsTheServerRetryDate() async {
        let service = makeService(responses: [
            "GetCurrentPeriodUsage": .status(429, headers: ["Retry-After": "120"]),
            "GetSandUsageStatus": .ok(unifiedSand),
        ])

        do {
            _ = try await service.fetchUsage()
            XCTFail("Expected a throttle")
        } catch CursorUsageError.throttled(let retryAfter) {
            XCTAssertNotNil(retryAfter)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testRejectedTokenReportsExpiredSignIn() async {
        let service = makeService(responses: [
            "GetCurrentPeriodUsage": .status(401),
            "GetSandUsageStatus": .status(401),
        ])

        do {
            _ = try await service.fetchUsage()
            XCTFail("Expected an expired sign-in")
        } catch CursorUsageError.tokenExpired {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testRequestsUseBearerTokenAndConnectHeadersOnDashboardMethodsOnly() async throws {
        let service = makeService(responses: [
            "GetCurrentPeriodUsage": .ok(legacyPeriod),
            "GetSandUsageStatus": .ok(legacySand),
            "GetPlanInfo": .ok(weeklyPlan),
        ])

        _ = try await service.fetchUsage()

        let requests = CursorStubURLProtocol.requests
        XCTAssertEqual(Set(requests.map(\.method)), ["GetCurrentPeriodUsage", "GetSandUsageStatus", "GetPlanInfo"])
        for request in requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.authorization, "Bearer test-token")
            XCTAssertEqual(request.connectVersion, "1")
            XCTAssertEqual(request.host, "cursor.test")
        }
    }

    func testMissingCredentialsSendNoRequest() async {
        let service = makeService(responses: [:], credentials: .stub(editor: nil, settings: nil))

        do {
            _ = try await service.fetchUsage()
            XCTFail("Expected not signed in")
        } catch CursorUsageError.notSignedIn {
            XCTAssertTrue(CursorStubURLProtocol.requests.isEmpty)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    private func makeService(
        responses: [String: CursorStubResponse],
        credentials: CursorCredentialLoader = .stub(editor: "test-token", settings: nil)
    ) -> CursorUsageService {
        CursorStubURLProtocol.configure(responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CursorStubURLProtocol.self]
        return CursorUsageService(
            baseURL: baseURL,
            session: URLSession(configuration: configuration),
            credentials: credentials
        )
    }
}

extension CursorCredentialLoader {
    static func stub(
        editor: String?,
        settings: String?,
        password: String? = nil,
        membership: String? = "pro",
        now: Date = Date(timeIntervalSince1970: 1_793_000_000)
    ) -> CursorCredentialLoader {
        CursorCredentialLoader(
            editorLogin: { editor.map { CursorEditorLogin(accessToken: $0, membershipType: membership) } },
            safeStoragePassword: { password },
            settingsToken: { settings },
            now: { now }
        )
    }
}

struct CursorStubResponse {
    let status: Int
    let body: Data
    let headers: [String: String]

    static func ok(_ json: String) -> CursorStubResponse {
        CursorStubResponse(status: 200, body: Data(json.utf8), headers: [:])
    }

    static func status(_ code: Int, headers: [String: String] = [:]) -> CursorStubResponse {
        CursorStubResponse(status: code, body: Data(), headers: headers)
    }
}

struct CursorRecordedRequest {
    let method: String
    let httpMethod: String?
    let authorization: String?
    let connectVersion: String?
    let host: String?
}

final class CursorStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [String: CursorStubResponse] = [:]
    private static var recorded: [CursorRecordedRequest] = []

    static func configure(_ values: [String: CursorStubResponse]) {
        lock.lock()
        responses = values
        recorded = []
        lock.unlock()
    }

    static func reset() {
        configure([:])
    }

    static var requests: [CursorRecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func count(for method: String) -> Int {
        requests.filter { $0.method == method }.count
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let method = url.lastPathComponent
        Self.lock.lock()
        Self.recorded.append(
            CursorRecordedRequest(
                method: method,
                httpMethod: request.httpMethod,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                connectVersion: request.value(forHTTPHeaderField: "Connect-Protocol-Version"),
                host: url.host
            )
        )
        let stub = Self.responses[method]
        Self.lock.unlock()
        guard let stub,
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
