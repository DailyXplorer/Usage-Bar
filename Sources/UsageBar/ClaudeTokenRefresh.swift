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

    static let resourceTimeout: TimeInterval = 30
    static let session: URLSession = {
        let configuration = ProviderSession.configuration
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration)
    }()
    static let exchange: ClaudeTokenExchange = { request in
        try await session.data(for: request, delegate: ClaudeTokenRedirectGuard())
    }

    static func request(refreshToken: String, scopes: [String]) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try requestBody(refreshToken: refreshToken, scopes: scopes)
        return request
    }

    static func requestBody(refreshToken: String, scopes: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": (scopes.isEmpty ? defaultScopes : scopes).joined(separator: " "),
        ])
    }

    static func allowsRedirect(to url: URL?) -> Bool {
        url?.scheme == "https" && url?.host == endpoint.host
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

final class ClaudeTokenRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        ClaudeTokenRefresh.allowsRedirect(to: request.url) ? request : nil
    }
}

struct ClaudeKeychainCommand: Equatable {
    static let lineLimit = 4032

    let arguments: [String]
    let input: String

    static func save(_ data: Data, account: String, service: String) -> ClaudeKeychainCommand? {
        let password: String
        if data.allSatisfy({ (0x20...0x7e).contains($0) }) {
            password = "-w " + quoted(String(decoding: data, as: UTF8.self))
        } else {
            password = "-X " + quoted(data.map { String(format: "%02x", $0) }.joined())
        }
        let line = "add-generic-password -U -a \(quoted(account)) -s \(quoted(service)) \(password)"
        guard !line.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              line.utf8.count < lineLimit else {
            return nil
        }
        return ClaudeKeychainCommand(arguments: ["-i"], input: line + "\n")
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

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'" + escaped + "'"
    }
}

struct ClaudeKeychain: Sendable {
    typealias Runner = @Sendable (_ arguments: [String], _ input: Data?) async throws -> Subprocess.Output

    static let service = "Claude Code-credentials"
    static let itemNotFound: Int32 = 44
    static let timeout: TimeInterval = 15
    static let system = ClaudeKeychain { arguments, input in
        try await Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/security"),
            arguments: arguments,
            input: input,
            timeout: timeout
        )
    }

    let run: Runner

    func read() async throws -> Data? {
        try await query(["find-generic-password", "-s", Self.service, "-w"]).flatMap { $0.isEmpty ? nil : $0 }
    }

    func saveCommand(for data: Data) async throws -> ClaudeKeychainCommand? {
        let attributes = try await query(["find-generic-password", "-s", Self.service])
        guard let account = attributes.flatMap({
            ClaudeKeychainCommand.account(fromAttributes: String(decoding: $0, as: UTF8.self))
        }) else {
            return nil
        }
        return ClaudeKeychainCommand.save(data, account: account, service: Self.service)
    }

    func write(_ data: Data) async throws {
        guard let command = try await saveCommand(for: data) else {
            throw ClaudeUsageError.credentialsNotSaved
        }
        let output: Subprocess.Output
        do {
            output = try await run(command.arguments, Data(command.input.utf8))
        } catch {
            throw ClaudeUsageError.credentialsNotSaved
        }
        guard output.status == 0, !output.timedOut else {
            throw ClaudeUsageError.credentialsNotSaved
        }
    }

    private func query(_ arguments: [String]) async throws -> Data? {
        let output: Subprocess.Output
        do {
            output = try await run(arguments, nil)
        } catch {
            throw ClaudeUsageError.keychainUnavailable
        }
        guard !output.timedOut else { throw ClaudeUsageError.keychainUnavailable }
        if output.status == Self.itemNotFound { return nil }
        guard output.status == 0 else { throw ClaudeUsageError.keychainUnavailable }
        return output.stdout
    }
}

struct ClaudeRefreshLock {
    static let staleAfter: TimeInterval = 60

    struct Hold {
        fileprivate let owned: [(url: URL, modified: Date)]

        func release() {
            for lock in owned.reversed() where ClaudeRefreshLock.modificationDate(of: lock.url) == lock.modified {
                try? FileManager.default.removeItem(at: lock.url)
            }
        }
    }

    let urls: [URL]

    init(claudeDirectory: URL) {
        let directory = claudeDirectory.resolvingSymlinksInPath()
        urls = [
            claudeDirectory.appendingPathComponent(".oauth_refresh.lock"),
            directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".lock"),
        ]
    }

    init(urls: [URL]) {
        self.urls = urls
    }

    func acquire(now: Date = Date()) -> Hold? {
        var owned: [(url: URL, modified: Date)] = []
        for url in urls where FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            guard let modified = Self.create(url, now: now) else {
                Hold(owned: owned).release()
                return nil
            }
            owned.append((url, modified))
        }
        return Hold(owned: owned)
    }

    private static func create(_ url: URL, now: Date) -> Date? {
        if let modified = makeDirectory(url) { return modified }
        guard let modified = modificationDate(of: url), now.timeIntervalSince(modified) > staleAfter else {
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        return makeDirectory(url)
    }

    private static func makeDirectory(_ url: URL) -> Date? {
        guard (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)) != nil else {
            return nil
        }
        return modificationDate(of: url)
    }

    fileprivate static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
