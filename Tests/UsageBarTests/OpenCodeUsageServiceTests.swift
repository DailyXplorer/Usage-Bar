import Foundation
import XCTest
@testable import UsageBar

final class OpenCodeUsageServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeUsageServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ClaudeStubProtocol.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        ClaudeStubProtocol.reset()
    }

    func testRejectedKeyCarriesItsFingerprintAndNeverTheKey() async throws {
        ClaudeStubProtocol.respond(status: 401, json: "{}")

        do {
            _ = try await service(key: "secret-key-one").fetchUsage()
            XCTFail("Expected a rejection")
        } catch OpenCodeUsageError.invalidKey(let fingerprint) {
            XCTAssertEqual(fingerprint, CredentialFingerprint.make("secret-key-one"))
            XCTAssertFalse(fingerprint.contains("secret"))
        }
    }

    func testHeldKeyIsNotSentToTheNetwork() async throws {
        do {
            _ = try await service(key: "key-one").fetchUsage(holdingKey: CredentialFingerprint.make("key-one"))
            XCTFail("Expected the key to stay on hold")
        } catch OpenCodeUsageError.keyOnHold {
            XCTAssertTrue(ClaudeStubProtocol.requests.isEmpty)
        }
    }

    func testChangedKeyIsRetriedAtOnceAndOldKeyAfterTheHold() async throws {
        let held = CredentialFingerprint.make("key-one")
        ClaudeStubProtocol.respond(json: Self.usage)
        ClaudeStubProtocol.respond(json: Self.usage)

        _ = try await service(key: "key-two").fetchUsage(holdingKey: held)
        _ = try await service(key: "key-one").fetchUsage(holdingKey: nil)

        XCTAssertEqual(ClaudeStubProtocol.requests.count, 2)
        XCTAssertEqual(ClaudeStubProtocol.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer key-two")
    }

    private static let usage = #"{"usage":{"rolling":{"status":"ok","percent":18,"resetsAt":"2026-11-02T12:00:00Z"}}}"#

    private func service(key: String) throws -> OpenCodeUsageService {
        let auth = directory.appendingPathComponent("auth.json")
        try Data(#"{"opencode-go":{"type":"api","key":"\#(key)"}}"#.utf8).write(to: auth)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeStubProtocol.self]
        return OpenCodeUsageService(
            session: URLSession(configuration: configuration),
            databases: [],
            authFiles: [auth]
        )
    }
}
