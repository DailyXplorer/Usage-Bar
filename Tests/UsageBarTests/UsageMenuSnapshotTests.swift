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
                    kind: .lunaReserve,
                    name: CodexLimits.lunaReserveDisplayName,
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
                    limitWindowSeconds: CursorLimits.grokBotWindowSeconds,
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
                bucket(kind: .spark, name: CodexLimits.sparkDisplayName),
                bucket(kind: .lunaReserve, name: CodexLimits.lunaReserveDisplayName),
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
