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

    @Published private(set) var menuBarProviders: Set<LimitBucket.Provider>

    private let service = UsageService()
    private let claudeService = ClaudeUsageService()
    private let cursorService = CursorUsageService()
    private let opencodeService = OpenCodeUsageService()
    private let defaults: UserDefaults
    private var refreshTask: Task<Void, Never>?
    private var started = false

    private static let refreshInterval: TimeInterval = 5 * 60

    private var claudeBackoff = ThrottleBackoff()
    private var cursorBackoff = ThrottleBackoff()
    private var opencodeBackoff = ThrottleBackoff()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarProviders = MenuBarPreferences.load(from: defaults)
        restoreSnapshot()
    }

    private func restoreSnapshot() {
        guard let snapshot = UsageSnapshotStore.load(from: defaults)?.refreshed() else { return }
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
        lastUpdated = snapshot.fetchedAt
        persistSnapshot(fetchedAt: snapshot.fetchedAt)
    }

    private func persistSnapshot(fetchedAt: Date) {
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
                fetchedAt: fetchedAt
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
        if changed, visible, started {
            refreshNow(force: true)
        }
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
        menuBarProviders: Set<LimitBucket.Provider> = [.codex, .claude],
        defaults: UserDefaults = .standard,
        errorMessage: String? = nil,
        cursorAvailable: Bool? = nil,
        opencodeAvailable: Bool? = nil
    ) {
        self.defaults = defaults
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
        self.menuBarProviders = menuBarProviders
        self.errorMessage = errorMessage
    }
#endif

    var claudeAllModels: LimitBucket? {
        claudeBuckets.first { $0.kind == .weeklyAll } ?? claudeBuckets.first
    }

    var menuBarClaudeText: String? {
        guard let bucket = claudeAllModels else { return nil }
        return "\(bucket.remainingPercent)%"
    }

    var menuBarClaudeDisplay: String {
        menuBarClaudeText ?? "–"
    }

    var menuBarClaudeAccessibilityText: String? {
        guard let bucket = claudeAllModels else { return nil }
        return "Claude Code all models, \(bucket.remainingPercent) percent left"
    }

    var cursorModels: LimitBucket? {
        cursorBuckets.first { $0.kind == .cursorModels } ?? cursorBuckets.first
    }

    var menuBarCursorText: String? {
        guard let bucket = cursorModels else { return nil }
        return "\(bucket.remainingPercent)%"
    }

    var menuBarCursorDisplay: String {
        menuBarCursorText ?? "–"
    }

    var menuBarCursorAccessibilityText: String? {
        guard let bucket = cursorModels else { return nil }
        return "Cursor models, \(bucket.remainingPercent) percent left"
    }

    var opencodeRolling: LimitBucket? {
        opencodeBuckets.first { $0.kind == .rolling } ?? opencodeBuckets.first
    }

    var menuBarOpenCodeText: String? {
        guard let bucket = opencodeRolling else { return nil }
        return "\(bucket.remainingPercent)%"
    }

    var menuBarOpenCodeDisplay: String {
        menuBarOpenCodeText ?? "–"
    }

    var menuBarOpenCodeAccessibilityText: String? {
        guard let bucket = opencodeRolling else { return nil }
        return "OpenCode Go rolling 5 hours, \(bucket.remainingPercent) percent left"
    }

    var menuBarSegments: [MenuBarSegment] {
        LimitBucket.Provider.allCases.compactMap { provider in
            guard menuBarProviders.contains(provider) else { return nil }
            switch provider {
            case .codex:
                return MenuBarSegment(logo: AppTheme.codexLogo, value: menuBarText)
            case .claude:
                return MenuBarSegment(logo: AppTheme.claudeLogo, value: menuBarClaudeDisplay)
            case .cursor:
                return MenuBarSegment(logo: AppTheme.cursorLogo, value: menuBarCursorDisplay)
            case .opencode:
                return MenuBarSegment(logo: AppTheme.opencodeLogo, value: menuBarOpenCodeDisplay)
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
        if menuBarProviders.contains(.opencode), let opencode = menuBarOpenCodeAccessibilityText {
            parts.append(opencode)
        } else if menuBarProviders.contains(.opencode) {
            parts.append("OpenCode Go unavailable")
        }
        return parts.joined(separator: ". ")
    }

    var menuBarText: String {
        if isLoading && buckets.isEmpty {
            return "--%"
        }
        if errorMessage != nil && buckets.isEmpty {
            return "!%"
        }
        guard let bucket = buckets.first else { return "--%" }
        return "\(bucket.remainingPercent)%"
    }

    var menuBarAccessibilityText: String {
        guard let bucket = buckets.first else {
            if isLoading { return "loading" }
            if errorMessage != nil { return "unavailable" }
            return "not loaded"
        }
        return "\(bucket.remainingPercent) percent left"
    }

    var menuBarColor: Color {
        guard let bucket = buckets.first else { return .primary }
        return Self.color(forPercentUsed: bucket.usedPercent)
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
        buckets.first?.reached ?? false
    }

    func start() {
        guard !started else { return }
        started = true
        refreshNow(force: true)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.refreshNow()
            }
        }
    }

    func refreshNow(force: Bool = false) {
        guard !isLoading else { return }
        if !force, let lastUpdated,
           Date().timeIntervalSince(lastUpdated) < Self.refreshInterval {
            return
        }

        isLoading = true
        Task {
            let codexFetch = Task { try await service.fetchUsage() }
            let claudeFetch = claudeBackoff.isBlocked
                ? nil
                : Task { try await claudeService.fetchUsage() }
            let cursorFetch = cursorBackoff.isBlocked
                ? nil
                : Task { try await cursorService.fetchUsage() }
            let opencodeFetch = opencodeBackoff.isBlocked
                ? nil
                : Task { try await opencodeService.fetchUsage() }

            var succeeded = false

            do {
                apply(try await codexFetch.value)
                errorMessage = nil
                succeeded = true
            } catch {
                errorMessage = error.localizedDescription
            }

            if let claudeFetch {
                do {
                    let (usage, credentials) = try await claudeFetch.value
                    applyClaude(usage, credentials: credentials)
                    claudeErrorMessage = nil
                    claudeBackoff.reset()
                    succeeded = true
                } catch ClaudeUsageError.notSignedIn {
                    claudeAvailable = false
                    claudeBuckets = []
                    claudeErrorMessage = nil
                } catch ClaudeUsageError.throttled {
                    claudeBackoff.recordThrottle()
                    claudeAvailable = true
                    claudeErrorMessage = ClaudeUsageError.throttled.errorDescription
                } catch {
                    claudeAvailable = true
                    claudeErrorMessage = error.localizedDescription
                }
            }

            if let cursorFetch {
                do {
                    let (usage, credentials) = try await cursorFetch.value
                    applyCursor(usage, credentials: credentials)
                    cursorErrorMessage = nil
                    cursorBackoff.reset()
                    succeeded = true
                } catch CursorUsageError.notSignedIn {
                    cursorAvailable = false
                    cursorBuckets = []
                    cursorErrorMessage = nil
                } catch CursorUsageError.throttled {
                    cursorBackoff.recordThrottle()
                    cursorAvailable = true
                    cursorErrorMessage = CursorUsageError.throttled.errorDescription
                } catch {
                    cursorAvailable = true
                    cursorErrorMessage = error.localizedDescription
                }
            }

            if let opencodeFetch {
                do {
                    let (usage, _) = try await opencodeFetch.value
                    applyOpenCode(usage)
                    opencodeErrorMessage = nil
                    opencodeBackoff.reset()
                    succeeded = true
                } catch OpenCodeUsageError.notSignedIn {
                    opencodeAvailable = false
                    opencodeBuckets = []
                    opencodeErrorMessage = nil
                } catch OpenCodeUsageError.throttled {
                    opencodeBackoff.recordThrottle()
                    opencodeAvailable = true
                    opencodeErrorMessage = OpenCodeUsageError.throttled.errorDescription
                } catch {
                    opencodeAvailable = true
                    opencodeErrorMessage = error.localizedDescription
                }
            }

            isLoading = false
            if succeeded {
                let now = Date()
                lastUpdated = now
                persistSnapshot(fetchedAt: now)
            }
        }
    }

    private func apply(_ usage: UsageResponse) {
        planType = usage.planType
        reached = usage.rateLimit?.limitReached ?? false
        resetCredits = usage.rateLimitResetCredits?.applicableAvailableCount
            ?? usage.rateLimitResetCredits?.availableCount
            ?? 0

        var result: [LimitBucket] = []
        if let primary = usage.rateLimit?.primaryWindow {
            result.append(makeBucket(
                kind: .primary,
                window: primary,
                isSecondary: false,
                reached: usage.rateLimit?.limitReached ?? false
            ))
        }
        if let secondary = usage.rateLimit?.secondaryWindow {
            result.append(makeBucket(
                kind: .secondary,
                window: secondary,
                isSecondary: true,
                reached: usage.rateLimit?.limitReached ?? false
            ))
        }
        buckets = result
    }

    private func applyClaude(_ usage: ClaudeUsageResponse, credentials: ClaudeCredentials) {
        claudeAvailable = true
        claudePlan = credentials.subscriptionType
        claudeBuckets = ClaudeLimits.buckets(from: usage)
    }

    private func applyCursor(_ usage: CursorUsageResponse, credentials: CursorCredentials) {
        cursorAvailable = true
        cursorPlan = credentials.membershipType
        cursorBuckets = CursorLimits.buckets(from: usage)
    }

    private func applyOpenCode(_ usage: OpenCodeUsageResponse) {
        opencodeAvailable = true
        opencodePlan = "Go"
        opencodeBuckets = OpenCodeLimits.buckets(from: usage)
    }

    func sectionMessage(for provider: LimitBucket.Provider) -> String? {
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
                return "OpenCode Go returned no limits."
            }
            if !opencodeAvailable {
                return "No OpenCode Go key. Run `/connect` in OpenCode and select OpenCode Go."
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

    private func makeBucket(
        kind: LimitBucket.Kind,
        window: RateLimitWindow,
        isSecondary: Bool,
        reached: Bool
    ) -> LimitBucket {
        LimitBucket(
            kind: kind,
            name: WindowLabels.label(forWindowSeconds: window.limitWindowSeconds, isSecondary: isSecondary),
            usedPercent: window.usedPercent ?? 0,
            resetAt: window.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            resetAfterSeconds: window.resetAfterSeconds,
            limitWindowSeconds: window.limitWindowSeconds,
            reached: reached
        )
    }

    func formattedReset(_ bucket: LimitBucket) -> String {
        if bucket.reached {
            return "Resets in \(Self.durationString(seconds: bucket.resetAfterSeconds ?? 0))"
        }
        guard let resetAt = bucket.resetAt else { return "" }
        return "Resets in \(Self.durationString(seconds: bucket.resetAfterSeconds ?? 0))"
            + " · \(resetAt.formatted(date: .omitted, time: .shortened))"
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
