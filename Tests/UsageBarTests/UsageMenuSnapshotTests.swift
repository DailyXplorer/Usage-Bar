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
                    name: "weekly",
                    usedPercent: 42,
                    resetAt: Date(timeIntervalSince1970: 1_786_189_759),
                    resetAfterSeconds: 231_321,
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
                    name: "Current session",
                    usedPercent: 12,
                    resetAt: Date(timeIntervalSince1970: 1_786_232_400),
                    resetAfterSeconds: 7_200,
                    limitWindowSeconds: 18_000,
                    reached: false
                ),
                LimitBucket(
                    provider: .claude,
                    kind: .weeklyAll,
                    name: "All models",
                    usedPercent: 40,
                    resetAt: Date(timeIntervalSince1970: 1_786_402_800),
                    resetAfterSeconds: 177_600,
                    limitWindowSeconds: 604_800,
                    reached: false
                ),
                LimitBucket(
                    provider: .claude,
                    kind: .weeklyScoped,
                    name: "Opus",
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

        try render(
            UsageMenuView()
                .environmentObject(model)
                .environmentObject(updater)
                .environment(\.colorScheme, .light),
            to: buildDirectory.appendingPathComponent("UsageBar-light.png")
        )
        try render(
            UsageMenuView()
                .environmentObject(model)
                .environmentObject(updater)
                .environment(\.colorScheme, .dark),
            to: buildDirectory.appendingPathComponent("UsageBar-dark.png")
        )
    }

    @MainActor
    private func render<Content: View>(_ content: Content, to url: URL) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.nsImage)
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
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
