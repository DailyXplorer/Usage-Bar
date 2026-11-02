import XCTest
@testable import UsageBar

final class ClaudeKeychainTests: XCTestCase {
    private let attributes = Data("""
    class: "genp"
    attributes:
        "acct"<blob>="user"
        "svce"<blob>="Claude Code-credentials"
    """.utf8)

    func testReadReturnsTheStoredPassword() async throws {
        let keychain = ClaudeKeychain { _, _ in Subprocess.Output(status: 0, stdout: Data("{}\n".utf8), timedOut: false) }

        let data = try await keychain.read()

        XCTAssertEqual(data, Data("{}\n".utf8))
    }

    func testOnlyExitStatus44MeansNoItem() async throws {
        let missing = ClaudeKeychain { _, _ in Subprocess.Output(status: 44, stdout: Data(), timedOut: false) }

        let data = try await missing.read()

        XCTAssertNil(data)
        for status: Int32 in [1, 36, 45, 51, 128] {
            let failing = ClaudeKeychain { _, _ in Subprocess.Output(status: status, stdout: Data(), timedOut: false) }
            await assertKeychainUnavailable(failing, "exit \(status)")
        }
    }

    func testTimeoutAndLaunchFailureMeanKeychainUnavailable() async {
        let slow = ClaudeKeychain { _, _ in Subprocess.Output(status: 15, stdout: Data(), timedOut: true) }
        let broken = ClaudeKeychain { _, _ in throw CocoaError(.executableNotLoadable) }

        await assertKeychainUnavailable(slow, "timeout")
        await assertKeychainUnavailable(broken, "launch failure")
    }

    func testWriteKeepsTheCredentialOffTheCommandLine() async throws {
        let recorder = SecurityRecorder(attributes: attributes)
        let keychain = ClaudeKeychain(run: recorder.run)
        let payload = #"{"claudeAiOauth":{"accessToken":"synthetic-access"}}"#

        try await keychain.write(Data(payload.utf8))

        let calls = recorder.calls
        XCTAssertEqual(calls.last?.arguments, ["-i"])
        XCTAssertTrue(String(decoding: calls.last?.input ?? Data(), as: UTF8.self).contains("synthetic-access"))
        XCTAssertFalse(calls.contains { $0.arguments.joined().contains("synthetic-access") })
    }

    func testWriteRefusesPayloadsTooLongForStdin() async {
        let recorder = SecurityRecorder(attributes: attributes)
        let keychain = ClaudeKeychain(run: recorder.run)
        let payload = Data(repeating: 0x61, count: ClaudeKeychainCommand.lineLimit)

        do {
            try await keychain.write(payload)
            XCTFail("Expected credentialsNotSaved")
        } catch ClaudeUsageError.credentialsNotSaved {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertFalse(recorder.calls.contains { $0.arguments.contains("add-generic-password") || $0.arguments == ["-i"] })
    }

    func testWriteFailsWhenSecurityFails() async {
        let keychain = ClaudeKeychain { arguments, _ in
            arguments == ["-i"]
                ? Subprocess.Output(status: 1, stdout: Data(), timedOut: false)
                : Subprocess.Output(status: 0, stdout: self.attributes, timedOut: false)
        }

        do {
            try await keychain.write(Data("{}".utf8))
            XCTFail("Expected credentialsNotSaved")
        } catch ClaudeUsageError.credentialsNotSaved {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testUnavailableKeychainDoesNotFallBackToTheFile() async throws {
        let file = try temporaryCredentialsFile()
        let storage = SystemClaudeCredentialStorage(
            keychain: ClaudeKeychain { _, _ in Subprocess.Output(status: 51, stdout: Data(), timedOut: false) },
            fileURL: file
        )
        let store = ClaudeCredentialStore(
            storage: storage,
            exchange: { _ in throw URLError(.notConnectedToInternet) },
            lock: ClaudeRefreshLock(urls: [FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")])
        )

        do {
            _ = try await store.usableCredentials()
            XCTFail("Expected keychainUnavailable")
        } catch ClaudeUsageError.keychainUnavailable {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testMissingKeychainItemFallsBackToTheFile() async throws {
        let file = try temporaryCredentialsFile()
        let storage = SystemClaudeCredentialStorage(
            keychain: ClaudeKeychain { _, _ in Subprocess.Output(status: 44, stdout: Data(), timedOut: false) },
            fileURL: file
        )
        let store = ClaudeCredentialStore(
            storage: storage,
            exchange: { _ in throw URLError(.notConnectedToInternet) },
            lock: ClaudeRefreshLock(urls: [FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")])
        )

        let credentials = try await store.usableCredentials()

        XCTAssertEqual(credentials.accessToken, "file-access")
    }

    func testFileWriteReplacesTheFileAndKeepsItsPermissions() async throws {
        let file = try temporaryCredentialsFile()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let storage = SystemClaudeCredentialStorage(
            keychain: ClaudeKeychain { _, _ in Subprocess.Output(status: 44, stdout: Data(), timedOut: false) },
            fileURL: file
        )

        try await storage.write(Data("{}".utf8), to: .file)

        XCTAssertEqual(try Data(contentsOf: file), Data("{}".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, [file.lastPathComponent])
    }

    private func assertKeychainUnavailable(_ keychain: ClaudeKeychain, _ label: String, line: UInt = #line) async {
        do {
            _ = try await keychain.read()
            XCTFail("Expected keychainUnavailable for \(label)", line: line)
        } catch ClaudeUsageError.keychainUnavailable {
        } catch {
            XCTFail("Unexpected error \(error) for \(label)", line: line)
        }
    }

    private func temporaryCredentialsFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".credentials.json")
        let blob = #"{"claudeAiOauth":{"accessToken":"file-access","refreshToken":"file-refresh","expiresAt":4102444800000}}"#
        try Data(blob.utf8).write(to: file)
        return file
    }
}

private final class SecurityRecorder: @unchecked Sendable {
    struct Call {
        let arguments: [String]
        let input: Data?
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let attributes: Data

    init(attributes: Data) {
        self.attributes = attributes
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    var run: ClaudeKeychain.Runner {
        { [self] arguments, input in
            record(Call(arguments: arguments, input: input))
            let stdout = arguments == ["find-generic-password", "-s", ClaudeKeychain.service] ? attributes : Data()
            return Subprocess.Output(status: 0, stdout: stdout, timedOut: false)
        }
    }

    private func record(_ call: Call) {
        lock.withLock { recorded.append(call) }
    }
}
