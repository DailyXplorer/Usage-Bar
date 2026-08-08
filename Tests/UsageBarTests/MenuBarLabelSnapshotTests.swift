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

        let label = MenuBarLabelImage.make(codex: model.menuBarText, claude: model.menuBarClaudeDisplay)
        XCTAssertTrue(label.isTemplate)
        XCTAssertGreaterThan(label.size.width, MenuBarLabelImage.iconSize * 2)

        // Les deux valeurs doivent bien atteindre le rendu : à valeurs
        // différentes, pixels différents.
        let other = MenuBarLabelImage.make(codex: "12%", claude: "34%")
        XCTAssertNotEqual(label.tiffRepresentation, other.tiffRepresentation)

        try render(
            MenuBarLabel(model: model),
            to: buildDirectory.appendingPathComponent("UsageBar-menubar.png")
        )
    }

    /// Sans session Claude, le segment reste en place avec un tiret : sa
    /// hiérarchie doit exister dès le premier rendu pour pouvoir se remplir.
    @MainActor
    func testClaudeSegmentKeepsItsPlaceWithoutData() {
        let model = UsageModel(
            previewBuckets: [codexBucket],
            planType: "prolite",
            lastUpdated: Date()
        )

        XCTAssertNil(model.menuBarClaudeText)
        XCTAssertEqual(model.menuBarClaudeDisplay, "–")
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
