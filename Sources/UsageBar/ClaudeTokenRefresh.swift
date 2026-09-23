import Foundation

struct ClaudeTokenGrant: Decodable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval
    let refreshTokenExpiresIn: TimeInterval?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case scope
    }
}

enum ClaudeTokenRefresh {
    static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let defaultScopes = [
        "user:profile",
        "user:inference",
        "user:sessions:claude_code",
        "user:mcp_servers",
        "user:file_upload",
    ]

    static func requestBody(refreshToken: String, scopes: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": (scopes.isEmpty ? defaultScopes : scopes).joined(separator: " "),
        ])
    }

    static func storedCredentials(_ stored: Data, applying grant: ClaudeTokenGrant, now: Date) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: stored) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any] else {
            throw ClaudeUsageError.notSignedIn
        }
        oauth["accessToken"] = grant.accessToken
        oauth["expiresAt"] = milliseconds(now.addingTimeInterval(grant.expiresIn))
        if let refreshToken = grant.refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        if let lifetime = grant.refreshTokenExpiresIn {
            oauth["refreshTokenExpiresAt"] = milliseconds(now.addingTimeInterval(lifetime))
        }
        if let scope = grant.scope {
            oauth["scopes"] = scope.split(separator: " ").map(String.init)
        }
        root["claudeAiOauth"] = oauth
        return try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

struct ClaudeKeychainCommand: Equatable {
    static let stdinLimit = 4032

    let arguments: [String]
    let input: String?

    static func save(_ data: Data, account: String, service: String) -> ClaudeKeychainCommand {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\""
        let quotable = !(account + service).contains { $0 == "\"" || $0 == "\\" }
        if quotable, line.count <= stdinLimit {
            return ClaudeKeychainCommand(arguments: ["-i"], input: line + "\n")
        }
        return ClaudeKeychainCommand(
            arguments: ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex],
            input: nil
        )
    }

    static func account(fromAttributes attributes: String) -> String? {
        let prefix = "\"acct\"<blob>=\""
        for line in attributes.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix), trimmed.hasSuffix("\""), trimmed.count > prefix.count else { continue }
            let account = String(trimmed.dropFirst(prefix.count).dropLast())
            return account.isEmpty ? nil : account
        }
        return nil
    }
}

struct ClaudeRefreshLock {
    static let staleAfter: TimeInterval = 10

    let url: URL

    func acquire(now: Date = Date()) -> Bool {
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { return true }
        if create() { return true }
        guard let modified = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
              now.timeIntervalSince(modified) > Self.staleAfter else {
            return false
        }
        try? FileManager.default.removeItem(at: url)
        return create()
    }

    func release() {
        try? FileManager.default.removeItem(at: url)
    }

    private func create() -> Bool {
        (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)) != nil
    }
}
