import AppKit
import SwiftUI
import XCTest
@testable import UsageBar

final class MenuBarLabelSnapshotTests: XCTestCase {
    @MainActor
    func testMenuBarLabelShowsCodexAndClaude() throws {
        AppTheme.loadFont()
        let model = UsageModel(
            previewBuckets: [codexBucket],
            planType: "prolite",
            lastUpdated: Date(),
            claudeBuckets: [claudeAllModelsBucket],
            claudePlan: "max"
        )

        XCTAssertEqual(model.menuBarText, "99%")
        XCTAssertEqual(model.menuBarClaudeDisplay, "100%")
        XCTAssertEqual(model.menuBarSegments.map(\.value), ["99%", "100%"])

        let label = MenuBarLabelImage.make(segments: model.menuBarSegments)
        XCTAssertTrue(label.isTemplate)
        XCTAssertGreaterThan(label.size.width, MenuBarLabelImage.iconSize * 2)

        let other = MenuBarLabelImage.make(codex: "12%", claude: "34%")
        XCTAssertNotEqual(label.tiffRepresentation, other.tiffRepresentation)

        try render(
            MenuBarLabel(model: model),
            to: buildDirectory.appendingPathComponent("UsageBar-menubar.png")
        )
    }

    @MainActor
    func testClaudeSegmentKeepsItsPlaceWithoutData() {
        let model = UsageModel(
            previewBuckets: [codexBucket],
            planType: "prolite",
            lastUpdated: Date()
        )

        XCTAssertNil(model.menuBarClaudeText)
        XCTAssertEqual(model.menuBarClaudeDisplay, "–")
        XCTAssertEqual(model.menuBarSegments.map(\.value), ["99%", "–"])
    }

    @MainActor
    func testMenuBarOmitsHiddenProviders() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let model = UsageModel(
            previewBuckets: [codexBucket],
            planType: "prolite",
            lastUpdated: Date(),
            claudeBuckets: [claudeAllModelsBucket],
            claudePlan: "max",
            cursorBuckets: [
                LimitBucket(
                    provider: .cursor,
                    kind: .cursorModels,
                    name: "Cursor Models",
                    usedPercent: 10,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: 2_678_400,
                    reached: false
                )
            ],
            cursorPlan: "pro",
            menuBarProviders: [.codex, .cursor],
            defaults: defaults
        )

        XCTAssertEqual(model.menuBarSegments.map(\.value), ["99%", "90%"])
        XCTAssertEqual(model.menuBarAccessibilityLabel, "Codex limits, 99 percent left. Cursor models, 90 percent left")

        model.setVisibleInMenuBar(.claude, visible: true)
        model.setVisibleInMenuBar(.codex, visible: false)
        XCTAssertEqual(model.menuBarSegments.map(\.value), ["100%", "90%"])
    }

    @MainActor
    func testLastMenuBarProviderCannotBeHidden() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let model = UsageModel(
            previewBuckets: [codexBucket],
            planType: "prolite",
            lastUpdated: Date(),
            menuBarProviders: [.codex],
            defaults: defaults
        )

        model.setVisibleInMenuBar(.codex, visible: false)
        XCTAssertEqual(model.menuBarProviders, [.codex])
        XCTAssertFalse(model.canHideMenuBarProvider)
    }

    private var codexBucket: LimitBucket {
        LimitBucket(
            kind: .primary,
            name: "weekly",
            usedPercent: 1,
            resetAt: nil,
            resetAfterSeconds: nil,
            limitWindowSeconds: 604_800,
            reached: false
        )
    }

    private var claudeAllModelsBucket: LimitBucket {
        LimitBucket(
            provider: .claude,
            kind: .weeklyAll,
            name: "Week · All models",
            usedPercent: 0,
            resetAt: nil,
            resetAfterSeconds: nil,
            limitWindowSeconds: 604_800,
            reached: false
        )
    }

    private var buildDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
    }

    @MainActor
    private func render<Content: View>(_ content: Content, to url: URL) throws {
        let renderer = ImageRenderer(
            content: content
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 4

        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)
    }
}
