import Foundation

struct ClaudeCredentials: Equatable {
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
        return multiplier == "20x" ? "Ultra" : "max_\(multiplier)"
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

enum ClaudeCredentialSource: Hashable, Sendable {
    case keychain
    case file
}

protocol ClaudeCredentialStorage: Sendable {
    func read(_ source: ClaudeCredentialSource) async throws -> Data?
    func canWrite(_ data: Data, to source: ClaudeCredentialSource) async throws -> Bool
    func write(_ data: Data, to source: ClaudeCredentialSource) async throws
}

typealias ClaudeTokenExchange = @Sendable (URLRequest) async throws -> (Data, URLResponse)

struct SystemClaudeCredentialStorage: ClaudeCredentialStorage {
    static let claudeDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")

    var keychain = ClaudeKeychain.system
    var fileURL = claudeDirectory.appendingPathComponent(".credentials.json")

    func read(_ source: ClaudeCredentialSource) async throws -> Data? {
        switch source {
        case .keychain:
            return try await keychain.read()
        case .file:
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return try Data(contentsOf: fileURL)
        }
    }

    func canWrite(_ data: Data, to source: ClaudeCredentialSource) async throws -> Bool {
        switch source {
        case .keychain:
            return try await keychain.saveCommand(for: data) != nil
        case .file:
            return true
        }
    }

    func write(_ data: Data, to source: ClaudeCredentialSource) async throws {
        switch source {
        case .keychain:
            try await keychain.write(data)
        case .file:
            try writeFile(data)
        }
    }

    private func writeFile(_ data: Data) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600
        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(permissions))
        guard descriptor >= 0 else { throw ClaudeUsageError.credentialsNotSaved }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, fileURL.path) == 0 else { throw ClaudeUsageError.credentialsNotSaved }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw ClaudeUsageError.credentialsNotSaved
        }
    }
}

actor ClaudeCredentialStore {
    static let expiryMargin: TimeInterval = 60
    static let writeAttempts = 2

    private struct StoredCredentials {
        let data: Data
        let source: ClaudeCredentialSource
        let credentials: ClaudeCredentials
    }

    private struct UnsavedGrant {
        let grant: ClaudeTokenGrant
        let grantedAt: Date
        let source: ClaudeCredentialSource
        let usedRefreshToken: String
        let replacedRefreshToken: String?
        let credentials: ClaudeCredentials
    }

    private enum Flight {
        case refresh(rejectedAccessToken: String?)
        case save
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

    private let storage: ClaudeCredentialStorage
    private let exchange: ClaudeTokenExchange
    private let lock: ClaudeRefreshLock
    private let lockAttempts: Int
    private let lockRetryDelay: UInt64
    private let now: @Sendable () -> Date
    private var flight: Task<ClaudeCredentials, Error>?
    private var unsaved: UnsavedGrant?

    init(
        storage: ClaudeCredentialStorage = SystemClaudeCredentialStorage(),
        exchange: @escaping ClaudeTokenExchange = ClaudeTokenRefresh.exchange,
        lock: ClaudeRefreshLock = ClaudeRefreshLock(claudeDirectory: SystemClaudeCredentialStorage.claudeDirectory),
        lockAttempts: Int = 6,
        lockRetryDelay: UInt64 = 1_000_000_000,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storage = storage
        self.exchange = exchange
        self.lock = lock
        self.lockAttempts = lockAttempts
        self.lockRetryDelay = lockRetryDelay
        self.now = now
    }

    func usableCredentials() async throws -> ClaudeCredentials {
        let current = try await currentCredentials()
        if isStale(current, rejectedAccessToken: nil) {
            return try await join(.refresh(rejectedAccessToken: nil))
        }
        if unsaved != nil {
            return (try? await join(.save)) ?? current
        }
        return current
    }

    func credentialsAfterRejection(of rejected: ClaudeCredentials) async throws -> ClaudeCredentials {
        let current = try await currentCredentials()
        guard isStale(current, rejectedAccessToken: rejected.accessToken) else {
            return current
        }
        return try await join(.refresh(rejectedAccessToken: rejected.accessToken))
    }

    private func join(_ next: Flight) async throws -> ClaudeCredentials {
        if let flight {
            return try await flight.value
        }
        let task = Task { try await self.fly(next) }
        flight = task
        defer { flight = nil }
        return try await task.value
    }

    private func fly(_ next: Flight) async throws -> ClaudeCredentials {
        let hold = try await acquireLock()
        defer { hold.release() }

        let stored = try await loadStored()
        let current = effectiveCredentials(stored)
        switch next {
        case .save:
            guard let unsaved else { return current }
            return try await commit(
                unsaved.grant,
                grantedAt: unsaved.grantedAt,
                usedRefreshToken: unsaved.usedRefreshToken,
                replacing: unsaved.replacedRefreshToken,
                into: stored
            )
        case .refresh(let rejectedAccessToken):
            guard isStale(current, rejectedAccessToken: rejectedAccessToken) else { return current }
            return try await refresh(current, stored: stored)
        }
    }

    private func refresh(_ current: ClaudeCredentials, stored: StoredCredentials) async throws -> ClaudeCredentials {
        guard let refreshToken = current.refreshToken else {
            throw ClaudeUsageError.tokenExpired
        }
        let replaced = unsaved?.replacedRefreshToken ?? stored.credentials.refreshToken
        let probe = try Self.writeProbe(for: stored.data, current: current, now: now())
        guard try await storage.canWrite(probe, to: stored.source) else {
            throw ClaudeUsageError.credentialsNotSaved
        }

        let request = try ClaudeTokenRefresh.request(refreshToken: refreshToken, scopes: current.scopes)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await exchange(request)
        } catch {
            throw ClaudeUsageError(transportError: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeUsageError.network
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 429 {
                throw ClaudeUsageError.server
            }
            if [400, 401, 403].contains(http.statusCode) {
                unsaved = nil
                if let latest = try? await read(stored.source),
                   isNewer(latest.credentials, than: refreshToken, replacing: replaced) {
                    return latest.credentials
                }
                throw ClaudeUsageError.tokenExpired
            }
            throw ClaudeUsageError.server
        }

        let grant: ClaudeTokenGrant
        do {
            grant = try JSONDecoder().decode(ClaudeTokenGrant.self, from: data)
        } catch {
            throw ClaudeUsageError.decoding
        }
        return try await commit(
            grant,
            grantedAt: now(),
            usedRefreshToken: refreshToken,
            replacing: replaced,
            into: stored
        )
    }

    private func commit(
        _ grant: ClaudeTokenGrant,
        grantedAt: Date,
        usedRefreshToken: String,
        replacing replaced: String?,
        into stored: StoredCredentials
    ) async throws -> ClaudeCredentials {
        var latestData = stored.data
        for attempt in 0...Self.writeAttempts {
            let fresh: StoredCredentials?
            do {
                fresh = try await read(stored.source)
            } catch {
                continue
            }
            guard let fresh else {
                unsaved = nil
                throw ClaudeUsageError.notSignedIn
            }
            if fresh.credentials.accessToken == grant.accessToken
                || isNewer(fresh.credentials, than: usedRefreshToken, replacing: replaced) {
                unsaved = nil
                return fresh.credentials
            }
            latestData = fresh.data
            guard attempt < Self.writeAttempts else { break }
            let updated = try ClaudeTokenRefresh.storedCredentials(fresh.data, applying: grant, now: grantedAt)
            try? await storage.write(updated, to: stored.source)
        }

        let credentials = try Self.parse(
            ClaudeTokenRefresh.storedCredentials(latestData, applying: grant, now: grantedAt)
        )
        unsaved = UnsavedGrant(
            grant: grant,
            grantedAt: grantedAt,
            source: stored.source,
            usedRefreshToken: usedRefreshToken,
            replacedRefreshToken: replaced,
            credentials: credentials
        )
        return credentials
    }

    private func isStale(_ credentials: ClaudeCredentials, rejectedAccessToken: String?) -> Bool {
        credentials.accessToken == rejectedAccessToken
            || credentials.isExpired(at: now().addingTimeInterval(Self.expiryMargin))
    }

    private func isNewer(_ credentials: ClaudeCredentials, than used: String, replacing replaced: String?) -> Bool {
        credentials.refreshToken != used
            && credentials.refreshToken != replaced
            && !isStale(credentials, rejectedAccessToken: nil)
    }

    func currentCredentials() async throws -> ClaudeCredentials {
        do {
            return effectiveCredentials(try await loadStored())
        } catch ClaudeUsageError.notSignedIn {
            unsaved = nil
            throw ClaudeUsageError.notSignedIn
        } catch {
            if let unsaved { return unsaved.credentials }
            throw error
        }
    }

    private func effectiveCredentials(_ stored: StoredCredentials) -> ClaudeCredentials {
        guard let pending = unsaved else { return stored.credentials }
        guard pending.source == stored.source,
              pending.replacedRefreshToken == stored.credentials.refreshToken else {
            unsaved = nil
            return stored.credentials
        }
        return pending.credentials
    }

    private func acquireLock() async throws -> ClaudeRefreshLock.Hold {
        for attempt in 0..<lockAttempts {
            if let hold = lock.acquire() { return hold }
            if attempt + 1 < lockAttempts {
                try? await Task.sleep(nanoseconds: lockRetryDelay)
            }
        }
        throw ClaudeUsageError.refreshInProgress
    }

    private func loadStored() async throws -> StoredCredentials {
        if let keychain = try await read(.keychain) {
            return keychain
        }
        guard let file = try? await read(.file) else {
            throw ClaudeUsageError.notSignedIn
        }
        return file
    }

    private func read(_ source: ClaudeCredentialSource) async throws -> StoredCredentials? {
        guard let data = try await storage.read(source),
              let credentials = try? Self.parse(data) else {
            return nil
        }
        return StoredCredentials(data: data, source: source, credentials: credentials)
    }

    private static func writeProbe(for data: Data, current: ClaudeCredentials, now: Date) throws -> Data {
        let padding = 128
        let lifetime: TimeInterval = 365 * 24 * 3600
        let probe = ClaudeTokenGrant(
            accessToken: String(repeating: "x", count: current.accessToken.count + padding),
            refreshToken: String(repeating: "x", count: (current.refreshToken?.count ?? 0) + padding),
            expiresIn: lifetime,
            refreshTokenExpiresIn: lifetime,
            scope: (current.scopes.isEmpty ? ClaudeTokenRefresh.defaultScopes : current.scopes).joined(separator: " ")
        )
        return try ClaudeTokenRefresh.storedCredentials(data, applying: probe, now: now)
    }

    private static func parse(_ data: Data) throws -> ClaudeCredentials {
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
}
