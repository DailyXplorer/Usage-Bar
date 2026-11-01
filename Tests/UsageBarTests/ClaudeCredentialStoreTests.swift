import XCTest
@testable import UsageBar

final class ClaudeCredentialStoreTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testValidCredentialsDoNotRefresh() async throws {
        let storage = MemoryCredentialStorage(keychain: blob(access: "access-1", refresh: "refresh-1", expiresIn: 3600))
        let endpoint = TokenEndpointStub()

        let credentials = try await makeStore(storage, endpoint).usableCredentials()

        XCTAssertEqual(credentials.accessToken, "access-1")
        XCTAssertEqual(endpoint.calls, 0)
    }

    func testRefreshWritesTheGrantIntoTheBlobReadAfterThePost() async throws {
        let storage = MemoryCredentialStorage(keychain: blob(access: "access-1", refresh: "refresh-1", expiresIn: -3600, mcp: "before"))
        let changed = blob(access: "access-1", refresh: "refresh-1", expiresIn: -3600, mcp: "changed during refresh")
        let endpoint = TokenEndpointStub { storage.set(changed, for: .keychain) }

        let credentials = try await makeStore(storage, endpoint).usableCredentials()

        XCTAssertEqual(credentials.accessToken, "access-2")
        let saved = try XCTUnwrap(storage.json(.keychain))
        let oauth = try XCTUnwrap(saved["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "access-2")
        XCTAssertEqual(oauth["refreshToken"] as? String, "refresh-2")
        XCTAssertEqual(oauth["expiresAt"] as? Int, 1_790_028_800_000)
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")
        XCTAssertEqual((saved["mcpOAuth"] as? [String: String])?["server"], "changed during refresh")
    }

    func testTokensWrittenByClaudeCodeDuringTheRefreshWin() async throws {
        let storage = MemoryCredentialStorage(keychain: blob(access: "access-1", refresh: "refresh-1", expiresIn: -3600))
        let newer = blob(access: "claude-code-access", refresh: "claude-code-refresh", expiresIn: 3600)
        let endpoint = TokenEndpointStub { storage.set(newer, for: .keychain) }

        let credentials = try await makeStore(storage, endpoint).usableCredentials()

        XCTAssertEqual(credentials.accessToken, "claude-code-access")
        XCTAssertEqual(storage.data(.keychain), newer)
        XCTAssertEqual(storage.writes, 0)
    }

    func testFailedVerificationReadKeepsTheRotatedGrant() async throws {
        let storage = MemoryCredentialStorage(keychain: blob(access: "access-1", refresh: "refresh-1", expiresIn: -3600))
        storage.failReadsAfterEachWrite = 5
        let endpoint = TokenEndpointStub()
        let store = makeStore(storage, endpoint)

        let first = try await store.usableCredentials()
        storage.failReadsAfterEachWrite = 0
        let second = try await store.usableCredentials()

        XCTAssertEqual(first.accessToken, "access-2")
        XCTAssertEqual(second.accessToken, "access-2")
        XCTAssertEqual(storage.credentials(.keychain)?["refreshToken"] as? String, "refresh-2")
        XCTAssertEqual(endpoint.calls, 1)
    }

    func testFailedSaveKeepsTheGrantInMemoryUntilASaveSucceeds() async throws {
        let original = blob(access: "access-1", refresh: "refresh-1", expiresIn: -3600)
        let storage = MemoryCredentialStorage(keychain: original)
        storage.writesFail = true
        let endpoint = TokenEndpointStub()
        let store = makeStore(storage, endpoint)

        let first = try await store.usableCredentials()
        let second = try await store.usableCredentials()

        XCTAssertEqual(first.accessToken, "access-2")
        XCTAssertEqual(second.accessToken, "access-2")
        XCTAssertEqual(storage.data(.keychain), original)
        XCTAssertEqual(endpoint.calls, 1)

        storage.writesFail = false
        let third = try await store.usableCredentials()

        XCTAssertEqual(third.accessToken, "access-2")
        XCTAssertEqual(storage.credentials(.keychain)?["accessToken"] as? String, "access-2")
        XCTAssertEqual(storage.credentials(.keychain)?["refreshToken"] as? String, "refresh-2")
        XCTAssertEqual(endpoint.calls, 1)
    }

    func testUnsavedGrantIsDroppedWhenClaudeCodeStoresANewCredential() async throws {
        let storage = MemoryCredentialStorage(keychain: blob(access: "access-1", refresh: "refresh-1", expiresIn: -3600))
        storage.writesFail = true
        let endpoint = TokenEndpointStub()
        let store = makeStore(storage, endpoint)
        _ = try await store.usableCredentials()

        storage.set(blob(access: "claude-code-access", refresh: "claude-code-refresh", expiresIn: 3600), for: .keychain)
        let credentials = try await store.usableCredentials()

        XCTAssertEqual(credentials.accessToken, "claude-code-access")
    }

    func testUnsavedGrantServesWhileTheKeychainCannotBeRead() async throws {
        let storage = MemoryCredentialStorage(keychain: blob(access: "access-1", refresh: "refresh-1", expiresIn: -3600))
        storage.writesFail = true
        let store = makeStore(storage, TokenEndpointStub())
        _ = try await store.usableCredentials()

        storage.readsFail = true
        let credentials = try await store.usableCredentials()

        XCTAssertEqual(credentials.accessToken, "access-2")
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        let storage = MemoryCredentialStorage(keychain: blob(access: "access-1", refresh: "refresh-1", expiresIn: -3600))
        let gate = Gate()
        let started = expectation(description: "refresh started")
        started.assertForOverFulfill = false
        let endpoint = TokenEndpointStub {
            started.fulfill()
            await gate.wait()
        }
        let store = makeStore(storage, endpoint)

        let callers = (0..<8).map { _ in Task { try await store.usableCredentials() } }
        await fulfillment(of: [started], timeout: 5)
        for _ in 0..<20 { await Task.yield() }
        await gate.open()

        for caller in callers {
            let credentials = try await caller.value
            XCTAssertEqual(credentials.accessToken, "access-2")
        }
        XCTAssertEqual(endpoint.calls, 1)
    }

    func testCancelledCallerDoesNotCancelTheWriteBack() async throws {
        let storage = MemoryCredentialStorage(keychain: blob(access: "access-1", refresh: "refresh-1", expiresIn: -3600))
        let gate = Gate()
        let started = expectation(description: "refresh started")
        let written = expectation(description: "grant written")
        written.assertForOverFulfill = false
        storage.onWrite = { written.fulfill() }
        let endpoint = TokenEndpointStub {
            started.fulfill()
            await gate.wait()
        }
        let store = makeStore(storage, endpoint)

        let caller = Task { try await store.usableCredentials() }
        await fulfillment(of: [started], timeout: 5)
        caller.cancel()
        await gate.open()
        await fulfillment(of: [written], timeout: 5)
        _ = try? await caller.value

        XCTAssertEqual(storage.credentials(.keychain)?["accessToken"] as? String, "access-2")
        XCTAssertEqual(storage.credentials(.keychain)?["refreshToken"] as? String, "refresh-2")
    }

    func testRejectedTokenRefreshesEvenBeforeItExpires() async throws {
        let storage = MemoryCredentialStorage(keychain: blob(access: "access-1", refresh: "refresh-1", expiresIn: 3600))
        let endpoint = TokenEndpointStub()
        let store = makeStore(storage, endpoint)
        let rejected = try await store.usableCredentials()

        let credentials = try await store.credentialsAfterRejection(of: rejected)

        XCTAssertEqual(credentials.accessToken, "access-2")
        XCTAssertEqual(endpoint.calls, 1)
        XCTAssertEqual(storage.credentials(.keychain)?["accessToken"] as? String, "access-2")
    }

    func testRejectionReturnsTheStoredTokenWhenItAlreadyChanged() async throws {
        let storage = MemoryCredentialStorage(keychain: blob(access: "access-1", refresh: "refresh-1", expiresIn: 3600))
        let endpoint = TokenEndpointStub()
        let store = makeStore(storage, endpoint)
        let rejected = try await store.usableCredentials()
        storage.set(blob(access: "claude-code-access", refresh: "claude-code-refresh", expiresIn: 3600), for: .keychain)

        let credentials = try await store.credentialsAfterRejection(of: rejected)

        XCTAssertEqual(credentials.accessToken, "claude-code-access")
        XCTAssertEqual(endpoint.calls, 0)
    }

    func testRejectionWithoutRefreshTokenReportsExpired() async throws {
        let storage = MemoryCredentialStorage(keychain: blob(access: "access-1", refresh: nil, expiresIn: 3600))
        let endpoint = TokenEndpointStub()
        let store = makeStore(storage, endpoint)
        let rejected = try await store.usableCredentials()

        await assertThrows(.tokenExpired) { try await store.credentialsAfterRejection(of: rejected) }
        XCTAssertEqual(endpoint.calls, 0)
    }

    func testRejectedRefreshTokenReportsExpired() async {
        let storage = MemoryCredentialStorage(keychain: blob(access: "access-1", refresh: "refresh-1", expiresIn: -3600))
        let endpoint = TokenEndpointStub(status: 400)

        await assertThrows(.tokenExpired) { try await self.makeStore(storage, endpoint).usableCredentials() }
    }

    func testRefreshIsSkippedWhenTheResultCouldNotBeSaved() async {
        let storage = MemoryCredentialStorage(keychain: blob(access: "access-1", refresh: "refresh-1", expiresIn: -3600))
        storage.unwritable = true
        let endpoint = TokenEndpointStub()

        await assertThrows(.credentialsNotSaved) { try await self.makeStore(storage, endpoint).usableCredentials() }
        XCTAssertEqual(endpoint.calls, 0)
    }

    func testRefreshWaitsForAnotherRefresher() async throws {
        let lockURL = temporaryLockURL()
        let other = try XCTUnwrap(ClaudeRefreshLock(urls: [lockURL]).acquire())
        defer { other.release() }
        let storage = MemoryCredentialStorage(keychain: blob(access: "access-1", refresh: "refresh-1", expiresIn: -3600))
        let endpoint = TokenEndpointStub()

        await assertThrows(.refreshInProgress) {
            try await self.makeStore(storage, endpoint, lock: ClaudeRefreshLock(urls: [lockURL])).usableCredentials()
        }
        XCTAssertEqual(endpoint.calls, 0)
    }

    func testFileCredentialsAreRefreshedInTheFile() async throws {
        let storage = MemoryCredentialStorage(file: blob(access: "access-1", refresh: "refresh-1", expiresIn: -3600))

        let credentials = try await makeStore(storage, TokenEndpointStub()).usableCredentials()

        XCTAssertEqual(credentials.accessToken, "access-2")
        XCTAssertEqual(storage.credentials(.file)?["accessToken"] as? String, "access-2")
        XCTAssertNil(storage.data(.keychain))
    }

    private func makeStore(
        _ storage: MemoryCredentialStorage,
        _ endpoint: TokenEndpointStub,
        lock: ClaudeRefreshLock? = nil
    ) -> ClaudeCredentialStore {
        ClaudeCredentialStore(
            storage: storage,
            exchange: endpoint.exchange,
            lock: lock ?? ClaudeRefreshLock(urls: [temporaryLockURL()]),
            lockAttempts: 2,
            lockRetryDelay: 1_000_000,
            now: { Self.now }
        )
    }

    private func blob(access: String, refresh: String?, expiresIn: TimeInterval, mcp: String = "unchanged") -> Data {
        var oauth: [String: Any] = [
            "accessToken": access,
            "expiresAt": Int64((Self.now.timeIntervalSince1970 + expiresIn) * 1000),
            "scopes": ["user:profile", "user:inference"],
            "subscriptionType": "max",
            "rateLimitTier": "default_claude_max_20x",
        ]
        if let refresh {
            oauth["refreshToken"] = refresh
        }
        let root: [String: Any] = ["claudeAiOauth": oauth, "mcpOAuth": ["server": mcp]]
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func temporaryLockURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("oauth-lock-\(UUID().uuidString)")
    }

    private func assertThrows(
        _ expected: ClaudeUsageError,
        line: UInt = #line,
        _ body: () async throws -> ClaudeCredentials
    ) async {
        do {
            _ = try await body()
            XCTFail("Expected \(expected)", line: line)
        } catch let error as ClaudeUsageError {
            XCTAssertEqual(String(describing: error), String(describing: expected), line: line)
        } catch {
            XCTFail("Unexpected error \(error)", line: line)
        }
    }
}

private final class MemoryCredentialStorage: ClaudeCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClaudeCredentialSource: Data] = [:]
    private var pendingReadFailures = 0
    private var writeCount = 0
    private var state = (readsFail: false, writesFail: false, unwritable: false, failReadsAfterEachWrite: 0)
    private var writeHook: (@Sendable () -> Void)?

    init(keychain: Data? = nil, file: Data? = nil) {
        items[.keychain] = keychain
        items[.file] = file
    }

    var readsFail: Bool {
        get { lock.withLock { state.readsFail } }
        set { lock.withLock { state.readsFail = newValue } }
    }

    var writesFail: Bool {
        get { lock.withLock { state.writesFail } }
        set { lock.withLock { state.writesFail = newValue } }
    }

    var unwritable: Bool {
        get { lock.withLock { state.unwritable } }
        set { lock.withLock { state.unwritable = newValue } }
    }

    var failReadsAfterEachWrite: Int {
        get { lock.withLock { state.failReadsAfterEachWrite } }
        set {
            lock.withLock {
                state.failReadsAfterEachWrite = newValue
                pendingReadFailures = 0
            }
        }
    }

    var onWrite: (@Sendable () -> Void)? {
        get { lock.withLock { writeHook } }
        set { lock.withLock { writeHook = newValue } }
    }

    var writes: Int {
        lock.withLock { writeCount }
    }

    func set(_ data: Data?, for source: ClaudeCredentialSource) {
        lock.withLock { items[source] = data }
    }

    func data(_ source: ClaudeCredentialSource) -> Data? {
        lock.withLock { items[source] }
    }

    func json(_ source: ClaudeCredentialSource) -> [String: Any]? {
        data(source).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func credentials(_ source: ClaudeCredentialSource) -> [String: Any]? {
        json(source)?["claudeAiOauth"] as? [String: Any]
    }

    func read(_ source: ClaudeCredentialSource) async throws -> Data? {
        try readNow(source)
    }

    func canWrite(_ data: Data, to source: ClaudeCredentialSource) async throws -> Bool {
        !unwritable
    }

    func write(_ data: Data, to source: ClaudeCredentialSource) async throws {
        try writeNow(data, to: source)
        onWrite?()
    }

    private func readNow(_ source: ClaudeCredentialSource) throws -> Data? {
        try lock.withLock {
            if state.readsFail { throw ClaudeUsageError.keychainUnavailable }
            if pendingReadFailures > 0 {
                pendingReadFailures -= 1
                throw ClaudeUsageError.keychainUnavailable
            }
            return items[source]
        }
    }

    private func writeNow(_ data: Data, to source: ClaudeCredentialSource) throws {
        try lock.withLock {
            if state.writesFail { throw ClaudeUsageError.credentialsNotSaved }
            items[source] = data
            writeCount += 1
            pendingReadFailures = state.failReadsAfterEachWrite
        }
    }
}

private final class TokenEndpointStub: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let status: Int
    private let onRequest: @Sendable () async -> Void

    init(status: Int = 200, onRequest: @escaping @Sendable () async -> Void = {}) {
        self.status = status
        self.onRequest = onRequest
    }

    var calls: Int {
        lock.withLock { count }
    }

    var exchange: ClaudeTokenExchange {
        { [self] request in
            increment()
            await onRequest()
            try Task.checkCancellation()
            let body = status == 200
                ? #"{"token_type":"Bearer","access_token":"access-2","refresh_token":"refresh-2","expires_in":28800}"#
                : #"{"error":"invalid_grant"}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private func increment() {
        lock.withLock { count += 1 }
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
