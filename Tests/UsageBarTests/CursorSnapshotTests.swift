import AppKit
import SwiftUI
import XCTest
@testable import UsageBar

final class CursorSnapshotTests: XCTestCase {
    private let now = Date()

    @MainActor
    func testUnifiedCursorNextToCodex() throws {
        let model = try menuModel(cursor: unifiedLayout())
        let light = try renderBothSchemes(UsageMenuView(), model: model, name: "cursor-unified")

        XCTAssertEqual(model.cursorBuckets.map(\.kind), [.weekly, .spendLimit])
        XCTAssertGreaterThan(light.size.height, 200)
    }

    @MainActor
    func testLegacyCursorWithSeparateGrokBotPool() throws {
        let model = try menuModel(cursor: legacyLayout())
        _ = try renderBothSchemes(UsageMenuView(), model: model, name: "cursor-legacy")

        XCTAssertEqual(model.cursorBuckets.map(\.kind), [.cursorModels, .otherModels, .grokBot])
    }

    @MainActor
    func testCursorNotSignedInLine() throws {
        let model = UsageModel(
            previewBuckets: [codexBucket()],
            planType: "plus",
            lastUpdated: now,
            menuBarProviders: [.codex, .cursor],
            cursorAvailable: false
        )
        _ = try renderBothSchemes(UsageMenuView(), model: model, name: "cursor-signed-out")

        XCTAssertEqual(model.sectionMessage(for: .cursor), CursorUsageError.notSignedIn.errorDescription)
    }

    @MainActor
    func testSettingsCursorSessionTokenField() throws {
        let model = UsageModel(previewBuckets: [], planType: "plus", lastUpdated: now, menuBarProviders: [.cursor])
        for (saved, suffix) in [(false, "empty"), (true, "saved")] {
            let stub = CursorSessionTokenActions(hasToken: { saved }, save: { _ in .saved }, remove: { true })
            let form = Form {
                CursorSessionTokenSection(actions: stub, hasSavedToken: saved)
            }
            .formStyle(.grouped)
            .frame(width: 448, height: 150)
            .environment(\.font, AppTheme.font(size: 13))
            _ = try renderBothSchemes(form, model: model, name: "settings-cursor-token-\(suffix)")
        }
    }

    @MainActor
    func testMenuBarLabelWithCodexAndUnifiedCursor() throws {
        AppTheme.loadFont()
        let model = try menuModel(cursor: unifiedLayout())
        let label = MenuBarLabelImage.make(segments: model.menuBarSegments)

        XCTAssertEqual(model.menuBarSegments.map(\.value), ["58%", "62%"])
        XCTAssertTrue(label.isTemplate)
        XCTAssertTrue(model.menuBarAccessibilityLabel.contains("Cursor weekly usage, 62 percent left"))

        for scheme in [ColorScheme.light, .dark] {
            let view = Image(nsImage: label)
                .renderingMode(.template)
                .foregroundStyle(scheme == .dark ? Color.white : Color.black)
                .padding(6)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.93))
            try render(view, to: shotURL("menubar-codex-cursor-\(scheme == .dark ? "dark" : "light")"))
        }
    }

    private func unifiedLayout() throws -> CursorLayout {
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(4 * 86_400 + 3 * 3_600))
        let start = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3 * 86_400 + 3 * 3_600))
        let cycleEnd = Int64(now.addingTimeInterval(18 * 86_400).timeIntervalSince1970 * 1_000)
        let cycleStart = cycleEnd - 30 * 86_400_000
        return try layout(
            period: """
            {"billingCycleStart":"\(cycleStart)","billingCycleEnd":"\(cycleEnd)","planUsage":{"totalPercentUsed":37.5},"spendLimitUsage":{"individualLimit":5000,"individualUsed":1200,"limitType":"user"},"enabled":true}
            """,
            sand: """
            {"currentPeriodStart":"\(start)","nextResetTimestampUtc":"\(reset)","usagePercent":37.5,"hasNonZeroIncludedLimit":true,"cursorPlanName":"Ultra","isUnified":true,"billingBrand":"SAND_BILLING_BRAND_GROK"}
            """
        )
    }

    private func legacyLayout() throws -> CursorLayout {
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(2 * 86_400 + 5 * 3_600))
        let cycleEnd = Int64(now.addingTimeInterval(12 * 86_400).timeIntervalSince1970 * 1_000)
        let cycleStart = cycleEnd - 30 * 86_400_000
        return try layout(
            period: """
            {"billingCycleStart":"\(cycleStart)","billingCycleEnd":"\(cycleEnd)","planUsage":{"autoPercentUsed":42.4,"apiPercentUsed":10.6},"enabled":true}
            """,
            sand: """
            {"nextResetTimestampUtc":"\(reset)","usagePercent":49.3,"hasAvailableUsage":true,"hasNonZeroIncludedLimit":true,"grokPlanLabel":"Grok Bot Plan"}
            """
        )
    }

    private func layout(period: String, sand: String) throws -> CursorLayout {
        let snapshot = CursorUsageSnapshot(
            period: try JSONDecoder().decode(CursorUsageResponse.self, from: Data(period.utf8)),
            sand: try JSONDecoder().decode(CursorSandUsageStatus.self, from: Data(sand.utf8)),
            planInfo: nil,
            membershipType: "pro"
        )
        return CursorLimits.layout(for: snapshot, now: now)
    }

    @MainActor
    private func menuModel(cursor: CursorLayout) throws -> UsageModel {
        UsageModel(
            previewBuckets: [codexBucket()],
            planType: "plus",
            lastUpdated: now,
            cursorBuckets: cursor.buckets,
            cursorPlan: cursor.plan,
            menuBarProviders: [.codex, .cursor]
        )
    }

    private func codexBucket() -> LimitBucket {
        LimitBucket(
            kind: .primary,
            name: "Current Session",
            usedPercent: 42,
            resetAt: now.addingTimeInterval(2 * 3_600 + 14 * 60),
            resetAfterSeconds: 2 * 3_600 + 14 * 60,
            limitWindowSeconds: 18_000,
            reached: false
        )
    }

    @MainActor
    private func renderBothSchemes<Content: View>(_ content: Content, model: UsageModel, name: String) throws -> NSImage {
        AppTheme.loadFont()
        let suiteName = "CursorSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: UpdatePreferences.checksKey)
        let updater = AppUpdater(
            client: SnapshotSilentGitHub(),
            installer: SnapshotSilentInstaller(),
            defaults: defaults,
            currentVersion: "1.0.0"
        )
        for scheme in [ColorScheme.light, .dark] {
            let view = content
                .environmentObject(model)
                .environmentObject(updater)
                .environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(white: 0.12) : Color.white)
            try render(view, to: shotURL("\(name)-\(scheme == .dark ? "dark" : "light")"))
        }
        return try XCTUnwrap(NSImage(contentsOf: shotURL("\(name)-light")))
    }

    private func shotURL(_ name: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/UsageBar-\(name).png")
    }

    @MainActor
    private func render<Content: View>(_ content: Content, to url: URL) throws {
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)
    }
}

private struct SnapshotSilentGitHub: GitHubReleasing {
    func latestRelease() async throws -> GitHubRelease {
        throw UpdateError.noReleases
    }
}

private struct SnapshotSilentInstaller: AppUpdateInstalling {
    func install(fromAppBundle url: URL) throws {}
    func relaunch() throws {}
}
