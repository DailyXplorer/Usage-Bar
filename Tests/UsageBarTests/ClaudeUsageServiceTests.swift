import Foundation
import XCTest
@testable import UsageBar

final class ClaudeUsageServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_500_000)
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "ClaudeUsageServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        ClaudeStubProtocol.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        ClaudeStubProtocol.reset()
    }

    func testUsageRequestMatchesClaudeCode() async throws {
        ClaudeStubProtocol.respond(json: ClaudeFixtures.withoutSession)
        ClaudeStubProtocol.respond(json: #"{"organization":{"plan_display_name":"Ultra"}}"#)

        let fetch = try await service().fetchUsage(ownDataDate: nil)

        let request = try XCTUnwrap(ClaudeStubProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"),
            "claude-cli/\(ClaudeRequests.claudeCodeVersion) (external, cli)"
        )
        XCTAssertEqual(fetch.source, .usageEndpoint)
        XCTAssertEqual(fetch.plan, "Ultra")
        XCTAssertEqual(fetch.dataDate, now)
    }

    func testProfileRequestMatchesClaudeCodeAndIsCachedForADay() async throws {
        ClaudeStubProtocol.respond(json: ClaudeFixtures.withSession)
        ClaudeStubProtocol.respond(json: #"{"organization":{"plan_display_name":"Ultra"}}"#)
        ClaudeStubProtocol.respond(json: ClaudeFixtures.withSession)

        _ = try await service().fetchUsage(ownDataDate: nil)
        let second = try await service(now: now.addingTimeInterval(23 * 3600)).fetchUsage(ownDataDate: nil)

        let profile = ClaudeStubProtocol.requests[1]
        XCTAssertEqual(profile.url?.path, "/api/oauth/profile")
        XCTAssertEqual(profile.value(forHTTPHeaderField: "User-Agent"), "claude-code/\(ClaudeRequests.claudeCodeVersion)")
        XCTAssertEqual(profile.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
        XCTAssertNil(profile.value(forHTTPHeaderField: "anthropic-beta"))
        XCTAssertEqual(ClaudeStubProtocol.requests.count, 3)
        XCTAssertEqual(second.plan, "Ultra")
    }

    func testPlanFallsBackToTheCredentialWhenTheProfileFails() async throws {
        ClaudeStubProtocol.respond(json: ClaudeFixtures.withSession)
        ClaudeStubProtocol.respond(status: 500, json: "{}")

        let fetch = try await service().fetchUsage(ownDataDate: nil)

        XCTAssertEqual(fetch.plan, "max_20x")
    }

    func testRecentClaudeCodeCopyForTheSameAccountAvoidsTheNetworkAndTheSignIn() async throws {
        try writeClaudeCodeState(account: "account-1", cacheAccount: "account-1", fetchedAt: now.addingTimeInterval(-600))
        let reads = Counter()

        let fetch = try await service(reads: reads).fetchUsage(ownDataDate: now.addingTimeInterval(-1_200))

        XCTAssertTrue(ClaudeStubProtocol.requests.isEmpty)
        let readCount = await reads.value
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(fetch.source, .claudeCode)
        XCTAssertEqual(fetch.dataDate, now.addingTimeInterval(-600))
        XCTAssertEqual(fetch.accountKey, ClaudeAccountKey.make("account-1"))
        XCTAssertNil(fetch.plan)
        XCTAssertEqual(fetch.usage.map { ClaudeLimits.buckets(from: $0, now: now).map(\.kind) }, [.weeklyAll, .weeklyScoped, .spendLimit])
    }

    func testClaudeCodeCopyKeepsTheStoredProfilePlanAfterADay() async throws {
        try writeClaudeCodeState(account: "account-1", cacheAccount: "account-1", fetchedAt: now.addingTimeInterval(-600))
        ClaudeProfilePlanCache(
            accountKey: ClaudeAccountKey.make("account-1"),
            planName: "Ultra",
            checkedAt: now.addingTimeInterval(-3 * 24 * 3600)
        ).save(to: defaults)
        let reads = Counter()

        let fetch = try await service(reads: reads).fetchUsage(ownDataDate: nil)

        XCTAssertTrue(ClaudeStubProtocol.requests.isEmpty)
        let readCount = await reads.value
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(fetch.plan, "Ultra")
    }

    func testClaudeCodeCopyIsIgnoredWhenOldForeignOrOlderThanOurs() async throws {
        let cases: [(cacheAccount: String, age: TimeInterval, ownAge: TimeInterval?)] = [
            ("account-1", 3_700, nil),
            ("account-2", 60, nil),
            ("account-1", 600, 300),
        ]
        for testCase in cases {
            ClaudeStubProtocol.reset()
            ClaudeStubProtocol.respond(json: ClaudeFixtures.withSession)
            ClaudeStubProtocol.respond(json: #"{"organization":{"plan_display_name":"Max"}}"#)
            try writeClaudeCodeState(
                account: "account-1",
                cacheAccount: testCase.cacheAccount,
                fetchedAt: now.addingTimeInterval(-testCase.age)
            )

            let fetch = try await service().fetchUsage(ownDataDate: testCase.ownAge.map { now.addingTimeInterval(-$0) })

            XCTAssertEqual(fetch.source, .usageEndpoint, "\(testCase)")
            XCTAssertEqual(ClaudeStubProtocol.requests.first?.url?.path, "/api/oauth/usage")
        }
    }

    func testRejectedTokenIsRenewedOnceAndRetried() async throws {
        ClaudeStubProtocol.respond(status: 401, json: "{}")
        ClaudeStubProtocol.respond(json: ClaudeFixtures.withSession)
        ClaudeStubProtocol.respond(json: "{}")
        let renewals = Counter()

        _ = try await service(renewals: renewals).fetchUsage(ownDataDate: nil)

        let tokens = ClaudeStubProtocol.requests.prefix(2).map { $0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(tokens, ["Bearer token-1", "Bearer token-2"])
        let renewalCount = await renewals.value
        XCTAssertEqual(renewalCount, 1)
    }

    func testSecondRejectionMeansTheSignInExpired() async throws {
        ClaudeStubProtocol.respond(status: 401, json: "{}")
        ClaudeStubProtocol.respond(status: 401, json: "{}")

        await assertThrows(try await service().fetchUsage(ownDataDate: nil)) {
            guard case ClaudeUsageError.tokenExpired = $0 else { return false }
            return true
        }
        XCTAssertEqual(ClaudeStubProtocol.requests.count, 2)
    }

    func testStatusCodesMapToPlainErrors() async throws {
        let cases: [(Int, [String: String], (Error) -> Bool)] = [
            (429, ["Retry-After": "120"], {
                guard case ClaudeUsageError.throttled(let date) = $0 else { return false }
                return date != nil
            }),
            (403, [:], { if case ClaudeUsageError.forbidden = $0 { return true }; return false }),
            (503, [:], { if case ClaudeUsageError.server = $0 { return true }; return false }),
        ]
        for (status, headers, matches) in cases {
            ClaudeStubProtocol.reset()
            ClaudeStubProtocol.respond(status: status, json: "{}", headers: headers)
            await assertThrows(try await service().fetchUsage(ownDataDate: nil), matches)
        }
        for error in [ClaudeUsageError.forbidden, .server, .network, .decoding, .throttled(retryAfter: nil)] {
            let text = error.localizedDescription
            XCTAssertNil(text.range(of: #"\d{3}"#, options: .regularExpression), text)
            XCTAssertFalse(text.contains("http"), text)
        }
    }

    func testWhilePausedNothingIsSentUnlessTheQuotaCheckIsOn() async throws {
        let fetch = try await service().fetchWhilePaused(ownDataDate: nil, quotaCheck: false, scopedModelName: nil)

        XCTAssertNil(fetch.usage)
        XCTAssertTrue(ClaudeStubProtocol.requests.isEmpty)
    }

    func testQuotaCheckSendsClaudeCodesOneTokenRequestAndReadsHeaders() async throws {
        var headers: [String: String] = [:]
        for case let (key as String, value as String) in ClaudeFixtures.unifiedHeaders {
            headers[key] = value
        }
        ClaudeStubProtocol.respond(status: 429, json: "{}", headers: headers)

        let fetch = try await service().fetchWhilePaused(ownDataDate: nil, quotaCheck: true, scopedModelName: "Fable")

        let request = try XCTUnwrap(ClaudeStubProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-app"), "cli")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: ClaudeStubProtocol.bodies.first ?? Data()) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-haiku-4-5-20251001")
        XCTAssertEqual(body["max_tokens"] as? Int, 1)
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "quota")
        XCTAssertEqual(fetch.source, .quotaCheck)
        XCTAssertEqual(fetch.usage.map { ClaudeLimits.buckets(from: $0, now: now).map(\.usedPercent) }, [32, 6])
    }

    func testProviderSessionNeverUsesACache() {
        let configuration = ProviderSession.configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertNil(configuration.httpCookieStorage)
    }

    private func service(now date: Date? = nil, renewals: Counter = Counter(), reads: Counter = Counter()) -> ClaudeUsageService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeStubProtocol.self]
        let fixed = date ?? now
        return ClaudeUsageService(
            credentials: ClaudeCredentialProvider(
                usable: {
                    await reads.increment()
                    return Self.credentials("token-1")
                },
                afterRejection: { _ in
                    await renewals.increment()
                    return Self.credentials("token-2")
                }
            ),
            session: URLSession(configuration: configuration),
            claudeCodeFile: directory.appendingPathComponent(".claude.json"),
            defaults: defaults,
            now: { fixed }
        )
    }

    private static func credentials(_ token: String) -> ClaudeCredentials {
        ClaudeCredentials(
            accessToken: token,
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x",
            expiresAt: nil,
            refreshToken: "refresh"
        )
    }

    private func writeClaudeCodeState(account: String, cacheAccount: String, fetchedAt: Date) throws {
        let usage = try JSONSerialization.jsonObject(with: Data(ClaudeFixtures.withoutSession.utf8))
        let root: [String: Any] = [
            "oauthAccount": ["accountUuid": account],
            "cachedUsageUtilization": [
                "fetchedAtMs": fetchedAt.timeIntervalSince1970 * 1000,
                "accountUuid": cacheAccount,
                "utilization": usage,
            ],
        ]
        try JSONSerialization.data(withJSONObject: root).write(to: directory.appendingPathComponent(".claude.json"))
    }

    private func assertThrows<T>(
        _ expression: @autoclosure () async throws -> T,
        _ matches: (Error) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected an error", file: file, line: line)
        } catch {
            XCTAssertTrue(matches(error), "\(error)", file: file, line: line)
        }
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

final class ClaudeStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queued: [(status: Int, body: Data, headers: [String: String])] = []
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var recordedBodies: [Data] = []

    static var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    static var bodies: [Data] {
        lock.withLock { recordedBodies }
    }

    static func reset() {
        lock.withLock {
            queued = []
            recorded = []
            recordedBodies = []
        }
    }

    static func respond(status: Int = 200, json: String, headers: [String: String] = [:]) {
        lock.withLock { queued.append((status, Data(json.utf8), headers)) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let next: (status: Int, body: Data, headers: [String: String])? = Self.lock.withLock {
            Self.recorded.append(request)
            Self.recordedBodies.append(body)
            return Self.queued.isEmpty ? nil : Self.queued.removeFirst()
        }
        guard let next, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
