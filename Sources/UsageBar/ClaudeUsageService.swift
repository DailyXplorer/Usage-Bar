import Foundation

struct ClaudeCredentials {
    let accessToken: String
    let subscriptionType: String?
    let rateLimitTier: String?
    let expiresAt: Date?
    var refreshToken: String? = nil
    var scopes: [String] = []

    var planToken: String? {
        guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
        guard subscriptionType.lowercased() == "max" else { return subscriptionType }
        guard let multiplier = Self.maxMultiplier(from: rateLimitTier) else {
            return subscriptionType
        }
        return "max_\(multiplier)"
    }

    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    private static func maxMultiplier(from rateLimitTier: String?) -> String? {
        guard let rateLimitTier, !rateLimitTier.isEmpty else { return nil }
        let normalized = rateLimitTier.lowercased()
        if normalized.contains("20x") { return "20x" }
        if normalized.contains("5x") { return "5x" }
        return nil
    }
}

enum ClaudeUsageError: LocalizedError {
    case notSignedIn
    case tokenExpired
    case refreshInProgress
    case credentialsNotSaved
    case throttled(retryAfter: Date?)
    case network(String)
    case httpStatus(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "No Claude Code session. Run `claude`, then `/login`."
        case .tokenExpired:
            return "Claude Code sign-in expired. Run `claude`, then `/login`."
        case .refreshInProgress:
            return "Claude Code is refreshing its sign-in. Retrying shortly."
        case .credentialsNotSaved:
            return "Could not save the refreshed Claude Code sign-in."
        case .throttled:
            return "Claude usage endpoint is rate limited. Waiting before retrying."
        case .network(let message):
            return "Network error: \(message)"
        case .httpStatus(let code):
            return "Claude returned HTTP \(code). Open Claude Code to refresh the session."
        case .decoding(let message):
            return "Unreadable Claude response: \(message)"
        }
    }
}

actor ClaudeUsageService {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"
    private static let claudeDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")
    private static let credentialsFile = claudeDirectory.appendingPathComponent(".credentials.json")
    private static let refreshLock = ClaudeRefreshLock(claudeDirectory: claudeDirectory)
    private static let expiryMargin: TimeInterval = 60

    func fetchUsage() async throws -> (usage: ClaudeUsageResponse, credentials: ClaudeCredentials) {
        var credentials = try Self.loadStoredCredentials().credentials
        if credentials.isExpired(at: Date().addingTimeInterval(Self.expiryMargin)) {
            credentials = try await refreshCredentials()
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeUsageError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeUsageError.network("invalid response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ClaudeUsageError.tokenExpired
            }
            if http.statusCode == 429 {
                throw ClaudeUsageError.throttled(retryAfter: RetryAfter.date(from: http))
            }
            throw ClaudeUsageError.httpStatus(http.statusCode)
        }

        do {
            return (try JSONDecoder().decode(ClaudeUsageResponse.self, from: data), credentials)
        } catch {
            throw ClaudeUsageError.decoding(error.localizedDescription)
        }
    }

    private func refreshCredentials() async throws -> ClaudeCredentials {
        var hold = Self.refreshLock.acquire()
        for _ in 0..<5 where hold == nil {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            hold = Self.refreshLock.acquire()
        }
        guard let hold else { throw ClaudeUsageError.refreshInProgress }
        defer { hold.release() }

        let stored = try Self.loadStoredCredentials()
        guard stored.credentials.isExpired(at: Date().addingTimeInterval(Self.expiryMargin)) else {
            return stored.credentials
        }
        guard let refreshToken = stored.credentials.refreshToken,
              stored.source == .file || Self.keychainAccount() != nil else {
            throw ClaudeUsageError.tokenExpired
        }

        var request = URLRequest(url: ClaudeTokenRefresh.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ClaudeTokenRefresh.requestBody(
            refreshToken: refreshToken,
            scopes: stored.credentials.scopes
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeUsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeUsageError.network("invalid response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 429 {
                throw ClaudeUsageError.throttled(retryAfter: RetryAfter.date(from: http))
            }
            if [400, 401, 403].contains(http.statusCode) {
                if let current = Self.loadStoredCredentials(from: stored.source)?.credentials,
                   current.refreshToken != refreshToken,
                   !current.isExpired(at: Date().addingTimeInterval(Self.expiryMargin)) {
                    return current
                }
                throw ClaudeUsageError.tokenExpired
            }
            throw ClaudeUsageError.httpStatus(http.statusCode)
        }

        let grant: ClaudeTokenGrant
        do {
            grant = try JSONDecoder().decode(ClaudeTokenGrant.self, from: data)
        } catch {
            throw ClaudeUsageError.decoding(error.localizedDescription)
        }
        let updated = try ClaudeTokenRefresh.storedCredentials(stored.data, applying: grant, now: Date())
        guard Self.loadStoredCredentials(from: stored.source)?.credentials.refreshToken == refreshToken else {
            return try Self.loadStoredCredentials().credentials
        }
        try Self.save(updated, to: stored.source)
        return try Self.parseCredentials(updated)
    }

    private enum CredentialSource {
        case keychain
        case file
    }

    private struct StoredCredentials {
        let data: Data
        let source: CredentialSource
        let credentials: ClaudeCredentials
    }

    private struct CredentialsFile: Decodable {
        struct OAuth: Decodable {
            let accessToken: String?
            let refreshToken: String?
            let expiresAt: Double?
            let scopes: [String]?
            let subscriptionType: String?
            let rateLimitTier: String?
        }

        let claudeAiOauth: OAuth?
    }

    private static func loadStoredCredentials() throws -> StoredCredentials {
        guard let stored = loadStoredCredentials(from: .keychain) ?? loadStoredCredentials(from: .file) else {
            throw ClaudeUsageError.notSignedIn
        }
        return stored
    }

    private static func loadStoredCredentials(from source: CredentialSource) -> StoredCredentials? {
        let data: Data?
        switch source {
        case .keychain:
            data = keychainData()
        case .file:
            data = try? Data(contentsOf: credentialsFile)
        }
        guard let data, let credentials = try? parseCredentials(data) else { return nil }
        return StoredCredentials(data: data, source: source, credentials: credentials)
    }

    private static func parseCredentials(_ data: Data) throws -> ClaudeCredentials {
        guard let oauth = try? JSONDecoder().decode(CredentialsFile.self, from: data).claudeAiOauth,
              let accessToken = oauth.accessToken, !accessToken.isEmpty else {
            throw ClaudeUsageError.notSignedIn
        }
        return ClaudeCredentials(
            accessToken: accessToken,
            subscriptionType: oauth.subscriptionType,
            rateLimitTier: oauth.rateLimitTier,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            refreshToken: oauth.refreshToken,
            scopes: oauth.scopes ?? []
        )
    }

    private static func save(_ data: Data, to source: CredentialSource) throws {
        switch source {
        case .keychain:
            try saveKeychainData(data)
        case .file:
            let permissions = (try? FileManager.default.attributesOfItem(atPath: credentialsFile.path))?[.posixPermissions] ?? 0o600
            try data.write(to: credentialsFile, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: credentialsFile.path)
        }
        guard let saved = loadStoredCredentials(from: source)?.credentials,
              saved.accessToken == (try parseCredentials(data)).accessToken else {
            throw ClaudeUsageError.credentialsNotSaved
        }
    }

    private static func keychainData() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    private static func keychainAccount() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return ClaudeKeychainCommand.account(fromAttributes: String(decoding: data, as: UTF8.self))
    }

    private static func saveKeychainData(_ data: Data) throws {
        guard let account = keychainAccount() else {
            throw ClaudeUsageError.credentialsNotSaved
        }
        let invocation = ClaudeKeychainCommand.save(data, account: account, service: keychainService)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = invocation.arguments
        let input = Pipe()
        process.standardInput = invocation.input == nil ? FileHandle.nullDevice : input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ClaudeUsageError.credentialsNotSaved
        }
        if let stdin = invocation.input {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        process.waitUntilExit()
    }
}
