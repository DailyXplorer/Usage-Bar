import Foundation
import SwiftUI

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var buckets: [LimitBucket] = []
    @Published private(set) var planType: String?
    @Published private(set) var reached: Bool = false
    @Published private(set) var resetCredits: Int = 0
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published var menuPresented = false

    @Published private(set) var claudeBuckets: [LimitBucket] = []
    @Published private(set) var claudePlan: String?
    @Published private(set) var claudeErrorMessage: String?
    @Published private(set) var claudeAvailable = false

    @Published private(set) var cursorBuckets: [LimitBucket] = []
    @Published private(set) var cursorPlan: String?
    @Published private(set) var cursorErrorMessage: String?
    @Published private(set) var cursorAvailable = false

    @Published private(set) var opencodeBuckets: [LimitBucket] = []
    @Published private(set) var opencodePlan: String?
    @Published private(set) var opencodeErrorMessage: String?
    @Published private(set) var opencodeAvailable = false

    @Published private(set) var commandcodeBuckets: [LimitBucket] = []
    @Published private(set) var commandcodePlan: String?
    @Published private(set) var commandcodeErrorMessage: String?
    @Published private(set) var commandcodeAvailable = false

    @Published private(set) var menuBarProviders: Set<LimitBucket.Provider>

    @Published private(set) var refreshStates: [UsageEndpoint: UsageRefreshState] = [:]

    private let fetcher: UsageFetcher
    private let now: () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var snapshotDate: Date?
    private let automaticallySchedules: Bool
    private let defaults: UserDefaults
    private var refreshTask: Task<Void, Never>?
    private var requests: [UsageEndpoint: Task<Void, Never>] = [:]
    private var started = false
    private var sleeping = false

    init(
        defaults: UserDefaults = .standard,
        fetcher: UsageFetcher = .live,
        now: @escaping () -> Date = Date.init,
        automaticallySchedules: Bool = true,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    ) {
        self.defaults = defaults
        self.fetcher = fetcher
        self.now = now
        self.sleep = sleep
        self.automaticallySchedules = automaticallySchedules
        menuBarProviders = MenuBarPreferences.load(from: defaults)
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
        menuBarProviders.count > 1
    }

    func isVisibleInMenuBar(_ provider: LimitBucket.Provider) -> Bool {
        menuBarProviders.contains(provider)
    }

    func setVisibleInMenuBar(_ provider: LimitBucket.Provider, visible: Bool) {
        var next = menuBarProviders
        if visible {
            next.insert(provider)
        } else {
            next.remove(provider)
            if next.isEmpty { return }
        }
        let changed = next != menuBarProviders
        menuBarProviders = next
        MenuBarPreferences.save(next, to: defaults)
        guard changed else { return }
        updateLastUpdated()
        if visible, started {
            refresh(endpoints: UsageEndpoint.allCases.filter { $0.provider == provider }, force: true)
        }
        scheduleNextRefresh()
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
        defaults: UserDefaults = .standard,
        errorMessage: String? = nil,
        cursorAvailable: Bool? = nil,
        opencodeAvailable: Bool? = nil,
        commandcodeAvailable: Bool? = nil
    ) {
        self.defaults = defaults
        fetcher = .live
        now = Date.init
        sleep = { delay in
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        automaticallySchedules = true
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
        self.menuBarProviders = menuBarProviders
        self.errorMessage = errorMessage
        for endpoint in UsageEndpoint.allCases {
            var state = UsageRefreshState()
            state.succeed(at: lastUpdated)
            refreshStates[endpoint] = state
        }
    }
#endif

    var claudeSession: LimitBucket? {
        claudeBuckets.first { $0.kind == .session }
    }

    var menuBarClaudeText: String? {
        guard let bucket = claudeSession else { return nil }
        return "\(bucket.remainingPercent)%"
    }

    var menuBarClaudeDisplay: String {
        menuBarClaudeText ?? MenuBarSegment.placeholder
    }

    var menuBarClaudeAccessibilityText: String? {
        guard let bucket = claudeSession else { return nil }
        return "Claude Code current session, \(bucket.remainingPercent) percent left"
    }

    var cursorModels: LimitBucket? {
        cursorBuckets.first { $0.kind == .cursorModels }
    }

    var menuBarCursorText: String? {
        guard let bucket = cursorModels else { return nil }
        return "\(bucket.remainingPercent)%"
    }

    var menuBarCursorDisplay: String {
        menuBarCursorText ?? MenuBarSegment.placeholder
    }

    var menuBarCursorAccessibilityText: String? {
        guard let bucket = cursorModels else { return nil }
        return "Cursor models, \(bucket.remainingPercent) percent left"
    }

    var opencodeRolling: LimitBucket? {
        opencodeBuckets.first { $0.kind == .rolling }
    }

    var menuBarOpenCodeText: String? {
        guard let bucket = opencodeRolling else { return nil }
        return "\(bucket.remainingPercent)%"
    }

    var menuBarOpenCodeDisplay: String {
        menuBarOpenCodeText ?? MenuBarSegment.placeholder
    }

    var menuBarOpenCodeAccessibilityText: String? {
        guard let bucket = opencodeRolling else { return nil }
        return "OpenCode current session, \(bucket.remainingPercent) percent left"
    }

    var showsOpenCode: Bool {
        isVisibleInMenuBar(.opencode) && (opencodeAvailable || opencodeErrorMessage != nil)
    }

    var commandcodeRolling: LimitBucket? {
        commandcodeBuckets.first { $0.kind == .rolling }
    }

    var menuBarCommandCodeText: String? {
        guard let bucket = commandcodeRolling else { return nil }
        return "\(bucket.remainingPercent)%"
    }

    var menuBarCommandCodeDisplay: String {
        menuBarCommandCodeText ?? MenuBarSegment.placeholder
    }

    var menuBarCommandCodeAccessibilityText: String? {
        guard let bucket = commandcodeRolling else { return nil }
        return "Command Code current session, \(bucket.remainingPercent) percent left"
    }

    var showsCommandCode: Bool {
        isVisibleInMenuBar(.commandcode) && (commandcodeAvailable || commandcodeErrorMessage != nil)
    }

    var menuBarSegments: [MenuBarSegment] {
        LimitBucket.Provider.allCases.compactMap { provider in
            guard menuBarProviders.contains(provider) else { return nil }
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
        if menuBarProviders.contains(.codex) {
            parts.append("Codex limits, \(menuBarAccessibilityText)")
        }
        if menuBarProviders.contains(.claude), let claude = menuBarClaudeAccessibilityText {
            parts.append(claude)
        } else if menuBarProviders.contains(.claude) {
            parts.append("Claude Code unavailable")
        }
        if menuBarProviders.contains(.cursor), let cursor = menuBarCursorAccessibilityText {
            parts.append(cursor)
        } else if menuBarProviders.contains(.cursor) {
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
        if isLoading(for: .codex) && buckets.isEmpty {
            return MenuBarSegment.placeholder
        }
        if errorMessage != nil && buckets.isEmpty {
            return "!%"
        }
        guard let bucket = codexMenuBarBucket else { return MenuBarSegment.placeholder }
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

    var menuBarColor: Color {
        guard let bucket = codexMenuBarBucket else { return .primary }
        return Self.color(forPercentUsed: bucket.usedPercent)
    }

    private var codexMenuBarBucket: LimitBucket? {
        buckets.first { $0.kind == .primary }
            ?? buckets.first { $0.kind == .secondary }
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

    var primaryLimitReached: Bool {
        codexMenuBarBucket?.reached ?? false
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
        for request in requests.values { request.cancel() }
    }

    func setSleeping(_ sleeping: Bool) {
        self.sleeping = sleeping
        if sleeping {
            refreshTask?.cancel()
            refreshTask = nil
        } else if started {
            refreshNow()
        }
    }

    func refreshNow(force: Bool = false) {
        refresh(endpoints: UsageEndpoint.allCases, force: force)
    }

    private func refresh(endpoints: [UsageEndpoint], force: Bool) {
        guard !sleeping else { return }
        let date = now()
        for endpoint in endpoints {
            guard menuBarProviders.contains(endpoint.provider), requests[endpoint] == nil,
                  (refreshStates[endpoint] ?? UsageRefreshState()).canStart(at: date, force: force) else {
                continue
            }
            let fetch = fetcher.fetch
            requests[endpoint] = Task { [weak self] in
                let result: Result<UsageFetchResult, Error>
                do {
                    result = .success(try await fetch(endpoint))
                } catch {
                    result = .failure(error)
                }
                guard let self else { return }
                self.requests[endpoint] = nil
                if !Task.isCancelled {
                    self.receive(result, from: endpoint)
                }
                self.isLoading = !self.requests.isEmpty
                self.scheduleNextRefresh()
            }
        }
        isLoading = !requests.isEmpty
        scheduleNextRefresh()
    }

    private func scheduleNextRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        guard started, automaticallySchedules, !sleeping else { return }
        let deadline = UsageEndpoint.allCases
            .filter { menuBarProviders.contains($0.provider) && requests[$0] == nil }
            .map { (refreshStates[$0] ?? UsageRefreshState()).nextEligible }
            .min()
        guard let deadline else { return }
        let delay = max(0.01, min(3600, deadline.timeIntervalSince(now())))
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
        var state = refreshStates[endpoint] ?? UsageRefreshState()
        switch result {
        case .success(let usage):
            switch usage {
            case .codex(let response):
                apply(response)
                errorMessage = nil
                state.succeed(at: date)
            case .claude(let response, let credentials):
                applyClaude(response, credentials: credentials)
                claudeErrorMessage = nil
                state.succeed(at: date)
            case .cursor(let response, let credentials):
                applyCursor(response, grokBot: .unavailable, credentials: credentials)
                cursorErrorMessage = nil
                state.succeed(at: date)
            case .cursorGrokBot(let response, let credentials):
                applyCursorGrokBot(response, credentials: credentials)
                switch response {
                case .refreshed:
                    state.succeed(at: date)
                case .unavailable:
                    state.fail("Grok Bot usage is temporarily unavailable.", at: date)
                case .throttled(let retryAfter):
                    state.throttle("Grok Bot usage is temporarily rate limited.", retryAfter: retryAfter, at: date)
                }
            case .opencode(let response):
                applyOpenCode(response)
                opencodeErrorMessage = nil
                state.succeed(at: date)
            case .commandcode(let response):
                applyCommandCode(response)
                commandcodeErrorMessage = nil
                state.succeed(at: date)
            }
        case .failure(let error):
            state.fail(error.localizedDescription, at: date)
            switch error {
            case UsageError.throttled(let retryAfter),
                 ClaudeUsageError.throttled(let retryAfter),
                 CursorUsageError.throttled(let retryAfter),
                 OpenCodeUsageError.throttled(let retryAfter),
                 CommandCodeUsageError.throttled(let retryAfter):
                state.throttle(error.localizedDescription, retryAfter: retryAfter, at: date)
            default:
                break
            }
            applyError(error, to: endpoint)
        }
        refreshStates[endpoint] = state
        updateLastUpdated()
        persistSnapshot()
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
        case .claude:
            if case ClaudeUsageError.notSignedIn = error {
                claudeAvailable = false
                claudeBuckets = []
                claudePlan = nil
                claudeErrorMessage = nil
            } else {
                claudeAvailable = true
                claudeErrorMessage = error.localizedDescription
            }
        case .cursor:
            if case CursorUsageError.notSignedIn = error {
                cursorAvailable = false
                cursorBuckets = []
                cursorPlan = nil
                cursorErrorMessage = nil
            } else {
                cursorAvailable = true
                cursorErrorMessage = error.localizedDescription
            }
        case .cursorGrokBot:
            if case CursorUsageError.notSignedIn = error {
                cursorBuckets.removeAll { $0.kind == .grokBot }
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
        let endpoints = UsageEndpoint.allCases.filter {
            menuBarProviders.contains($0.provider)
                && ($0 != .cursorGrokBot || cursorBuckets.contains { $0.kind == .grokBot })
        }
        let dates = endpoints.compactMap { refreshStates[$0]?.lastSuccess }
        lastUpdated = dates.count == endpoints.count ? dates.min() : nil
    }

    func freshnessMessage(for provider: LimitBucket.Provider, at date: Date) -> String? {
        guard let endpoint = UsageEndpoint(rawValue: provider.rawValue),
              let state = refreshStates[endpoint], let lastSuccess = state.lastSuccess else {
            return "Saved data — refresh pending"
        }
        let sameDay = Calendar.current.isDate(lastSuccess, inSameDayAs: date)
        let time = lastSuccess.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened)
        if state.lastError != nil || date.timeIntervalSince(lastSuccess) > UsageRefreshState.interval + 1 {
            return "Saved data from \(time)"
        }
        return "Updated at \(time)"
    }

    func grokBotMessage(at date: Date) -> String? {
        guard let state = refreshStates[.cursorGrokBot] else { return nil }
        if let error = state.lastError { return error }
        guard cursorBuckets.contains(where: { $0.kind == .grokBot }),
              let success = state.lastSuccess,
              date.timeIntervalSince(success) > UsageRefreshState.interval + 1 else { return nil }
        return "Grok Bot data from \(success.formatted(date: .omitted, time: .shortened))"
    }

    private func apply(_ usage: UsageResponse) {
        planType = usage.planType
        reached = usage.rateLimit?.limitReached ?? false
        resetCredits = usage.rateLimitResetCredits?.applicableAvailableCount
            ?? usage.rateLimitResetCredits?.availableCount
            ?? 0

        buckets = CodexLimits.buckets(from: usage, now: now())
    }

    private func applyClaude(_ usage: ClaudeUsageResponse, credentials: ClaudeCredentials) {
        claudeAvailable = true
        claudePlan = credentials.planToken
        claudeBuckets = ClaudeLimits.buckets(from: usage, now: now())
    }

    private func applyCursor(
        _ usage: CursorUsageResponse,
        grokBot: CursorGrokBotFetchResult,
        credentials: CursorCredentials
    ) {
        cursorAvailable = true
        cursorPlan = credentials.membershipType
        cursorBuckets = CursorLimits.buckets(
            from: usage,
            grokBot: grokBot,
            preserving: cursorBuckets,
            now: now()
        )
    }

    private func applyCursorGrokBot(
        _ grokBot: CursorGrokBotFetchResult,
        credentials: CursorCredentials
    ) {
        cursorBuckets = CursorLimits.updatingGrokBot(
            in: cursorBuckets,
            from: grokBot,
            preserving: cursorBuckets,
            now: now()
        )
        if case .refreshed = grokBot {
            cursorAvailable = true
            cursorPlan = credentials.membershipType
        }
    }

    private func applyOpenCode(_ usage: OpenCodeUsageResponse) {
        opencodeAvailable = true
        opencodeBuckets = OpenCodeLimits.buckets(from: usage, now: now())
        opencodePlan = OpenCodeLimits.plan(for: opencodeBuckets)
    }

    private func applyCommandCode(_ usage: CommandCodeUsageSnapshot) {
        if CommandCodeLimits.shouldHide(usage) {
            commandcodeAvailable = false
            commandcodeBuckets = []
            commandcodePlan = nil
            return
        }
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
            if let claudeErrorMessage { return claudeErrorMessage }
            if claudeAvailable || isLoading { return nil }
            return "No Claude Code session. Run `claude`, then `/login`."
        case .cursor:
            if let cursorErrorMessage { return cursorErrorMessage }
            if isLoading { return nil }
            if cursorAvailable && cursorBuckets.isEmpty {
                return "Cursor returned no limits."
            }
            if !cursorAvailable {
                return "No Cursor session. Open Cursor and sign in."
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

    var visibleEmptyStateMessage: String {
        let messages = LimitBucket.Provider.allCases
            .filter(isVisibleInMenuBar)
            .compactMap { sectionMessage(for: $0) }
        return messages.first ?? "No usage limits were returned."
    }

    func formattedReset(_ bucket: LimitBucket) -> String {
        guard let seconds = bucket.remainingResetSeconds(at: now()), let resetAt = bucket.resetAt else {
            return ""
        }
        let duration = "Resets in \(Self.durationString(seconds: seconds))"
        return bucket.reached ? duration : duration + " · \(resetAt.formatted(date: .omitted, time: .shortened))"
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

    func relativeTimeString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
