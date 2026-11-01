import XCTest
@testable import UsageBar

final class UsageServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_990_000)
    private let endpoint = URL(string: "https://codex-usage.test/backend-api/wham/usage")!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CodexStubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        CodexStubURLProtocol.reset()
    }

    func testAuthFileHonoursCodexHome() {
        let home = URL(fileURLWithPath: "/tmp/home-x", isDirectory: true)

        XCTAssertEqual(
            UsageService.authFile(environment: ["CODEX_HOME": "/tmp/codex-x"], home: home).path,
            "/tmp/codex-x/auth.json"
        )
        XCTAssertEqual(
            UsageService.authFile(environment: ["CODEX_HOME": "  "], home: home).path,
            "/tmp/home-x/.codex/auth.json"
        )
        XCTAssertEqual(
            UsageService.authFile(environment: [:], home: home).path,
            "/tmp/home-x/.codex/auth.json"
        )
    }

    func testMissingFileAsksToSignIn() {
        XCTAssertThrowsError(
            try UsageService.loadCredentials(from: directory.appendingPathComponent("auth.json"), now: now)
        ) { error in
            guard case UsageError.missingAuthFile = error else {
                return XCTFail("Expected missingAuthFile, got \(error)")
            }
        }
    }

    func testFileWithoutChatGPTTokensAsksToSignIn() throws {
        let file = try writeAuth(#"{"OPENAI_API_KEY":"sk-test","tokens":null}"#)

        XCTAssertThrowsError(try UsageService.loadCredentials(from: file, now: now)) { error in
            guard case UsageError.missingTokens = error else {
                return XCTFail("Expected missingTokens, got \(error)")
            }
        }
    }

    func testExpiredTokenIsReportedWithoutCallingTheServer() async throws {
        let file = try writeAuth(token: jwt(exp: now.timeIntervalSince1970 - 1))
        CodexStubURLProtocol.respond(status: 200, body: CodexFixtures.plus)

        do {
            _ = try await makeService(authFile: file).fetchUsage()
            XCTFail("Expected an expired sign-in")
        } catch UsageError.signInExpired {
            XCTAssertEqual(
                UsageError.signInExpired.localizedDescription,
                "Codex sign-in expired. Open Codex to renew it."
            )
        }
        XCTAssertEqual(CodexStubURLProtocol.requests.count, 0)
    }

    func testTokenExpiryReadsBase64URLPayload() {
        let exp = 1_793_000_123.0
        XCTAssertEqual(UsageService.tokenExpiry(jwt(exp: exp)), Date(timeIntervalSince1970: exp))
        XCTAssertEqual(
            UsageService.tokenExpiry(jwt(payload: #"{"exp":"1793000123","sub":"???>>>"}"#)),
            Date(timeIntervalSince1970: exp)
        )
        XCTAssertNil(UsageService.tokenExpiry("not-a-jwt"))
        XCTAssertNil(UsageService.tokenExpiry("a.%%%.c"))
        XCTAssertNil(UsageService.tokenExpiry(jwt(payload: #"{"sub":"x"}"#)))
        XCTAssertNil(UsageService.tokenExpiry(jwt(payload: #"{"exp":1e300}"#)))
    }

    func testValidTokenSendsTheCodexRequestOnly() async throws {
        let file = try writeAuth(token: jwt(exp: now.timeIntervalSince1970 + 3_600))
        CodexStubURLProtocol.respond(status: 200, body: CodexFixtures.proAtLimit)

        let usage = try await makeService(authFile: file).fetchUsage()

        XCTAssertEqual(usage.rateLimitReachedType, "rate_limit_reached")
        let request = try XCTUnwrap(CodexStubURLProtocol.requests.first)
        XCTAssertEqual(CodexStubURLProtocol.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-x")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "codex-cli")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        XCTAssertNil(request.value(forHTTPHeaderField: "x-openai-codex-luna-reserve"))
    }

    func testTokenWithoutReadableExpiryIsStillUsed() async throws {
        let file = try writeAuth(token: "opaque-token")
        CodexStubURLProtocol.respond(status: 200, body: CodexFixtures.freeObserved)

        let usage = try await makeService(authFile: file).fetchUsage()

        XCTAssertEqual(usage.planType, "free")
    }

    func testUnauthorizedResponseMeansExpiredSignIn() async throws {
        try await assertFetch(status: 401, throws: "Codex sign-in expired. Open Codex to renew it.")
    }

    func testServerErrorDoesNotAskToSignInAgain() async throws {
        for status in [500, 502, 503] {
            try await assertFetch(status: status, throws: UsageError.server.localizedDescription)
        }
        XCTAssertFalse(UsageError.server.localizedDescription.localizedCaseInsensitiveContains("sign"))
    }

    func testThrottledResponseKeepsRetryAfter() async throws {
        let file = try writeAuth(token: jwt(exp: now.timeIntervalSince1970 + 3_600))
        CodexStubURLProtocol.respond(status: 429, body: "", headers: ["Retry-After": "120"])

        do {
            _ = try await makeService(authFile: file).fetchUsage()
            XCTFail("Expected throttling")
        } catch UsageError.throttled(let retryAfter) {
            XCTAssertEqual(retryAfter, now.addingTimeInterval(120))
        }
    }

    func testUnreadableBodyAsksForAnUpdate() async throws {
        try await assertFetch(
            status: 200,
            body: "<html>",
            throws: "Codex sent usage data in an unknown format. Check for a Usage Bar update."
        )
    }

    func testErrorTextsAreShortPlainSentences() {
        let errors: [UsageError] = [
            .missingAuthFile, .missingTokens, .signInExpired, .forbidden,
            .network("The Internet connection appears to be offline. NSURLErrorDomain -1009"),
            .throttled(retryAfter: nil), .server, .httpStatus(418),
            .decoding("The data couldn’t be read because it isn’t in the correct format."),
        ]
        for error in errors {
            let text = error.localizedDescription
            XCTAssertTrue(text.hasSuffix("."), text)
            for banned in ["HTTP", "http", "auth.json", "418", "NSURL", "couldn’t", "codex login"] {
                XCTAssertFalse(text.contains(banned), "\(text) contains \(banned)")
            }
        }
        XCTAssertEqual(UsageError.missingAuthFile.localizedDescription, "No Codex sign-in found. Open Codex and sign in.")
        XCTAssertEqual(
            UsageError.network("offline").localizedDescription,
            "Could not reach ChatGPT. Check your internet connection."
        )
    }

    private func assertFetch(
        status: Int,
        body: String = "",
        throws expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let authFile = try writeAuth(token: jwt(exp: now.timeIntervalSince1970 + 3_600))
        CodexStubURLProtocol.respond(status: status, body: body)
        do {
            _ = try await makeService(authFile: authFile).fetchUsage()
            XCTFail("Expected an error for \(status)", file: file, line: line)
        } catch {
            XCTAssertEqual(error.localizedDescription, expected, file: file, line: line)
        }
    }

    private func makeService(authFile: URL) -> UsageService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexStubURLProtocol.self]
        let fixedNow = now
        return UsageService(
            endpoint: endpoint,
            session: URLSession(configuration: configuration),
            authFile: authFile,
            now: { fixedNow }
        )
    }

    private func writeAuth(token: String) throws -> URL {
        try writeAuth(#"{"tokens":{"access_token":"\#(token)","account_id":"account-x"}}"#)
    }

    private func writeAuth(_ json: String) throws -> URL {
        let file = directory.appendingPathComponent("auth.json")
        try Data(json.utf8).write(to: file)
        return file
    }

    private func jwt(exp: Double) -> String {
        jwt(payload: #"{"exp":\#(Int(exp)),"sub":"user-x"}"#)
    }

    private func jwt(payload: String) -> String {
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(encoded).signature"
    }
}

private final class CodexStubURLProtocol: URLProtocol {
    private struct Stub {
        let status: Int
        let body: Data
        let headers: [String: String]
    }

    private static let lock = NSLock()
    private static var stub: Stub?
    private static var recorded: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func respond(status: Int, body: String, headers: [String: String] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        stub = Stub(status: status, body: Data(body.utf8), headers: headers)
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        stub = nil
        recorded = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let stub = Self.stub
        Self.lock.unlock()
        guard let stub, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
