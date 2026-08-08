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
    /// `false` quand aucune session Claude Code n'existe : la section est masquée.
    @Published private(set) var claudeAvailable = false

    private let service = UsageService()
    private let claudeService = ClaudeUsageService()
    private var refreshTask: Task<Void, Never>?
    private var started = false

    private static let refreshInterval: TimeInterval = 5 * 60

    private var claudeBackoff = ThrottleBackoff()

    init() {
        restoreSnapshot()
    }

    /// Réaffiche le dernier état connu avant toute requête : la barre est juste
    /// dès la première frame, et une relance ne coûte pas un appel réseau.
    private func restoreSnapshot() {
        guard let snapshot = UsageSnapshotStore.load()?.refreshed() else { return }
        buckets = snapshot.codexBuckets
        planType = snapshot.codexPlan
        claudeBuckets = snapshot.claudeBuckets
        claudePlan = snapshot.claudePlan
        claudeAvailable = !snapshot.claudeBuckets.isEmpty
        lastUpdated = snapshot.fetchedAt
    }

    private func persistSnapshot(fetchedAt: Date) {
        UsageSnapshotStore.save(
            UsageSnapshot(
                codexBuckets: buckets,
                codexPlan: planType,
                claudeBuckets: claudeBuckets,
                claudePlan: claudePlan,
                fetchedAt: fetchedAt
            )
        )
    }

#if DEBUG
    init(
        previewBuckets: [LimitBucket],
        planType: String,
        lastUpdated: Date,
        claudeBuckets: [LimitBucket] = [],
        claudePlan: String? = nil
    ) {
        buckets = previewBuckets
        self.planType = planType
        self.lastUpdated = lastUpdated
        self.claudeBuckets = claudeBuckets
        self.claudePlan = claudePlan
        claudeAvailable = !claudeBuckets.isEmpty
    }
#endif

    /// La barre « All models » de Claude Code, celle qui est épinglée dans la barre de menus.
    var claudeAllModels: LimitBucket? {
        claudeBuckets.first { $0.kind == .weeklyAll } ?? claudeBuckets.first
    }

    var menuBarClaudeText: String? {
        guard let bucket = claudeAllModels else { return nil }
        return "\(bucket.remainingPercent)%"
    }

    /// Toujours une chaîne, jamais `nil` : `MenuBarExtra` fige la hiérarchie de
    /// vues de son label au premier rendu, donc un segment inséré plus tard par
    /// un `if` n'apparaîtrait jamais. Seul le contenu d'un `Text` déjà en place
    /// se rafraîchit.
    var menuBarClaudeDisplay: String {
        menuBarClaudeText ?? "–"
    }


    var menuBarClaudeAccessibilityText: String? {
        guard let bucket = claudeAllModels else { return nil }
        return "Claude Code all models, \(bucket.remainingPercent) percent left"
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
        refreshNow()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.refreshNow()
            }
        }
    }

    /// `force` = ouverture du popover ou action explicite : on rafraîchit même
    /// si les données sont encore jeunes, mais jamais pendant un recul 429.
    func refreshNow(force: Bool = false) {
        guard !isLoading else { return }
        if !force, let lastUpdated,
           Date().timeIntervalSince(lastUpdated) < Self.refreshInterval {
            return
        }

        isLoading = true
        Task {
            // Les deux appels partent ensemble : un Codex lent ne retarde pas Claude.
            let codexFetch = Task { try await service.fetchUsage() }
            let claudeFetch = claudeBackoff.isBlocked
                ? nil
                : Task { try await claudeService.fetchUsage() }

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
                    // On garde les dernières valeurs connues et on espace les tentatives.
                    claudeBackoff.recordThrottle()
                    claudeAvailable = true
                    claudeErrorMessage = ClaudeUsageError.throttled.errorDescription
                } catch {
                    // Une session existe (sinon on serait passé par `notSignedIn`) :
                    // on garde la section visible pour y afficher l'erreur.
                    claudeAvailable = true
                    claudeErrorMessage = error.localizedDescription
                }
            }

            isLoading = false
            // `lastUpdated` date les données, pas la tentative : un échec ne doit
            // pas faire passer un état périmé pour frais.
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
