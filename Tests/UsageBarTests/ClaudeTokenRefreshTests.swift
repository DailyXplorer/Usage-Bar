import XCTest
@testable import UsageBar

final class ClaudeTokenRefreshTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testRequestBodyMatchesClaudeCodeRefreshGrant() throws {
        let body = try ClaudeTokenRefresh.requestBody(refreshToken: "refresh-1", scopes: ["user:profile", "user:inference"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])

        XCTAssertEqual(json, [
            "grant_type": "refresh_token",
            "refresh_token": "refresh-1",
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "scope": "user:profile user:inference",
        ])
    }

    func testRequestBodyFallsBackToClaudeCodeScopes() throws {
        let body = try ClaudeTokenRefresh.requestBody(refreshToken: "refresh-1", scopes: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])

        XCTAssertEqual(json["scope"], "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload")
    }

    func testStoredCredentialsKeepUnrelatedFieldsAndRotateTokens() throws {
        let stored = Data("""
        {"claudeAiOauth":{"accessToken":"old","refreshToken":"refresh-1","expiresAt":1,"refreshTokenExpiresAt":2,
        "scopes":["user:profile"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},
        "mcpOAuth":{"server":{"accessToken":"mcp"}}}
        """.utf8)
        let grant = ClaudeTokenGrant(
            accessToken: "new",
            refreshToken: "refresh-2",
            expiresIn: 28_800,
            refreshTokenExpiresIn: 86_400,
            scope: "user:profile user:inference"
        )

        let updated = try ClaudeTokenRefresh.storedCredentials(stored, applying: grant, now: now)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let oauth = try XCTUnwrap(root["claudeAiOauth"] as? [String: Any])

        XCTAssertEqual(oauth["accessToken"] as? String, "new")
        XCTAssertEqual(oauth["refreshToken"] as? String, "refresh-2")
        XCTAssertEqual(oauth["expiresAt"] as? Int, 1_790_028_800_000)
        XCTAssertEqual(oauth["refreshTokenExpiresAt"] as? Int, 1_790_086_400_000)
        XCTAssertEqual(oauth["scopes"] as? [String], ["user:profile", "user:inference"])
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")
        XCTAssertEqual(oauth["rateLimitTier"] as? String, "default_claude_max_20x")
        XCTAssertEqual((root["mcpOAuth"] as? [String: [String: String]])?["server"]?["accessToken"], "mcp")
    }

    func testStoredCredentialsKeepRefreshTokenWhenGrantOmitsIt() throws {
        let stored = Data(#"{"claudeAiOauth":{"accessToken":"old","refreshToken":"refresh-1","expiresAt":1,"refreshTokenExpiresAt":2}}"#.utf8)
        let grant = ClaudeTokenGrant(accessToken: "new", refreshToken: nil, expiresIn: 60, refreshTokenExpiresIn: nil, scope: nil)

        let updated = try ClaudeTokenRefresh.storedCredentials(stored, applying: grant, now: now)
        let oauth = try XCTUnwrap((JSONSerialization.jsonObject(with: updated) as? [String: Any])?["claudeAiOauth"] as? [String: Any])

        XCTAssertEqual(oauth["refreshToken"] as? String, "refresh-1")
        XCTAssertEqual(oauth["refreshTokenExpiresAt"] as? Int, 2)
        XCTAssertEqual(oauth["expiresAt"] as? Int, 1_790_000_060_000)
    }

    func testGrantDecodesTokenEndpointResponse() throws {
        let data = Data(#"{"token_type":"Bearer","access_token":"a","refresh_token":"r","expires_in":28800,"scope":"user:profile"}"#.utf8)

        XCTAssertEqual(
            try JSONDecoder().decode(ClaudeTokenGrant.self, from: data),
            ClaudeTokenGrant(accessToken: "a", refreshToken: "r", expiresIn: 28_800, refreshTokenExpiresIn: nil, scope: "user:profile")
        )
    }

    func testKeychainSaveUsesStdinLikeClaudeCode() {
        let command = ClaudeKeychainCommand.save(Data("{}".utf8), account: "louis", service: "Claude Code-credentials")

        XCTAssertEqual(command, ClaudeKeychainCommand(
            arguments: ["-i"],
            input: "add-generic-password -U -a \"louis\" -s \"Claude Code-credentials\" -X \"7b7d\"\n"
        ))
    }

    func testKeychainSaveFallsBackToArgumentsForLargePayloads() {
        let payload = Data(repeating: 0x61, count: 2100)
        let command = ClaudeKeychainCommand.save(payload, account: "louis", service: "Claude Code-credentials")

        XCTAssertNil(command.input)
        XCTAssertEqual(Array(command.arguments.prefix(7)), ["add-generic-password", "-U", "-a", "louis", "-s", "Claude Code-credentials", "-X"])
        XCTAssertEqual(command.arguments.last, String(repeating: "61", count: 2100))
    }

    func testKeychainSaveAvoidsStdinWhenAccountNeedsQuoting() {
        let command = ClaudeKeychainCommand.save(Data("{}".utf8), account: "a\"b", service: "Claude Code-credentials")

        XCTAssertEqual(command.arguments, ["add-generic-password", "-U", "-a", "a\"b", "-s", "Claude Code-credentials", "-X", "7b7d"])
        XCTAssertNil(command.input)
    }

    func testKeychainAccountIsReadFromItemAttributes() {
        let attributes = """
        keychain: "/Users/louis/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            "acct"<blob>="louis"
            "svce"<blob>="Claude Code-credentials"
        """

        XCTAssertEqual(ClaudeKeychainCommand.account(fromAttributes: attributes), "louis")
        XCTAssertNil(ClaudeKeychainCommand.account(fromAttributes: #"    "acct"<blob>=<NULL>"#))
        XCTAssertNil(ClaudeKeychainCommand.account(fromAttributes: #"    "acct"<blob>="""#))
    }

    func testRefreshLockDoesNotBlockWithoutClaudeDirectory() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
            .appendingPathComponent(".oauth_refresh.lock")

        XCTAssertTrue(ClaudeRefreshLock(url: url).acquire())
    }

    func testRefreshLockIsExclusiveUntilReleasedOrStale() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oauth-lock-\(UUID().uuidString)")
        let lock = ClaudeRefreshLock(url: url)
        defer { lock.release() }

        XCTAssertTrue(lock.acquire(now: Date()))
        XCTAssertFalse(lock.acquire(now: Date()))
        XCTAssertTrue(lock.acquire(now: Date().addingTimeInterval(ClaudeRefreshLock.staleAfter + 1)))
        lock.release()
        XCTAssertTrue(lock.acquire(now: Date()))
    }
}
