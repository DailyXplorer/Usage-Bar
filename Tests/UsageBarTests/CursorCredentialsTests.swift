import CommonCrypto
import Foundation
import SQLite3
import XCTest
@testable import UsageBar

final class CursorCredentialsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    func testEncryptedEditorTokenIsDecryptedWithSafeStorageKey() async throws {
        let token = jwt(expiry: now.addingTimeInterval(3_600))
        let stored = try sealed(token, password: "synthetic-password")
        let loader = CursorCredentialLoader.stub(editor: stored, settings: nil, password: "synthetic-password", now: now)

        let credentials = try await loader.load()

        XCTAssertEqual(credentials.accessToken, token)
        XCTAssertEqual(credentials.source, .editor)
        XCTAssertEqual(credentials.membershipType, "pro")
    }

    func testPlaintextEditorTokenIsUsedAsIs() async throws {
        let token = jwt(expiry: now.addingTimeInterval(3_600))
        let credentials = try await CursorCredentialLoader.stub(editor: token, settings: nil, now: now).load()

        XCTAssertEqual(credentials.accessToken, token)
    }

    func testWrongSafeStorageKeyFallsBackToSettingsToken() async throws {
        let stored = try sealed(jwt(expiry: now.addingTimeInterval(3_600)), password: "synthetic-password")
        let settings = jwt(expiry: now.addingTimeInterval(60))
        let loader = CursorCredentialLoader.stub(editor: stored, settings: settings, password: "other", now: now)

        let credentials = try await loader.load()

        XCTAssertEqual(credentials.accessToken, settings)
        XCTAssertEqual(credentials.source, .settingsToken)
    }

    func testDeniedKeychainWithoutSettingsTokenSaysSo() async throws {
        let stored = try sealed("token", password: "synthetic-password")
        let loader = CursorCredentialLoader.stub(editor: stored, settings: nil, password: nil, now: now)

        await XCTAssertThrowsCursorError(.unreadableLogin) { try await loader.load() }
    }

    func testExpiredEditorTokenIsSkippedNeverRefreshed() async throws {
        let expired = jwt(expiry: now.addingTimeInterval(-1))
        let settings = "user_01ABC%3A%3A" + jwt(expiry: now.addingTimeInterval(600))
        let loader = CursorCredentialLoader.stub(editor: expired, settings: settings, now: now)

        let credentials = try await loader.load()

        XCTAssertEqual(credentials.accessToken, jwt(expiry: now.addingTimeInterval(600)))
    }

    func testOnlyExpiredTokensReportExpiredSignIn() async {
        let expired = jwt(expiry: now.addingTimeInterval(-1))
        let loader = CursorCredentialLoader.stub(editor: expired, settings: expired, now: now)

        await XCTAssertThrowsCursorError(.tokenExpired) { try await loader.load() }
    }

    func testNoSourceMeansNotSignedIn() async {
        let loader = CursorCredentialLoader.stub(editor: nil, settings: "   ", now: now)

        await XCTAssertThrowsCursorError(.notSignedIn) { try await loader.load() }
    }

    func testSessionTokenAcceptsCookieForms() {
        let token = jwt(expiry: now)
        XCTAssertEqual(CursorSessionToken.accessToken(from: token), token)
        XCTAssertEqual(CursorSessionToken.accessToken(from: " user_01ABC%3A%3A\(token)\n"), token)
        XCTAssertEqual(CursorSessionToken.accessToken(from: "user_01ABC::\(token)"), token)
        XCTAssertEqual(CursorSessionToken.accessToken(from: "WorkosCursorSessionToken=user_01ABC%3A%3A\(token); Path=/"), token)
        XCTAssertEqual(CursorSessionToken.accessToken(from: "Bearer \(token)"), token)
        XCTAssertNil(CursorSessionToken.accessToken(from: ""))
        XCTAssertNil(CursorSessionToken.accessToken(from: "two words"))
    }

    func testJWTExpiryIsReadWithoutNetwork() {
        XCTAssertEqual(CursorJWT.expiry(of: jwt(expiry: now)), now)
        XCTAssertTrue(CursorJWT.isExpired(jwt(expiry: now), at: now))
        XCTAssertFalse(CursorJWT.isExpired("opaque-token", at: now))
    }

    func testEditorStoreReadsTextAndBlobValues() async throws {
        let file = try temporaryDatabase()
        try execute(file, [
            "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)",
            "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', CAST('token-from-blob' AS BLOB))",
            "INSERT INTO ItemTable VALUES ('cursorAuth/stripeMembershipType', 'pro')",
            "INSERT INTO ItemTable VALUES ('other', 'ignored')",
        ])

        let login = await CursorEditorStore.readLogin(from: file)

        XCTAssertEqual(login?.accessToken, "token-from-blob")
        XCTAssertEqual(login?.membershipType, "pro")
    }

    func testEditorStoreSeesUncheckpointedWALWrites() async throws {
        let file = try temporaryDatabase()
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        for sql in [
            "PRAGMA journal_mode=WAL",
            "PRAGMA wal_autocheckpoint=0",
            "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)",
            "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'wal-token')",
        ] {
            XCTAssertEqual(sqlite3_exec(writer, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + "-wal"))

        let login = await CursorEditorStore.readLogin(from: file)

        XCTAssertEqual(login?.accessToken, "wal-token")
    }

    func testMissingEditorDatabaseReadsAsNoLogin() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).vscdb")

        let login = await CursorEditorStore.readLogin(from: missing)

        XCTAssertNil(login)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testUndecryptableLoginReadsSafeStorageOncePerRetryDelay() async throws {
        let reads = KeychainReadCounter()
        let clock = KeychainTestClock(now)
        let keychain = CursorSafeStorageKeychain(read: { reads.read("stale-password") }, now: { clock.now })
        let stored = try sealed(jwt(expiry: now.addingTimeInterval(3_600)), password: "current-password")
        let loader = CursorCredentialLoader(
            editorLogin: { CursorEditorLogin(accessToken: stored, membershipType: "pro") },
            safeStoragePassword: { await keychain.password() },
            settingsToken: { nil },
            now: { clock.now },
            forgetSafeStoragePassword: { await keychain.forget() }
        )

        for _ in 0..<3 {
            await XCTAssertThrowsCursorError(.unreadableLogin) { try await loader.load() }
        }
        XCTAssertEqual(reads.count, 1)

        clock.now = now.addingTimeInterval(60 * 60 + 1)
        await XCTAssertThrowsCursorError(.unreadableLogin) { try await loader.load() }
        await XCTAssertThrowsCursorError(.unreadableLogin) { try await loader.load() }
        XCTAssertEqual(reads.count, 2)
    }

    func testFailedSettingsTokenReadIsRetriedAfterDelay() async {
        let reads = KeychainReadCounter()
        let clock = KeychainTestClock(now)
        let store = CursorSessionTokenStore(read: { reads.count == 0 ? reads.read(nil) : reads.read("saved-token") }, now: { clock.now })

        let first = await store.token()
        let blocked = await store.token()
        clock.now = now.addingTimeInterval(60 * 60 + 1)
        let retried = await store.token()
        let cached = await store.token()

        XCTAssertNil(first)
        XCTAssertNil(blocked)
        XCTAssertEqual(retried, "saved-token")
        XCTAssertEqual(cached, "saved-token")
        XCTAssertEqual(reads.count, 2)
    }

    func testBlockingWorkReturnsNilAfterTimeout() async {
        let start = Date()
        let value: Int? = await ProviderIO.runBlocking(timeout: 0.2) {
            Thread.sleep(forTimeInterval: 2)
            return 1
        }

        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    private func jwt(expiry: Date) -> String {
        let header = Data(#"{"alg":"none"}"#.utf8).base64URLEncoded
        let payload = Data(#"{"sub":"user_synthetic","exp":\#(Int(expiry.timeIntervalSince1970))}"#.utf8).base64URLEncoded
        return "\(header).\(payload).signature"
    }

    private func sealed(_ token: String, password: String) throws -> String {
        let key = try XCTUnwrap(CursorSafeStorage.derivedKey(password: password))
        let plain = Data(token.utf8)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: plain.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let status = output.withUnsafeMutableBytes { out in
            plain.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            input.baseAddress, plain.count, out.baseAddress, capacity, &written
                        )
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        let blob = Data("v10".utf8) + output.prefix(written)
        return CursorSafeStorage.prefix + blob.base64EncodedString()
    }

    private func temporaryDatabase() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("state.vscdb")
    }

    private func execute(_ file: URL, _ statements: [String]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in statements {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
    }
}

private final class KeychainReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var count: Int {
        lock.withLock { reads }
    }

    func read(_ value: String?) -> String? {
        lock.withLock { reads += 1 }
        return value
    }
}

private final class KeychainTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

func XCTAssertThrowsCursorError<T>(
    _ expected: CursorUsageError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> T
) async {
    do {
        _ = try await body()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as CursorUsageError {
        XCTAssertEqual(String(describing: error), String(describing: expected), file: file, line: line)
    } catch {
        XCTFail("Unexpected error \(error)", file: file, line: line)
    }
}
