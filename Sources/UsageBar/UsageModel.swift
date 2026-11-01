import Foundation
import SwiftUI

@MainActor
final class UsageModel: ObservableObject {
    static let claudeQuotaCheckKey = "claudeQuotaCheck"
    static let wakeGrace: TimeInterval = 60

    @Published private(set) var buckets: [LimitBucket] = [] {
        didSet { scheduleResetRedraw() }
    }
    @Published private(set) var planType: String?
    @Published private(set) var reached: Bool = false
    @Published private(set) var resetCredits: Int = 0
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published var menuPresented = false

    @Published private(set) var claudeBuckets: [LimitBucket] = [] {
        didSet { scheduleResetRedraw() }
    }
    @Published private(set) var claudePlan: String?
    @Published private(set) var claudeErrorMessage: String?
    @Published private(set) var claudeAvailable = false
    @Published var claudeQuotaCheckEnabled: Bool {
        didSet {
            defaults.set(claudeQuotaCheckEnabled, forKey: Self.claudeQuotaCheckKey)
            if claudeQuotaCheckEnabled, started {
                refreshNow()
            }
        }
    }

    @Published private(set) var cursorBuckets: [LimitBucket] = [] {
        didSet { scheduleResetRedraw() }
    }
    @Published private(set) var cursorPlan: String?
    @Published private(set) var cursorErrorMessage: String?
    @Published private(set) var cursorAvailable = false
    @Published private(set) var cursorNotice: String?

    @Published private(set) var opencodeBuckets: [LimitBucket] = [] {
        didSet { scheduleResetRedraw() }
    }
    @Published private(set) var opencodePlan: String?
    @Published private(set) var opencodeErrorMessage: String?
    @Published private(set) var opencodeAvailable = false

    @Published private(set) var commandcodeBuckets: [LimitBucket] = [] {
        didSet { scheduleResetRedraw() }
    }
    @Published private(set) var commandcodePlan: String?
    @Published private(set) var commandcodeErrorMessage: String?
    @Published private(set) var commandcodeAvailable = false

    @Published private(set) var providers: ProviderPreferences

    @Published private(set) var refreshStates: [UsageEndpoint: UsageRefreshState] = [:]

    var menuBarProviders: Set<LimitBucket.Provider> {
        providers.menuBar
    }

    var popoverProviders: Set<LimitBucket.Provider> {
        providers.popover
    }

    private struct Request {
        let id: UUID
        let task: Task<Void, Never>
    }

    private enum RefreshTrigger {
        case scheduled, opened, manual
    }

    private let fetcher: UsageFetcher
    private let now: () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var snapshotDate: Date?
    private let automaticallySchedules: Bool
    private let defaults: UserDefaults
    private var refreshTask: Task<Void, Never>?
    private var resetRedraw: Task<Void, Never>?
    private var requests: [UsageEndpoint: Request] = [:]
    private var started = false
    private var sleeping = false
    private var networkAvailable = true
    private var wokeAt: Date?
    private var claudeAccountKey: String?

    init(
        defaults: UserDefaults = .standard,
        fetcher: UsageFetcher = .live,
        now: @escaping () -> Date = Date.init,
        automaticallySchedules: Bool = true,
        detectedProviders: @escaping () -> Set<LimitBucket.Provider> = ProviderCredentialDetector.detected,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    ) {
        self.defaults = defaults
        self.fetcher = fetcher
        self.now = now
        self.sleep = sleep
        self.automaticallySchedules = automaticallySchedules
        providers = ProviderPreferences.load(from: defaults, detected: detectedProviders)
        claudeQuotaCheckEnabled = defaults.bool(forKey: Self.claudeQuotaCheckKey)
        restoreSnapshot()
    }

    private func restoreSnapshot() {
        guard let snapshot = UsageSnapshotStore.load(from: defaults)?.refreshed(now: now()) else { return }
        snapshotDate = snapshot.fetchedAt
        buckets = snapshot.codexBuckets
        planType = snapshot.codexPlan
        claudeBuckets = snapshot.claudeBuckets
        claudePlan = snapshot.claudePlan
        claudeAvailable = !snapshot.claudeBuckets.isEmpty
        cursorBuckets = snapshot.cursorBuckets
        cursorPlan = snapshot.cursorPlan
        cursorAvailable = !snapshot.cursorBuckets.isEmpty
        opencodeBuckets = snapshot.opencodeBuckets
        opencodePlan = snapshot.opencodePlan
        opencodeAvailable = !snapshot.opencodeBuckets.isEmpty
        commandcodeBuckets = snapshot.commandcodeBuckets
        commandcodePlan = snapshot.commandcodePlan
        commandcodeAvailable = !snapshot.commandcodeBuckets.isEmpty
        refreshStates = Dictionary(uniqueKeysWithValues: snapshot.refreshStates.compactMap { key, value in
            UsageEndpoint(rawValue: key).map { ($0, value) }
        })
        claudeAccountKey = refreshStates[.claude]?.backoff.scope
        updateLastUpdated()
        errorMessage = refreshStates[.codex]?.lastError
        claudeErrorMessage = refreshStates[.claude]?.lastError
        cursorErrorMessage = refreshStates[.cursor]?.lastError
        opencodeErrorMessage = refreshStates[.opencode]?.lastError
        commandcodeErrorMessage = refreshStates[.commandcode]?.lastError
        UsageSnapshotStore.save(snapshot, to: defaults)
    }

    private func persistSnapshot() {
        let fetchedAt = refreshStates.values.compactMap(\.lastSuccess).max() ?? snapshotDate ?? .distantPast
        snapshotDate = fetchedAt
        UsageSnapshotStore.save(
            UsageSnapshot(
                codexBuckets: buckets,
                codexPlan: planType,
                claudeBuckets: claudeBuckets,
                claudePlan: claudePlan,
                cursorBuckets: cursorBuckets,
                cursorPlan: cursorPlan,
                opencodeBuckets: opencodeBuckets,
                opencodePlan: opencodePlan,
                commandcodeBuckets: commandcodeBuckets,
                commandcodePlan: commandcodePlan,
                fetchedAt: fetchedAt,
                refreshStates: Dictionary(uniqueKeysWithValues: refreshStates.map { ($0.key.rawValue, $0.value) })
            ),
            to: defaults
        )
    }

    var canHideMenuBarProvider: Bool {
        providers.menuBar.count > 1
    }

    func isVisibleInMenuBar(_ provider: LimitBucket.Provider) -> Bool {
        providers.menuBar.contains(provider)
    }

    func isVisibleInPopover(_ provider: LimitBucket.Provider) -> Bool {
        providers.popover.contains(provider)
    }

    func canHideFromMenuBar(_ provider: LimitBucket.Provider) -> Bool {
        !isVisibleInMenuBar(provider) || canHideMenuBarProvider
    }

    func canHideFromPopover(_ provider: LimitBucket.Provider) -> Bool {
        guard isVisibleInPopover(provider) else { return true }
        return providers.popover.count > 1 && canHideFromMenuBar(provider)
    }

    func setVisibleInMenuBar(_ provider: LimitBucket.Provider, visible: Bool) {
        guard visible || canHideFromMenuBar(provider) else { return }
        var next = providers
        next.setMenuBar(provider, visible: visible)
        apply(next)
    }

    func setVisibleInPopover(_ provider: LimitBucket.Provider, visible: Bool) {
        guard visible || canHideFromPopover(provider) else { return }
        var next = providers
        next.setPopover(provider, visible: visible)
        apply(next)
    }

    private func apply(_ next: ProviderPreferences) {
        guard next != providers else { return }
        let added = next.popover.subtracting(providers.popover)
        providers = next
        next.save(to: defaults)
        updateLastUpdated()
        if started, !added.isEmpty {
            refresh(endpoints: UsageEndpoint.allCases.filter { added.contains($0.provider) }, trigger: .manual)
        }
        scheduleNextRefresh()
        scheduleResetRedraw()
    }

#if DEBUG
    init(
        previewBuckets: [LimitBucket],
        planType: String,
        lastUpdated: Date,
        claudeBuckets: [LimitBucket] = [],
        claudePlan: String? = nil,
        cursorBuckets: [LimitBucket] = [],
        cursorPlan: String? = nil,
        opencodeBuckets: [LimitBucket] = [],
        opencodePlan: String? = nil,
        commandcodeBuckets: [LimitBucket] = [],
        commandcodePlan: String? = nil,
        menuBarProviders: Set<LimitBucket.Provider> = [.codex, .claude],
        popoverProviders: Set<LimitBucket.Provider>? = nil,
        defaults: UserDefaults = .standard,
        errorMessage: String? = nil,
        cursorAvailable: Bool? = nil,
        opencodeAvailable: Bool? = nil,
        commandcodeAvailable: Bool? = nil,
        claudePausedUntil: Date? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        fetcher = .live
        self.now = now
        sleep = { delay in
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        automaticallySchedules = true
        claudeQuotaCheckEnabled = false
        buckets = previewBuckets
        self.planType = planType
        self.lastUpdated = lastUpdated
        self.claudeBuckets = claudeBuckets
        self.claudePlan = claudePlan
        claudeAvailable = !claudeBuckets.isEmpty
        self.cursorBuckets = cursorBuckets
        self.cursorPlan = cursorPlan
        self.cursorAvailable = cursorAvailable ?? !cursorBuckets.isEmpty
        self.opencodeBuckets = opencodeBuckets
        self.opencodePlan = opencodePlan
        self.opencodeAvailable = opencodeAvailable ?? !opencodeBuckets.isEmpty
        self.commandcodeBuckets = commandcodeBuckets
        self.commandcodePlan = commandcodePlan
        self.commandcodeAvailable = commandcodeAvailable ?? !commandcodeBuckets.isEmpty
        providers = ProviderPreferences(
            popover: (popoverProviders ?? menuBarProviders).union(menuBarProviders),
            menuBar: menuBarProviders
        )
        self.errorMessage = errorMessage
        for endpoint in UsageEndpoint.allCases where endpoint != .claudeWhilePaused {
            var state = UsageRefreshState()
            state.succeed(at: lastUpdated, interval: endpoint.policy.interval)
            refreshStates[endpoint] = state
        }
        if let claudePausedUntil {
            var state = refreshStates[.claude] ?? UsageRefreshState()
            let pausedAt = now()
            state.throttle(
                ClaudeUsageError.throttled(retryAfter: nil).localizedDescription,
                retryAfter: claudePausedUntil,
                at: pausedAt,
                interval: UsageEndpoint.claude.policy.interval
            )
            refreshStates[.claude] = state
        }
    }
#endif

    private func displayed(_ provider: LimitBucket.Provider) -> [LimitBucket] {
        let date = now()
        let fetchedAt = dataDate(for: provider)
        return buckets(for: provider).filter(\.drivesMenuBar).map { $0.resetApplied(at: date, since: fetchedAt) }
    }

    var claudeMenuBarBucket: LimitBucket? {
        let candidates = displayed(.claude)
        return candidates.first(where: \.isActive)
            ?? candidates.first { $0.kind == .session }
            ?? candidates.first { $0.kind == .weeklyAll }
            ?? candidates.filter { $0.kind == .weeklyScoped }.max { $0.usedPercent < $1.usedPercent }
            ?? candidates.first
    }

    var menuBarClaudeText: String? {
        claudeMenuBarBucket.map { "\($0.remainingPercent)%" }
    }

    var menuBarClaudeDisplay: String {
        menuBarClaudeText ?? placeholder(for: .claude)
    }

    var menuBarClaudeAccessibilityText: String? {
        guard let bucket = claudeMenuBarBucket else { return nil }
        return "Claude \(Self.windowPhrase(for: bucket)), \(bucket.remainingPercent) percent left"
    }

    private static func windowPhrase(for bucket: LimitBucket) -> String {
        switch bucket.kind {
        case .session:
            return "session limit"
        case .weeklyAll:
            return "weekly limit"
        case .weeklyScoped:
            let model = ClaudeLimits.scopedModel(fromStoredName: bucket.name)
            return model.map { "weekly \($0) limit" } ?? "weekly model limit"
        default:
            return "\(bucket.name) limit"
        }
    }

    var cursorMenuBarBucket: LimitBucket? {
        CursorLimits.menuBarBucket(in: displayed(.cursor))
    }

    var menuBarCursorText: String? {
        guard let bucket = cursorMenuBarBucket else { return nil }
        return "\(bucket.remainingPercent)%"
    }

    var menuBarCursorDisplay: String {
        menuBarCursorText ?? placeholder(for: .cursor)
    }

    var menuBarCursorAccessibilityText: String? {
        guard let bucket = cursorMenuBarBucket else { return nil }
        return CursorLimits.menuBarAccessibilityText(for: bucket)
    }

    var opencodeRolling: LimitBucket? {
        displayed(.opencode).first { $0.kind == .rolling }
    }

    var menuBarOpenCodeText: String? {
        guard let bucket = opencodeRolling else { return nil }
        return "\(bucket.remainingPercent)%"
    }

    var menuBarOpenCodeDisplay: String {
        menuBarOpenCodeText ?? placeholder(for: .opencode)
    }

    var menuBarOpenCodeAccessibilityText: String? {
        guard let bucket = opencodeRolling else { return nil }
        return "OpenCode current session, \(bucket.remainingPercent) percent left"
    }

    var showsOpenCode: Bool {
        isVisibleInMenuBar(.opencode) && (opencodeAvailable || opencodeErrorMessage != nil)
    }

    var commandcodeRolling: LimitBucket? {
        displayed(.commandcode).first { $0.kind == .rolling }
    }

    var menuBarCommandCodeText: String? {
        guard let bucket = commandcodeRolling else { return nil }
        return "\(bucket.remainingPercent)%"
    }

    var menuBarCommandCodeDisplay: String {
        menuBarCommandCodeText ?? placeholder(for: .commandcode)
    }

    var menuBarCommandCodeAccessibilityText: String? {
        guard let bucket = commandcodeRolling else { return nil }
        return "Command Code current session, \(bucket.remainingPercent) percent left"
    }

    var showsCommandCode: Bool {
        isVisibleInMenuBar(.commandcode) && (commandcodeAvailable || commandcodeErrorMessage != nil)
    }

    private func placeholder(for provider: LimitBucket.Provider) -> String {
        guard !isLoading(for: provider), buckets(for: provider).isEmpty, errorMessage(for: provider) != nil else {
            return MenuBarSegment.placeholder
        }
        return MenuBarSegment.unavailable
    }

    var menuBarSegments: [MenuBarSegment] {
        LimitBucket.Provider.allCases.compactMap { provider in
            guard providers.menuBar.contains(provider) else { return nil }
            switch provider {
            case .codex:
                return MenuBarSegment(
                    provider: .codex,
                    logo: AppTheme.codexLogo,
                    value: menuBarText
                )
            case .claude:
                return MenuBarSegment(
                    provider: .claude,
                    logo: AppTheme.claudeLogo,
                    value: menuBarClaudeDisplay
                )
            case .cursor:
                return MenuBarSegment(
                    provider: .cursor,
                    logo: AppTheme.cursorLogo,
                    value: menuBarCursorDisplay
                )
            case .opencode:
                guard showsOpenCode else { return nil }
                return MenuBarSegment(
                    provider: .opencode,
                    logo: AppTheme.opencodeLogo,
                    value: menuBarOpenCodeDisplay
                )
            case .commandcode:
                guard showsCommandCode else { return nil }
                return MenuBarSegment(
                    provider: .commandcode,
                    logo: AppTheme.commandcodeLogo,
                    value: menuBarCommandCodeDisplay
                )
            }
        }
    }

    var menuBarAccessibilityLabel: String {
        var parts: [String] = []
        if providers.menuBar.contains(.codex) {
            parts.append("Codex limits, \(menuBarAccessibilityText)")
        }
        if providers.menuBar.contains(.claude), let claude = menuBarClaudeAccessibilityText {
            parts.append(claude)
        } else if providers.menuBar.contains(.claude) {
            parts.append("Claude unavailable")
        }
        if providers.menuBar.contains(.cursor), let cursor = menuBarCursorAccessibilityText {
            parts.append(cursor)
        } else if providers.menuBar.contains(.cursor) {
            parts.append("Cursor unavailable")
        }
        if showsOpenCode, let opencode = menuBarOpenCodeAccessibilityText {
            parts.append(opencode)
        } else if showsOpenCode {
            parts.append("OpenCode unavailable")
        }
        if showsCommandCode, let commandcode = menuBarCommandCodeAccessibilityText {
            parts.append(commandcode)
        } else if showsCommandCode {
            parts.append("Command Code unavailable")
        }
        return parts.joined(separator: ". ")
    }

    var menuBarText: String {
        guard let bucket = codexMenuBarBucket else { return placeholder(for: .codex) }
        return "\(bucket.remainingPercent)%"
    }

    var menuBarAccessibilityText: String {
        guard let bucket = codexMenuBarBucket else {
            if isLoading(for: .codex) { return "loading" }
            if errorMessage != nil { return "unavailable" }
            return "not loaded"
        }
        return "\(bucket.remainingPercent) percent left"
    }

    private var codexMenuBarBucket: LimitBucket? {
        displayed(.codex)
            .filter { $0.kind == .primary || $0.kind == .secondary }
            .min { $0.remainingPercent < $1.remainingPercent }
    }

    static func color(forPercentUsed used: Int) -> Color {
        if used >= 85 {
            return .red
        }
        if used >= 60 {
            return .orange
        }
        return .green
    }

    func start() {
        guard !started else { return }
        started = true
        refreshNow()
    }

    func stop() {
        started = false
        refreshTask?.cancel()
        refreshTask = nil
        cancelRequests()
    }

    func setSleeping(_ sleeping: Bool) {
        self.sleeping = sleeping
        if sleeping {
            refreshTask?.cancel()
            refreshTask = nil
            cancelRequests()
        } else {
            wokeAt = now()
            if started {
                refreshNow()
            }
        }
    }

    func setNetworkAvailable(_ available: Bool) {
        let regained = available && !networkAvailable
        networkAvailable = available
        guard started else { return }
        if regained {
            wokeAt = now()
            refreshNow()
        } else if !available {
            scheduleNextRefresh()
        }
    }

    private func cancelRequests() {
        for request in requests.values { request.task.cancel() }
        requests.removeAll()
        isLoading = false
    }

    func refreshNow(force: Bool = false) {
        refresh(endpoints: UsageEndpoint.allCases, trigger: force ? .manual : .scheduled)
    }

    func refreshForOpenedPanel() {
        if sleeping {
            sleeping = false
            wokeAt = now()
        }
        refresh(endpoints: UsageEndpoint.allCases, trigger: .opened)
    }

    private func isEnabled(_ endpoint: UsageEndpoint, at date: Date) -> Bool {
        guard providers.popover.contains(endpoint.provider) else { return false }
        if endpoint == .claudeWhilePaused {
            return refreshStates[.claude]?.isPaused(at: date) == true
        }
        return true
    }

    private func refresh(endpoints: [UsageEndpoint], trigger: RefreshTrigger) {
        guard !sleeping, networkAvailable else { return }
        let date = now()
        for endpoint in endpoints where isEnabled(endpoint, at: date) && requests[endpoint] == nil {
            let state = refreshStates[endpoint] ?? UsageRefreshState()
            let policy = endpoint.policy
            let allowed: Bool
            switch trigger {
            case .scheduled:
                allowed = state.canStart(at: date, force: false, policy: policy)
            case .manual:
                allowed = state.canStart(at: date, force: true, policy: policy)
            case .opened:
                allowed = state.canStartOnOpen(at: date, policy: policy)
            }
            guard allowed else { continue }
            start(endpoint, at: date)
        }
        isLoading = !requests.isEmpty
        scheduleNextRefresh()
    }

    private func start(_ endpoint: UsageEndpoint, at date: Date) {
        var state = refreshStates[endpoint] ?? UsageRefreshState()
        state.begin(at: date)
        refreshStates[endpoint] = state
        let context = UsageFetchContext(
            dataDate: dataDate(for: endpoint.provider),
            claudeQuotaCheck: claudeQuotaCheckEnabled,
            claudeScopedModelName: claudeScopedModelName
        )
        let fetch = fetcher.fetch
        let id = UUID()
        let task = Task { [weak self] in
            let result: Result<UsageFetchResult, Error>
            do {
                result = .success(try await fetch(endpoint, context))
            } catch {
                result = .failure(error)
            }
            guard let self, self.requests[endpoint]?.id == id else { return }
            self.requests[endpoint] = nil
            if !Task.isCancelled {
                self.receive(result, from: endpoint)
            }
            self.isLoading = !self.requests.isEmpty
            self.scheduleNextRefresh()
        }
        requests[endpoint] = Request(id: id, task: task)
    }

    private var claudeScopedModelName: String? {
        let scoped = claudeBuckets.filter { $0.kind == .weeklyScoped }
        guard scoped.count == 1 else { return nil }
        return ClaudeLimits.scopedModel(fromStoredName: scoped[0].name)
    }

    func dataDate(for provider: LimitBucket.Provider) -> Date? {
        UsageEndpoint.allCases
            .filter { $0.provider == provider }
            .compactMap { refreshStates[$0]?.lastSuccess }
            .max()
    }

    private func scheduleResetRedraw() {
        resetRedraw?.cancel()
        resetRedraw = nil
        let date = now()
        let resetAt = LimitBucket.Provider.allCases
            .filter { providers.popover.contains($0) }
            .flatMap { buckets(for: $0) }
            .compactMap(\.resetAt)
            .filter { $0 > date }
            .min()
        guard let resetAt else { return }
        let now = now
        let sleep = sleep
        resetRedraw = Task { [weak self] in
            var remaining = resetAt.timeIntervalSince(now())
            while remaining > 0 {
                do {
                    try await sleep(min(remaining, 3600))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                remaining = resetAt.timeIntervalSince(now())
            }
            guard let self else { return }
            self.objectWillChange.send()
            self.scheduleResetRedraw()
        }
    }

    private func scheduleNextRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        guard started, automaticallySchedules, !sleeping, networkAvailable else { return }
        let date = now()
        let deadline = UsageEndpoint.allCases
            .filter { requests[$0] == nil && isEnabled($0, at: date) }
            .map { (refreshStates[$0] ?? UsageRefreshState()).nextEligible(policy: $0.policy) }
            .min()
        guard let next = deadline else { return }
        let delay = max(0.01, min(3600, next.timeIntervalSince(date)))
        let sleep = sleep
        refreshTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    private func receive(_ result: Result<UsageFetchResult, Error>, from endpoint: UsageEndpoint) {
        let date = now()
        let interval = endpoint.policy.interval
        var state = refreshStates[endpoint] ?? UsageRefreshState()
        switch result {
        case .success(let usage):
            switch usage {
            case .codex(let response):
                apply(response)
                errorMessage = nil
                state.succeed(at: date, interval: interval)
            case .claude(let fetch):
                receiveClaude(fetch, from: endpoint, state: &state, at: date)
            case .cursor(let snapshot):
                applyCursor(snapshot)
                cursorErrorMessage = nil
                state.succeed(at: date, interval: interval)
            case .opencode(let response):
                applyOpenCode(response)
                opencodeErrorMessage = nil
                state.succeed(at: date, interval: interval)
            case .commandcode(let response):
                applyCommandCode(response)
                commandcodeErrorMessage = nil
                state.succeed(at: date, interval: interval)
            }
        case .failure(let error):
            receiveFailure(error, from: endpoint, state: &state, at: date)
        }
        refreshStates[endpoint] = state
        updateLastUpdated()
        persistSnapshot()
    }

    private func receiveClaude(
        _ fetch: ClaudeFetch,
        from endpoint: UsageEndpoint,
        state: inout UsageRefreshState,
        at date: Date
    ) {
        let interval = endpoint.policy.interval
        if let key = fetch.accountKey {
            if endpoint == .claudeWhilePaused,
               let pausedFor = refreshStates[.claude]?.backoff.scope, pausedFor != key {
                var claude = refreshStates[.claude] ?? UsageRefreshState()
                claude.backoff.reset()
                claude.nextRefresh = date
                refreshStates[.claude] = claude
            }
            if let previous = claudeAccountKey, previous != key {
                claudePlan = nil
            }
            claudeAccountKey = key
        }
        if endpoint == .claude {
            claudeErrorMessage = nil
        }
        guard let usage = fetch.usage else {
            state.idle(at: date, interval: interval)
            return
        }
        let fresh = ClaudeLimits.buckets(from: usage, now: date)
        claudeAvailable = true
        claudePlan = fetch.plan ?? claudePlan
        claudeBuckets = fetch.source == .quotaCheck
            ? ClaudeLimits.merged(
                fresh: fresh,
                previous: claudeBuckets,
                now: date,
                previousFetchedAt: dataDate(for: .claude)
            )
            : fresh
        state.succeed(
            at: date,
            dataDate: fetch.dataDate,
            interval: interval,
            resetsBackoff: fetch.source == .usageEndpoint
        )
    }

    private func receiveFailure(
        _ error: Error,
        from endpoint: UsageEndpoint,
        state: inout UsageRefreshState,
        at date: Date
    ) {
        let interval = endpoint.policy.interval
        let message = error.localizedDescription
        if let retryAfter = Self.throttleRetryAfter(error) {
            let scope = endpoint == .claude ? claudeAccountKey : nil
            state.throttle(message, retryAfter: retryAfter, at: date, interval: interval, scope: scope)
            if endpoint == .claude {
                claudeAvailable = true
            } else {
                applyError(error, to: endpoint)
            }
            return
        }
        if Self.isNetworkFailure(error) {
            if let wokeAt, date.timeIntervalSince(wokeAt) < Self.wakeGrace {
                state.fail(state.lastError, at: date, retryAfter: RefreshPolicy.wakeRetry)
                return
            }
            state.fail(message, at: date, retryAfter: min(interval, RefreshPolicy.networkRetry))
        } else {
            state.fail(message, at: date, retryAfter: interval)
        }
        applyError(error, to: endpoint)
    }

    private static func throttleRetryAfter(_ error: Error) -> Date?? {
        switch error {
        case UsageError.throttled(let retryAfter),
             ClaudeUsageError.throttled(let retryAfter),
             CursorUsageError.throttled(let retryAfter),
             OpenCodeUsageError.throttled(let retryAfter),
             CommandCodeUsageError.throttled(let retryAfter):
            return .some(retryAfter)
        default:
            return nil
        }
    }

    private static func isNetworkFailure(_ error: Error) -> Bool {
        switch error {
        case UsageError.network, ClaudeUsageError.network, CursorUsageError.network,
             OpenCodeUsageError.network, CommandCodeUsageError.network:
            return true
        default:
            return error is URLError
        }
    }

    private func applyError(_ error: Error, to endpoint: UsageEndpoint) {
        switch endpoint {
        case .codex:
            errorMessage = error.localizedDescription
            if case UsageError.missingAuthFile = error {
                buckets = []
                planType = nil
                reached = false
                resetCredits = 0
            } else if case UsageError.missingTokens = error {
                buckets = []
                planType = nil
                reached = false
                resetCredits = 0
            }
        case .claude, .claudeWhilePaused:
            if case ClaudeUsageError.notSignedIn = error {
                claudeAvailable = false
                claudeBuckets = []
                claudePlan = nil
                claudeErrorMessage = nil
            } else if endpoint == .claude {
                claudeAvailable = true
                claudeErrorMessage = error.localizedDescription
            }
        case .cursor:
            if case CursorUsageError.notSignedIn = error {
                cursorAvailable = false
                cursorBuckets = []
                cursorPlan = nil
                cursorNotice = nil
                cursorErrorMessage = nil
            } else {
                cursorAvailable = true
                cursorErrorMessage = error.localizedDescription
            }
        case .opencode:
            if case OpenCodeUsageError.notSignedIn = error {
                opencodeAvailable = false
                opencodeBuckets = []
                opencodePlan = nil
                opencodeErrorMessage = nil
            } else {
                opencodeAvailable = true
                opencodeErrorMessage = error.localizedDescription
            }
        case .commandcode:
            if case CommandCodeUsageError.notSignedIn = error {
                commandcodeAvailable = false
                commandcodeBuckets = []
                commandcodePlan = nil
                commandcodeErrorMessage = nil
            } else {
                commandcodeAvailable = true
                commandcodeErrorMessage = error.localizedDescription
            }
        }
    }

    private func updateLastUpdated() {
        lastUpdated = LimitBucket.Provider.allCases
            .filter { providers.popover.contains($0) }
            .compactMap { dataDate(for: $0) }
            .max()
    }

    func buckets(for provider: LimitBucket.Provider) -> [LimitBucket] {
        switch provider {
        case .codex: return buckets
        case .claude: return claudeBuckets
        case .cursor: return cursorBuckets
        case .opencode: return opencodeBuckets
        case .commandcode: return commandcodeBuckets
        }
    }

    func plan(for provider: LimitBucket.Provider) -> String? {
        switch provider {
        case .codex: return planType
        case .claude: return claudePlan
        case .cursor: return cursorPlan
        case .opencode: return opencodePlan
        case .commandcode: return commandcodePlan
        }
    }

    private func errorMessage(for provider: LimitBucket.Provider) -> String? {
        switch provider {
        case .codex: return errorMessage
        case .claude: return claudeErrorMessage
        case .cursor: return cursorErrorMessage
        case .opencode: return opencodeErrorMessage
        case .commandcode: return commandcodeErrorMessage
        }
    }

    func claudePausedUntil(at date: Date) -> Date? {
        guard let state = refreshStates[.claude], state.isPaused(at: date) else { return nil }
        return state.backoff.blockedUntil
    }

    func freshnessMessage(for provider: LimitBucket.Provider, at date: Date) -> String? {
        if provider == .claude, claudePausedUntil(at: date) != nil {
            return nil
        }
        guard let lastSuccess = dataDate(for: provider) else {
            return "Saved data — refresh pending"
        }
        let primary = UsageEndpoint(rawValue: provider.rawValue)
        let staleAfter = primary?.policy.staleAfter ?? UsageEndpoint.codex.policy.staleAfter
        let failed = primary.flatMap { refreshStates[$0]?.lastError } != nil
        if failed || date.timeIntervalSince(lastSuccess) > staleAfter {
            return "Saved data from \(ClockText.from(lastSuccess, relativeTo: date))"
        }
        return "Updated \(ClockText.at(lastSuccess, relativeTo: date))"
    }

    func updatedText(at date: Date) -> String {
        guard let lastUpdated else { return "Not updated yet" }
        let seconds = max(0, date.timeIntervalSince(lastUpdated))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "Updated just now" }
        if minutes < 60 { return "Updated \(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "Updated \(hours) h ago" }
        return "Updated \(ClockText.at(lastUpdated, relativeTo: date))"
    }

    private func apply(_ usage: UsageResponse) {
        planType = usage.planType
        resetCredits = usage.rateLimitResetCredits?.applicableAvailableCount
            ?? usage.rateLimitResetCredits?.availableCount
            ?? 0

        buckets = CodexLimits.buckets(from: usage, now: now())
        reached = buckets.contains { $0.reached }
    }

    private func applyCursor(_ snapshot: CursorUsageSnapshot) {
        let layout = CursorLimits.layout(for: snapshot, now: now())
        cursorAvailable = true
        cursorPlan = layout.plan
        cursorBuckets = layout.buckets
        cursorNotice = layout.notice
    }

    private func applyOpenCode(_ usage: OpenCodeUsageResponse) {
        opencodeAvailable = true
        opencodeBuckets = OpenCodeLimits.buckets(from: usage, now: now())
        opencodePlan = OpenCodeLimits.plan(for: opencodeBuckets)
    }

    private func applyCommandCode(_ usage: CommandCodeUsageSnapshot) {
        commandcodeAvailable = true
        commandcodePlan = usage.planId
        commandcodeBuckets = CommandCodeLimits.buckets(from: usage, now: now())
    }

    func isLoading(for provider: LimitBucket.Provider) -> Bool {
        requests.keys.contains { $0.provider == provider }
    }

    func sectionMessage(for provider: LimitBucket.Provider) -> String? {
        let isLoading = isLoading(for: provider)
        switch provider {
        case .codex:
            if let errorMessage { return errorMessage }
            if isLoading || !buckets.isEmpty { return nil }
            return "Codex returned no limits."
        case .claude:
            let date = now()
            if let pausedUntil = claudePausedUntil(at: date) {
                return claudePausedMessage(until: pausedUntil, at: date)
            }
            if let claudeErrorMessage { return claudeErrorMessage }
            if isLoading { return nil }
            if !claudeAvailable { return ClaudeUsageError.notSignedIn.localizedDescription }
            return claudeBuckets.isEmpty ? "Claude returned no limits." : nil
        case .cursor:
            if let cursorErrorMessage { return cursorErrorMessage }
            if isLoading { return nil }
            if cursorAvailable && cursorBuckets.isEmpty {
                return cursorNotice ?? "Cursor returned no limits."
            }
            if !cursorAvailable {
                return CursorUsageError.notSignedIn.errorDescription
            }
            return nil
        case .opencode:
            if let opencodeErrorMessage { return opencodeErrorMessage }
            if isLoading { return nil }
            if opencodeAvailable && opencodeBuckets.isEmpty {
                return "OpenCode returned no limits."
            }
            return nil
        case .commandcode:
            if let commandcodeErrorMessage { return commandcodeErrorMessage }
            if isLoading { return nil }
            if commandcodeAvailable && commandcodeBuckets.isEmpty {
                return "Command Code returned no limits."
            }
            return nil
        }
    }

    func popoverMessage(for provider: LimitBucket.Provider) -> String? {
        if let message = sectionMessage(for: provider) { return message }
        guard !isLoading(for: provider), buckets(for: provider).isEmpty else { return nil }
        switch provider {
        case .opencode where !opencodeAvailable:
            return OpenCodeUsageError.notSignedIn.localizedDescription
        case .commandcode where !commandcodeAvailable:
            return CommandCodeUsageError.notSignedIn.localizedDescription
        default:
            return nil
        }
    }

    private func claudePausedMessage(until pausedUntil: Date, at date: Date) -> String {
        let next = "Next try \(ClockText.at(pausedUntil, relativeTo: date))."
        guard !claudeBuckets.isEmpty, let dataDate = dataDate(for: .claude) else {
            return "Anthropic paused usage updates. \(next)"
        }
        return "Anthropic paused usage updates. Showing values from \(ClockText.from(dataDate, relativeTo: date)). \(next)"
    }

    var visibleEmptyStateMessage: String {
        let messages = LimitBucket.Provider.allCases
            .filter(isVisibleInPopover)
            .compactMap { popoverMessage(for: $0) }
        return messages.first ?? "No usage limits were returned."
    }

    static func durationString(seconds: Int) -> String {
        let total = max(0, seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
