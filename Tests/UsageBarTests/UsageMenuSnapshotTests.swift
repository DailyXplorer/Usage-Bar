import AppKit
import SwiftUI
import XCTest
@testable import UsageBar

final class UsageMenuSnapshotTests: XCTestCase {
    @MainActor
    func testMenuRendersInLightAndDarkModes() throws {
        AppTheme.loadFont()
        let model = UsageModel(
            previewBuckets: [
                LimitBucket(
                    kind: .primary,
                    name: "Weekly Limit",
                    usedPercent: 42,
                    resetAt: Date(timeIntervalSince1970: 1_786_189_759),
                    resetAfterSeconds: 231_321,
                    limitWindowSeconds: 604_800,
                    reached: false
                ),
                LimitBucket(
                    kind: .additional,
                    scope: "additional.model_x.primary",
                    name: "Model X Weekly Limit",
                    usedPercent: 0,
                    resetAt: Date(timeIntervalSince1970: 1_786_402_800),
                    resetAfterSeconds: 177_600,
                    limitWindowSeconds: 604_800,
                    reached: false
                )
            ],
            planType: "prolite",
            lastUpdated: Date(),
            claudeBuckets: [
                LimitBucket(
                    provider: .claude,
                    kind: .session,
                    name: "Current Session",
                    usedPercent: 12,
                    resetAt: Date(timeIntervalSince1970: 1_786_232_400),
                    resetAfterSeconds: 7_200,
                    limitWindowSeconds: 18_000,
                    reached: false
                ),
                LimitBucket(
                    provider: .claude,
                    kind: .weeklyAll,
                    name: "All Models",
                    usedPercent: 40,
                    resetAt: Date(timeIntervalSince1970: 1_786_402_800),
                    resetAfterSeconds: 177_600,
                    limitWindowSeconds: 604_800,
                    reached: false
                ),
                LimitBucket(
                    provider: .claude,
                    kind: .weeklyScoped,
                    name: "Fable",
                    usedPercent: 91,
                    resetAt: Date(timeIntervalSince1970: 1_786_402_800),
                    resetAfterSeconds: 177_600,
                    limitWindowSeconds: 604_800,
                    reached: false
                ),
            ],
            claudePlan: "max_5x",
            cursorBuckets: [
                LimitBucket(
                    provider: .cursor,
                    kind: .cursorModels,
                    name: "Cursor Models",
                    usedPercent: 8,
                    resetAt: Date(timeIntervalSince1970: 1_789_244_447),
                    resetAfterSeconds: 2_678_400,
                    limitWindowSeconds: 2_678_400,
                    reached: false
                ),
                LimitBucket(
                    provider: .cursor,
                    kind: .otherModels,
                    name: "Other Models",
                    usedPercent: 21,
                    resetAt: Date(timeIntervalSince1970: 1_789_244_447),
                    resetAfterSeconds: 2_678_400,
                    limitWindowSeconds: 2_678_400,
                    reached: false
                ),
                LimitBucket(
                    provider: .cursor,
                    kind: .grokBot,
                    name: CursorLimits.grokBotDisplayName,
                    usedPercent: 19,
                    resetAt: Date(timeIntervalSince1970: 1_786_363_200),
                    resetAfterSeconds: 86_400,
                    limitWindowSeconds: CursorLimits.weekSeconds,
                    reached: false
                ),
            ],
            cursorPlan: "pro",
            menuBarProviders: [.codex, .claude, .cursor]
        )

        let buildDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let updater = stubUpdater(defaults: defaults)

        let lightURL = buildDirectory.appendingPathComponent("UsageBar-light.png")
        try render(
            UsageMenuView()
                .environmentObject(model)
                .environmentObject(updater)
                .environment(\.colorScheme, .light),
            to: lightURL
        )
        try render(
            UsageMenuView()
                .environmentObject(model)
                .environmentObject(updater)
                .environment(\.colorScheme, .dark),
            to: buildDirectory.appendingPathComponent("UsageBar-dark.png")
        )

        let light = try XCTUnwrap(NSImage(contentsOf: lightURL))
        XCTAssertEqual(light.size.width, 304, accuracy: 0.5)
        XCTAssertLessThan(light.size.height, 520)
        XCTAssertGreaterThan(light.size.height, 360)
    }

    @MainActor
    func testShortMenuKeepsItsIntrinsicHeight() throws {
        AppTheme.loadFont()
        let model = UsageModel(
            previewBuckets: [
                LimitBucket(
                    kind: .primary,
                    name: "Weekly Limit",
                    usedPercent: 42,
                    resetAt: Date(timeIntervalSince1970: 1_786_189_759),
                    resetAfterSeconds: 231_321,
                    limitWindowSeconds: 604_800,
                    reached: false
                )
            ],
            planType: "prolite",
            lastUpdated: Date(),
            menuBarProviders: [.codex]
        )
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/UsageBar-short.png")

        try render(
            UsageMenuView()
                .environmentObject(model)
                .environmentObject(stubUpdater(defaults: defaults))
                .environment(\.colorScheme, .light),
            to: url
        )

        let image = try XCTUnwrap(NSImage(contentsOf: url))
        XCTAssertLessThan(image.size.height, 250)
    }

    @MainActor
    func testBoundaryMenuStaysBelowHeightLimit() throws {
        AppTheme.loadFont()
        let model = UsageModel(
            previewBuckets: [
                bucket(kind: .primary, name: "Current Session"),
                bucket(kind: .secondary, name: "Weekly Limit"),
                bucket(kind: .additional, name: "Model X Weekly Limit"),
                bucket(kind: .spendLimit, name: CodexLimits.spendLimitDisplayName),
            ],
            planType: "prolite",
            lastUpdated: Date(),
            cursorBuckets: [
                bucket(provider: .cursor, kind: .cursorModels, name: "Cursor Models"),
                bucket(provider: .cursor, kind: .otherModels, name: "Other Models"),
                bucket(provider: .cursor, kind: .grokBot, name: CursorLimits.grokBotDisplayName),
            ],
            cursorPlan: "pro",
            menuBarProviders: [.codex, .claude, .cursor]
        )
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/UsageBar-boundary.png")

        try render(
            UsageMenuView()
                .environmentObject(model)
                .environmentObject(stubUpdater(defaults: defaults))
                .environment(\.colorScheme, .light),
            to: url
        )

        let image = try XCTUnwrap(NSImage(contentsOf: url))
        XCTAssertLessThan(image.size.height, 520)
    }

    @MainActor
    func testConstrainedBoundaryMenuUsesScrollView() throws {
        AppTheme.loadFont()
        let model = UsageModel(
            previewBuckets: [
                bucket(kind: .primary, name: "Current Session"),
                bucket(kind: .secondary, name: "Weekly Limit"),
                bucket(kind: .additional, name: "Model X Weekly Limit"),
                bucket(kind: .spendLimit, name: CodexLimits.spendLimitDisplayName),
            ],
            planType: "prolite",
            lastUpdated: Date(),
            cursorBuckets: [
                bucket(provider: .cursor, kind: .cursorModels, name: "Cursor Models"),
                bucket(provider: .cursor, kind: .otherModels, name: "Other Models"),
                bucket(provider: .cursor, kind: .grokBot, name: CursorLimits.grokBotDisplayName),
            ],
            cursorPlan: "pro",
            menuBarProviders: [.codex, .cursor]
        )
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let content = UsageMenuView()
            .environmentObject(model)
            .environmentObject(stubUpdater(defaults: defaults))
            .environment(\.colorScheme, .light)
            .frame(width: UsageMenuView.width, height: 360)
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: UsageMenuView.width, height: 360)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertTrue(containsScrollView(in: hostingView))
    }

    @MainActor
    func testClaudeUltraWithoutSessionAndCodexProWeeklyOnly() throws {
        let now = Date()
        let model = UsageModel(
            previewBuckets: try codexBuckets(Self.codexProWeeklyOnly, now: now),
            planType: "pro",
            lastUpdated: now.addingTimeInterval(-120),
            claudeBuckets: try claudeBuckets(ClaudeFixtures.withoutSession, now: now),
            claudePlan: "Ultra",
            now: { now }
        )

        XCTAssertFalse(model.claudeBuckets.contains { $0.kind == .session })
        XCTAssertEqual(model.menuBarClaudeText, "25%")
        try renderBothModes(model, name: "claude-ultra-codex-pro")
    }

    @MainActor
    func testClaudeMaxWithSessionAndCodexPlus() throws {
        let now = Date()
        let model = UsageModel(
            previewBuckets: try codexBuckets(Self.codexPlus, now: now),
            planType: "plus",
            lastUpdated: now.addingTimeInterval(-60),
            claudeBuckets: try claudeBuckets(ClaudeFixtures.withSession, now: now),
            claudePlan: "Max",
            now: { now }
        )

        XCTAssertEqual(model.claudeBuckets.first?.kind, .session)
        try renderBothModes(model, name: "claude-max-codex-plus")
    }

    @MainActor
    func testClaudePausedByAnthropicKeepsItsValues() throws {
        let now = Date()
        let model = UsageModel(
            previewBuckets: try codexBuckets(Self.codexPlus, now: now),
            planType: "plus",
            lastUpdated: now.addingTimeInterval(-25 * 60),
            claudeBuckets: try claudeBuckets(ClaudeFixtures.withoutSession, now: now),
            claudePlan: "Ultra",
            claudePausedUntil: now.addingTimeInterval(35 * 60),
            now: { now }
        )

        XCTAssertTrue(model.sectionMessage(for: .claude)?.hasPrefix("Anthropic paused usage updates. Showing values from") == true)
        XCTAssertFalse(model.claudeBuckets.isEmpty)
        try renderBothModes(model, name: "claude-paused")
    }

    @MainActor
    func testEveryProviderAtOnce() throws {
        AppTheme.loadFont()
        let now = Date()
        let model = UsageModel(
            previewBuckets: try codexBuckets(Self.codexProWeeklyOnly, now: now),
            planType: "pro",
            lastUpdated: now.addingTimeInterval(-60),
            claudeBuckets: try claudeBuckets(ClaudeFixtures.withoutSession, now: now),
            claudePlan: "Ultra",
            cursorBuckets: try unifiedCursorBuckets(now: now),
            cursorPlan: "Ultra",
            opencodeBuckets: try openCodeBuckets(now: now),
            opencodePlan: OpenCodeLimits.planName,
            commandcodeBuckets: CommandCodeLimits.buckets(from: commandCodeSnapshot(now: now), now: now),
            commandcodePlan: "individual-pro",
            menuBarProviders: Set(LimitBucket.Provider.allCases),
            now: { now }
        )

        XCTAssertEqual(model.menuBarSegments.map(\.provider), LimitBucket.Provider.allCases)
        XCTAssertFalse(model.menuBarSegments.contains { $0.value == MenuBarSegment.placeholder })
        try renderBothModes(model, name: "all-providers")
        try renderBothModes(model, name: "all-providers-full", contentMaxHeight: 2_000)

        let label = MenuBarLabelImage.make(segments: model.menuBarSegments)
        XCTAssertTrue(label.isTemplate)
        for scheme in [ColorScheme.light, .dark] {
            let view = Image(nsImage: label)
                .renderingMode(.template)
                .foregroundStyle(scheme == .dark ? Color.white : Color.black)
                .padding(6)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.93))
            try render(view, to: buildDirectory.appendingPathComponent("UsageBar-menubar-all-providers-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    private func unifiedCursorBuckets(now: Date) throws -> [LimitBucket] {
        let iso = ISO8601DateFormatter()
        let cycleEnd = Int64(now.addingTimeInterval(18 * 86_400).timeIntervalSince1970 * 1_000)
        let period = """
        {"billingCycleStart":"\(cycleEnd - 30 * 86_400_000)","billingCycleEnd":"\(cycleEnd)","spendLimitUsage":{"individualLimit":5000,"individualUsed":1200},"enabled":true}
        """
        let sand = """
        {"currentPeriodStart":"\(iso.string(from: now.addingTimeInterval(-3 * 86_400)))","nextResetTimestampUtc":"\(iso.string(from: now.addingTimeInterval(4 * 86_400)))","usagePercent":37.5,"cursorPlanName":"Ultra","isUnified":true}
        """
        let snapshot = CursorUsageSnapshot(
            period: try JSONDecoder().decode(CursorUsageResponse.self, from: Data(period.utf8)),
            sand: try JSONDecoder().decode(CursorSandUsageStatus.self, from: Data(sand.utf8)),
            planInfo: nil,
            membershipType: nil
        )
        return CursorLimits.layout(for: snapshot, now: now).buckets
    }

    private func openCodeBuckets(now: Date) throws -> [LimitBucket] {
        let iso = ISO8601DateFormatter()
        let payload = """
        {"usage":{
          "rolling":{"status":"ok","percent":18,"resetsAt":"\(iso.string(from: now.addingTimeInterval(3 * 3_600)))"},
          "weekly":{"status":"ok","percent":9,"resetsAt":"\(iso.string(from: now.addingTimeInterval(5 * 86_400)))"},
          "monthly":{"status":"ok","percent":4,"resetsAt":"\(iso.string(from: now.addingTimeInterval(20 * 86_400)))"}}}
        """
        return OpenCodeLimits.buckets(from: try JSONDecoder().decode(OpenCodeUsageResponse.self, from: Data(payload.utf8)), now: now)
    }

    private func commandCodeSnapshot(now: Date) -> CommandCodeUsageSnapshot {
        func millis(_ offset: TimeInterval) -> Double { (now.timeIntervalSince1970 + offset) * 1_000 }
        return CommandCodeUsageSnapshot(
            planId: "individual-pro",
            subscriptionStatus: "active",
            currentPeriodEnd: ISO8601DateFormatter().string(from: now.addingTimeInterval(16 * 86_400)),
            credits: CommandCodeCreditsResponse.Credits(monthlyCredits: 21, purchasedCredits: 0, freeCredits: 0),
            windowLimits: CommandCodeCreditsResponse.WindowLimits(
                limited: true,
                fiveHour: CommandCodeWindow(used: 1.2, cap: 4, exceeded: false, resetAt: millis(2 * 3_600)),
                weekly: CommandCodeWindow(used: 5, cap: 12, exceeded: false, resetAt: millis(3 * 86_400))
            ),
            monthlyUsed: 9
        )
    }

    @MainActor
    func testSettingsShowsPopoverAndMenuBarTogglesAndTheClaudeFallback() throws {
        AppTheme.loadFont()
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = UsageModel(
            previewBuckets: [],
            planType: "pro",
            lastUpdated: Date(),
            menuBarProviders: [.codex, .claude],
            popoverProviders: [.codex, .claude, .cursor],
            defaults: defaults
        )
        let updater = stubUpdater(defaults: defaults)
        for scheme in [ColorScheme.light, .dark] {
            let view = SettingsView()
                .environmentObject(model)
                .environmentObject(updater)
                .environment(\.colorScheme, scheme)
            let hostingView = NSHostingView(rootView: view)
            hostingView.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            hostingView.frame = NSRect(x: 0, y: 0, width: 448, height: 900)
            hostingView.layoutSubtreeIfNeeded()
            let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
            hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
            let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            try png.write(to: buildDirectory.appendingPathComponent("UsageBar-settings-\(scheme == .dark ? "dark" : "light").png"))
        }
        XCTAssertTrue(model.isVisibleInPopover(.cursor))
        XCTAssertFalse(model.isVisibleInMenuBar(.cursor))
        XCTAssertFalse(model.claudeQuotaCheckEnabled)
    }

    private static let codexProWeeklyOnly = """
    {"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,
     "primary_window":{"used_percent":38,"limit_window_seconds":604800,"reset_after_seconds":302400,"reset_at":null},
     "secondary_window":null},
     "credits":{"has_credits":false,"unlimited":false,"balance":null},
     "spend_control":{"reached":false,"individual_limit":null},"rate_limit_reached_type":null}
    """

    private static let codexPlus = """
    {"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,
     "primary_window":{"used_percent":22,"limit_window_seconds":18000,"reset_after_seconds":7800,"reset_at":null},
     "secondary_window":{"used_percent":41,"limit_window_seconds":604800,"reset_after_seconds":266400,"reset_at":null}},
     "rate_limit_reached_type":null}
    """

    private func codexBuckets(_ json: String, now: Date) throws -> [LimitBucket] {
        CodexLimits.buckets(from: try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8)), now: now)
    }

    private func claudeBuckets(_ json: String, now: Date) throws -> [LimitBucket] {
        let fixtureNow = Date(timeIntervalSince1970: 1_793_570_400)
        return ClaudeLimits.buckets(from: try ClaudeFixtures.decode(json), now: fixtureNow).map { bucket in
            let resetAt = bucket.resetAt.map { now.addingTimeInterval($0.timeIntervalSince(fixtureNow)) }
            return LimitBucket(
                provider: bucket.provider,
                kind: bucket.kind,
                scope: bucket.scope,
                name: bucket.name,
                usedPercent: bucket.usedPercent,
                resetAt: resetAt,
                resetAfterSeconds: resetAt.map { Int($0.timeIntervalSince(now)) },
                limitWindowSeconds: bucket.limitWindowSeconds,
                reached: bucket.reached,
                detail: bucket.detail,
                isActive: bucket.isActive
            )
        }
    }

    @MainActor
    private func renderBothModes(_ model: UsageModel, name: String, contentMaxHeight: CGFloat = 434) throws {
        AppTheme.loadFont()
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let updater = stubUpdater(defaults: defaults)
        for scheme in [ColorScheme.light, .dark] {
            let url = buildDirectory.appendingPathComponent("UsageBar-\(name)-\(scheme == .dark ? "dark" : "light").png")
            try render(
                UsageMenuView(contentMaxHeight: contentMaxHeight)
                    .environmentObject(model)
                    .environmentObject(updater)
                    .environment(\.colorScheme, scheme),
                to: url
            )
            let image = try XCTUnwrap(NSImage(contentsOf: url))
            XCTAssertEqual(image.size.width, UsageMenuView.width, accuracy: 0.5)
        }
    }

    private var buildDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
    }

    private func bucket(
        provider: LimitBucket.Provider = .codex,
        kind: LimitBucket.Kind,
        name: String
    ) -> LimitBucket {
        LimitBucket(
            provider: provider,
            kind: kind,
            name: name,
            usedPercent: 0,
            resetAt: Date(timeIntervalSince1970: 1_786_402_800),
            resetAfterSeconds: 177_600,
            limitWindowSeconds: 604_800,
            reached: false
        )
    }

    @MainActor
    private func render<Content: View>(_ content: Content, to url: URL) throws {
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let pngData = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try pngData.write(to: url, options: .atomic)
    }

    private func containsScrollView(in view: NSView) -> Bool {
        view is NSScrollView || view.subviews.contains(where: containsScrollView)
    }
}

@MainActor
private func stubUpdater(defaults: UserDefaults) -> AppUpdater {
    defaults.set(false, forKey: UpdatePreferences.checksKey)
    return AppUpdater(
        client: SilentGitHub(),
        installer: SilentInstaller(),
        defaults: defaults,
        currentVersion: "1.0.0"
    )
}

private struct SilentGitHub: GitHubReleasing {
    func latestRelease() async throws -> GitHubRelease {
        throw UpdateError.noReleases
    }
}

private struct SilentInstaller: AppUpdateInstalling {
    func install(fromAppBundle url: URL) throws {}
    func relaunch() throws {}
}
