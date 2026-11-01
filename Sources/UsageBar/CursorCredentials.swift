import CommonCrypto
import Foundation
import Security

struct CursorCredentials: Sendable {
    enum Source: Sendable {
        case editor
        case settingsToken
    }

    let accessToken: String
    let membershipType: String?
    let source: Source

    init(accessToken: String, membershipType: String?, source: Source = .editor) {
        self.accessToken = accessToken
        self.membershipType = membershipType
        self.source = source
    }
}

struct CursorEditorLogin: Sendable {
    let accessToken: String?
    let membershipType: String?
}

struct CursorCredentialLoader: Sendable {
    var editorLogin: @Sendable () async -> CursorEditorLogin?
    var safeStoragePassword: @Sendable () async -> String?
    var settingsToken: @Sendable () async -> String?
    var now: @Sendable () -> Date
    var forgetSafeStoragePassword: @Sendable () async -> Void = {}

    static let live = CursorCredentialLoader(
        editorLogin: { await CursorEditorStore.readLogin() },
        safeStoragePassword: { await CursorSafeStorageKeychain.shared.password() },
        settingsToken: { await CursorSessionTokenStore.shared.token() },
        now: { Date() },
        forgetSafeStoragePassword: { await CursorSafeStorageKeychain.shared.forget() }
    )

    func load() async throws -> CursorCredentials {
        var sawExpiredToken = false
        var sawLockedLogin = false

        if let login = await editorLogin(), let stored = login.accessToken, !stored.isEmpty {
            if let token = await CursorSafeStorage.token(from: stored, password: safeStoragePassword) {
                if CursorJWT.isExpired(token, at: now()) {
                    sawExpiredToken = true
                } else {
                    return CursorCredentials(accessToken: token, membershipType: login.membershipType, source: .editor)
                }
            } else {
                sawLockedLogin = true
                await forgetSafeStoragePassword()
            }
        }

        if let raw = await settingsToken(), let token = CursorSessionToken.accessToken(from: raw) {
            if CursorJWT.isExpired(token, at: now()) {
                sawExpiredToken = true
            } else {
                return CursorCredentials(accessToken: token, membershipType: nil, source: .settingsToken)
            }
        }

        if sawExpiredToken { throw CursorUsageError.tokenExpired }
        if sawLockedLogin { throw CursorUsageError.unreadableLogin }
        throw CursorUsageError.notSignedIn
    }
}

enum CursorEditorStore {
    static let stateDB = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    static let accessTokenKey = "cursorAuth/accessToken"
    static let membershipKey = "cursorAuth/stripeMembershipType"

    static func readLogin(from file: URL = stateDB) async -> CursorEditorLogin? {
        guard let rows = await ReadOnlySQLite.rows(
            at: file,
            sql: "SELECT key, value FROM ItemTable WHERE key IN (?, ?)",
            bindings: [accessTokenKey, membershipKey]
        ) else {
            return nil
        }
        var values: [String: String] = [:]
        for row in rows where row.count == 2 {
            if let key = row[0], let value = row[1]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                values[key] = value
            }
        }
        return CursorEditorLogin(accessToken: values[accessTokenKey], membershipType: values[membershipKey])
    }
}

enum CursorSafeStorage {
    static let prefix = "cursor-safe-storage:v1:"
    private static let version = Data("v10".utf8)

    static func token(
        from stored: String,
        password: @Sendable () async -> String?
    ) async -> String? {
        guard stored.hasPrefix(prefix) else { return stored }
        guard let sealed = Data(base64Encoded: String(stored.dropFirst(prefix.count))),
              let secret = await password() else {
            return nil
        }
        return decrypt(sealed, password: secret)
    }

    static func decrypt(_ sealed: Data, password: String) -> String? {
        guard sealed.starts(with: version) else { return nil }
        let cipherText = sealed.dropFirst(version.count)
        guard !cipherText.isEmpty, cipherText.count % kCCBlockSizeAES128 == 0,
              let key = derivedKey(password: password) else {
            return nil
        }
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: cipherText.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var written = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            cipherText.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress, cipherText.count,
                            outputBytes.baseAddress, outputCapacity,
                            &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        let token = String(data: output.prefix(written), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }

    static func derivedKey(password: String) -> Data? {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyCount = key.count
        let status = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, password.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    keyBytes.bindMemory(to: UInt8.self).baseAddress, keyCount
                )
            }
        }
        return status == kCCSuccess ? key : nil
    }
}

actor CursorSafeStorageKeychain {
    static let shared = CursorSafeStorageKeychain()
    static let service = "Cursor Safe Storage"
    static let account = "Cursor"
    private static let readTimeout: TimeInterval = 30
    private static let retryDelay: TimeInterval = 60 * 60

    private let read: @Sendable () -> String?
    private let now: @Sendable () -> Date
    private var cached: String?
    private var failedAt: Date?
    private var pending: Task<String?, Never>?

    init(read: @escaping @Sendable () -> String? = { readItem() }, now: @escaping @Sendable () -> Date = { Date() }) {
        self.read = read
        self.now = now
    }

    func password() async -> String? {
        if let cached { return cached }
        if let failedAt, now().timeIntervalSince(failedAt) < Self.retryDelay { return nil }
        let read = read
        let task = pending ?? Task {
            await ProviderIO.runBlocking(timeout: Self.readTimeout) { read() }
        }
        pending = task
        let value = await task.value
        pending = nil
        if let value, !value.isEmpty {
            cached = value
            failedAt = nil
        } else {
            failedAt = now()
        }
        return cached
    }

    func forget() {
        guard cached != nil else { return }
        cached = nil
        failedAt = now()
    }

    private static func readItem() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
    }
}

enum CursorSessionToken {
    static func accessToken(from raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "WorkosCursorSessionToken=") {
            value = String(value[range.upperBound...])
            if let end = value.firstIndex(of: ";") {
                value = String(value[..<end])
            }
        }
        value = value.removingPercentEncoding ?? value
        if let range = value.range(of: "::", options: .backwards) {
            value = String(value[range.upperBound...])
        }
        if value.lowercased().hasPrefix("bearer ") {
            value = String(value.dropFirst("bearer ".count))
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else { return nil }
        return value
    }
}

enum CursorJWT {
    static func isExpired(_ token: String, at date: Date) -> Bool {
        guard let expiry = expiry(of: token) else { return false }
        return expiry <= date
    }

    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (object["exp"] as? NSNumber)?.doubleValue, exp.isFinite, exp > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }
}

actor CursorSessionTokenStore {
    static let shared = CursorSessionTokenStore()
    static let service = "com.usagebar.app.cursor-session-token"
    static let account = "cursor"
    private static let readTimeout: TimeInterval = 30
    private static let retryDelay: TimeInterval = 60 * 60

    private let read: @Sendable () -> String?
    private let now: @Sendable () -> Date
    private var loaded = false
    private var cached: String?
    private var failedAt: Date?
    private var pending: Task<String?, Never>?

    init(read: @escaping @Sendable () -> String? = { readItem() }, now: @escaping @Sendable () -> Date = { Date() }) {
        self.read = read
        self.now = now
    }

    func token() async -> String? {
        if loaded { return cached }
        if let failedAt, now().timeIntervalSince(failedAt) < Self.retryDelay { return nil }
        let read = read
        let task = pending ?? Task {
            await ProviderIO.runBlocking(timeout: Self.readTimeout) { read() }
        }
        pending = task
        let value = await task.value
        pending = nil
        if let value {
            cached = value.isEmpty ? nil : value
            loaded = true
            failedAt = nil
        } else {
            failedAt = now()
        }
        return cached
    }

    func save(_ raw: String) async -> Bool {
        guard let token = CursorSessionToken.accessToken(from: raw) else { return false }
        let saved = await ProviderIO.runBlocking(timeout: Self.readTimeout) { Self.writeItem(token) } ?? false
        if saved {
            cached = token
            loaded = true
            failedAt = nil
        }
        return saved
    }

    func remove() async -> Bool {
        let removed = await ProviderIO.runBlocking(timeout: Self.readTimeout) { Self.deleteItem() } ?? false
        if removed {
            cached = nil
            loaded = true
            failedAt = nil
        }
        return removed
    }

    func hasToken() async -> Bool {
        if loaded { return cached != nil }
        return await ProviderIO.runBlocking(timeout: 5) { Self.itemExists() } ?? false
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readItem() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func itemExists() -> Bool {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func writeItem(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let update = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = baseQuery()
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Usage Bar Cursor session token"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteItem() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
