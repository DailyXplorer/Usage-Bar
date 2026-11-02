import Foundation

struct UsageSnapshot: Codable {
    var codexBuckets: [LimitBucket] = []
    var codexPlan: String?
    var claudeBuckets: [LimitBucket] = []
    var claudePlan: String?
    var cursorBuckets: [LimitBucket] = []
    var cursorPlan: String?
    var opencodeBuckets: [LimitBucket] = []
    var opencodePlan: String?
    var commandcodeBuckets: [LimitBucket] = []
    var commandcodePlan: String?
    var refreshStates: [String: UsageRefreshState] = [:]
    var fetchedAt: Date

    private enum CodingKeys: String, CodingKey {
        case codexBuckets, codexPlan, claudeBuckets, claudePlan
        case cursorBuckets, cursorPlan, opencodeBuckets, opencodePlan
        case commandcodeBuckets, commandcodePlan, fetchedAt, refreshStates
    }

    init(
        codexBuckets: [LimitBucket] = [],
        codexPlan: String? = nil,
        claudeBuckets: [LimitBucket] = [],
        claudePlan: String? = nil,
        cursorBuckets: [LimitBucket] = [],
        cursorPlan: String? = nil,
        opencodeBuckets: [LimitBucket] = [],
        opencodePlan: String? = nil,
        commandcodeBuckets: [LimitBucket] = [],
        commandcodePlan: String? = nil,
        fetchedAt: Date,
        refreshStates: [String: UsageRefreshState] = [:]
    ) {
        self.codexBuckets = codexBuckets
        self.codexPlan = codexPlan
        self.claudeBuckets = claudeBuckets
        self.claudePlan = claudePlan
        self.cursorBuckets = cursorBuckets
        self.cursorPlan = cursorPlan
        self.opencodeBuckets = opencodeBuckets
        self.opencodePlan = opencodePlan
        self.commandcodeBuckets = commandcodeBuckets
        self.commandcodePlan = commandcodePlan
        self.fetchedAt = fetchedAt
        self.refreshStates = refreshStates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codexBuckets = container.lenientBuckets(forKey: .codexBuckets)
        codexPlan = try? container.decodeIfPresent(String.self, forKey: .codexPlan)
        claudeBuckets = container.lenientBuckets(forKey: .claudeBuckets)
        claudePlan = try? container.decodeIfPresent(String.self, forKey: .claudePlan)
        cursorBuckets = container.lenientBuckets(forKey: .cursorBuckets)
        cursorPlan = try? container.decodeIfPresent(String.self, forKey: .cursorPlan)
        opencodeBuckets = container.lenientBuckets(forKey: .opencodeBuckets)
        opencodePlan = try? container.decodeIfPresent(String.self, forKey: .opencodePlan)
        commandcodeBuckets = container.lenientBuckets(forKey: .commandcodeBuckets)
        commandcodePlan = try? container.decodeIfPresent(String.self, forKey: .commandcodePlan)
        fetchedAt = (try? container.decode(Date.self, forKey: .fetchedAt)) ?? .distantPast
        let states = try? container.decodeIfPresent([String: Lenient<UsageRefreshState>].self, forKey: .refreshStates)
        refreshStates = (states ?? [:]).compactMapValues(\.value)
    }

    func refreshed(now: Date = Date()) -> UsageSnapshot {
        var copy = self
        copy.codexBuckets = Self.current(codexBuckets.map(CodexLimits.relabeled), now: now)
        copy.claudeBuckets = Self.current(claudeBuckets.map(ClaudeLimits.relabeled), now: now)
        copy.cursorBuckets = Self.current(cursorBuckets, now: now)
        copy.opencodeBuckets = Self.current(opencodeBuckets.map(OpenCodeLimits.relabeled), now: now)
        copy.opencodePlan = OpenCodeLimits.plan(for: copy.opencodeBuckets)
        copy.commandcodeBuckets = Self.current(commandcodeBuckets.map(CommandCodeLimits.relabeled), now: now)
        copy.refreshStates = refreshStates.mapValues { $0.restored(now: now) }
        return copy
    }

    static func current(_ buckets: [LimitBucket], now: Date) -> [LimitBucket] {
        buckets
            .filter { bucket in
                guard let resetAt = bucket.resetAt else { return true }
                let window = TimeInterval(bucket.limitWindowSeconds ?? 0)
                return now.timeIntervalSince(resetAt) <= max(window, 24 * 60 * 60)
            }
            .map { $0.recountingReset(from: now) }
    }
}

struct ProviderPreferences: Equatable {
    static let popoverKey = "popoverProviders"
    static let menuBarKey = "menuBarProviders"
    static let fallbackProviders: Set<LimitBucket.Provider> = [.codex, .claude]

    var popover: Set<LimitBucket.Provider>
    var menuBar: Set<LimitBucket.Provider>

    static func load(
        from defaults: UserDefaults = .standard,
        detected: () -> Set<LimitBucket.Provider> = ProviderCredentialDetector.detected
    ) -> ProviderPreferences {
        let storedMenuBar = providers(defaults.array(forKey: menuBarKey))
        let storedPopover = providers(defaults.array(forKey: popoverKey))
        var preferences: ProviderPreferences
        switch (storedPopover, storedMenuBar) {
        case let (popover?, menuBar?):
            preferences = ProviderPreferences(popover: popover, menuBar: menuBar)
        case let (popover?, nil):
            preferences = ProviderPreferences(popover: popover, menuBar: popover)
        case let (nil, menuBar?):
            preferences = ProviderPreferences(popover: menuBar.union(detected()), menuBar: menuBar)
        case (nil, nil):
            let found = detected()
            let initial = found.isEmpty ? fallbackProviders : found
            preferences = ProviderPreferences(popover: initial, menuBar: initial)
        }
        preferences.normalize()
        if storedPopover == nil || storedMenuBar == nil || preferences.popover != storedPopover
            || preferences.menuBar != storedMenuBar {
            preferences.save(to: defaults)
        }
        return preferences
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(Self.ordered(popover), forKey: Self.popoverKey)
        defaults.set(Self.ordered(menuBar), forKey: Self.menuBarKey)
    }

    mutating func setPopover(_ provider: LimitBucket.Provider, visible: Bool) {
        if visible {
            popover.insert(provider)
        } else {
            popover.remove(provider)
            menuBar.remove(provider)
        }
        normalize()
    }

    mutating func setMenuBar(_ provider: LimitBucket.Provider, visible: Bool) {
        if visible {
            menuBar.insert(provider)
            popover.insert(provider)
        } else {
            menuBar.remove(provider)
        }
        normalize()
    }

    private mutating func normalize() {
        menuBar.formIntersection(popover)
        if menuBar.isEmpty {
            let first = LimitBucket.Provider.allCases.first { popover.contains($0) }
            menuBar = first.map { [$0] } ?? Self.fallbackProviders
        }
        popover.formUnion(menuBar)
    }

    private static func providers(_ raw: [Any]?) -> Set<LimitBucket.Provider>? {
        guard let raw = raw as? [String] else { return nil }
        let parsed = Set(raw.compactMap(LimitBucket.Provider.init(rawValue:)))
        return parsed.isEmpty ? nil : parsed
    }

    private static func ordered(_ providers: Set<LimitBucket.Provider>) -> [String] {
        LimitBucket.Provider.allCases.filter { providers.contains($0) }.map(\.rawValue)
    }
}

enum ProviderCredentialDetector {
    static func detected() -> Set<LimitBucket.Provider> {
        detected(home: FileManager.default.homeDirectoryForCurrentUser, environment: ProcessInfo.processInfo.environment)
    }

    static func detected(home: URL, environment: [String: String]) -> Set<LimitBucket.Provider> {
        let exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
        var found: Set<LimitBucket.Provider> = []
        var codexFiles = [home.appendingPathComponent(".codex/auth.json")]
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            codexFiles.insert(URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json"), at: 0)
        }
        if codexFiles.contains(where: exists) { found.insert(.codex) }
        if [home.appendingPathComponent(".claude/.credentials.json"), home.appendingPathComponent(".claude.json")]
            .contains(where: exists) {
            found.insert(.claude)
        }
        if exists(home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")) {
            found.insert(.cursor)
        }
        if OpenCodeUsageService.authFileCandidates(home: home, environment: environment).contains(where: exists) {
            found.insert(.opencode)
        }
        let commandCodeKey = ["COMMAND_CODE_API_KEY", "COMMANDCODE_API_KEY"].contains {
            !(environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        if commandCodeKey || CommandCodeUsageService.authFileCandidates(home: home).contains(where: exists) {
            found.insert(.commandcode)
        }
        return found
    }
}

enum UsageSnapshotStore {
    private static let key = "lastUsageSnapshot"

    static func load(from defaults: UserDefaults = .standard) -> UsageSnapshot? {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data) else {
            return nil
        }
        return snapshot
    }

    static func save(_ snapshot: UsageSnapshot, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}

struct ThrottleBackoff: Codable {
    static let steps: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 60 * 60]
    static let maximumPause: TimeInterval = 60 * 60

    private(set) var attempt = 0
    private(set) var blockedUntil: Date?
    private(set) var scope: String?

    private enum CodingKeys: String, CodingKey {
        case attempt, blockedUntil, scope
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attempt = max(0, (try? container.decodeIfPresent(Int.self, forKey: .attempt)) ?? 0)
        blockedUntil = try? container.decodeIfPresent(Date.self, forKey: .blockedUntil)
        scope = try? container.decodeIfPresent(String.self, forKey: .scope)
    }

    var isBlocked: Bool {
        guard let blockedUntil else { return false }
        return blockedUntil > Date()
    }

    mutating func recordThrottle(now: Date = Date(), retryAfter: Date? = nil, scope: String? = nil) {
        let step = max(0, min(attempt, Self.steps.count - 1))
        attempt = step + 1
        let pause: TimeInterval
        if let retryAfter, retryAfter.timeIntervalSince(now) >= 1 {
            pause = retryAfter.timeIntervalSince(now)
        } else {
            pause = Self.steps[step]
        }
        let requested = max(now.addingTimeInterval(pause), blockedUntil ?? .distantPast)
        blockedUntil = min(requested, now.addingTimeInterval(Self.maximumPause))
        self.scope = scope
    }

    mutating func reset() {
        attempt = 0
        blockedUntil = nil
        scope = nil
    }

    func capped(now: Date) -> ThrottleBackoff {
        guard let blockedUntil, blockedUntil.timeIntervalSince(now) > Self.maximumPause else { return self }
        var copy = self
        copy.blockedUntil = now.addingTimeInterval(Self.maximumPause)
        return copy
    }
}

extension KeyedDecodingContainer {
    func lenientBuckets(forKey key: Key) -> [LimitBucket] {
        let buckets = try? decodeIfPresent([Lenient<LimitBucket>].self, forKey: key)
        return (buckets ?? []).compactMap(\.value)
    }
}
