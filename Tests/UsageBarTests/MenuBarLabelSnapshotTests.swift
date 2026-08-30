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
            claudeBuckets: [claudeSessionBucket],
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
    func testMenuBarLabelWidthStaysStableWhenPercentagesLoad() {
        AppTheme.loadFont()
        let loading = MenuBarLabelImage.make(segments: [
            MenuBarSegment(provider: .codex, logo: AppTheme.codexLogo, value: MenuBarSegment.placeholder),
            MenuBarSegment(provider: .cursor, logo: AppTheme.cursorLogo, value: MenuBarSegment.placeholder),
        ])
        let loaded = MenuBarLabelImage.make(segments: [
            MenuBarSegment(provider: .codex, logo: AppTheme.codexLogo, value: "22%"),
            MenuBarSegment(provider: .cursor, logo: AppTheme.cursorLogo, value: "89%"),
        ])
        let maximum = MenuBarLabelImage.make(segments: [
            MenuBarSegment(provider: .codex, logo: AppTheme.codexLogo, value: "100%"),
            MenuBarSegment(provider: .cursor, logo: AppTheme.cursorLogo, value: "100%"),
        ])

        XCTAssertEqual(loading.size.width, loaded.size.width, accuracy: 0.5)
        XCTAssertEqual(loaded.size.width, maximum.size.width, accuracy: 0.5)
        XCTAssertTrue(loaded.isTemplate)
    }

    @MainActor
    func testMenuBarPlaceholderDoesNotLeaveAWideGap() {
        AppTheme.loadFont()
        let dash = MenuBarLabelImage.make(segments: [
            MenuBarSegment(provider: .claude, logo: AppTheme.claudeLogo, value: "–")
        ])
        let placeholder = MenuBarLabelImage.make(segments: [
            MenuBarSegment(provider: .claude, logo: AppTheme.claudeLogo, value: MenuBarSegment.placeholder)
        ])
        let maximum = MenuBarLabelImage.make(segments: [
            MenuBarSegment(provider: .claude, logo: AppTheme.claudeLogo, value: MenuBarSegment.reservedValue)
        ])

        XCTAssertEqual(placeholder.size.width, maximum.size.width, accuracy: 0.5)
        XCTAssertLessThan(trailingClearPoints(in: placeholder), 10)
        XCTAssertLessThan(trailingClearPoints(in: maximum), 10)
        XCTAssertGreaterThan(trailingClearPoints(in: dash), 20)

        let withPlaceholder = MenuBarLabelImage.make(segments: [
            MenuBarSegment(provider: .codex, logo: AppTheme.codexLogo, value: "99%"),
            MenuBarSegment(provider: .claude, logo: AppTheme.claudeLogo, value: MenuBarSegment.placeholder),
            MenuBarSegment(provider: .cursor, logo: AppTheme.cursorLogo, value: "87%"),
        ])
        let withDash = MenuBarLabelImage.make(segments: [
            MenuBarSegment(provider: .codex, logo: AppTheme.codexLogo, value: "99%"),
            MenuBarSegment(provider: .claude, logo: AppTheme.claudeLogo, value: "–"),
            MenuBarSegment(provider: .cursor, logo: AppTheme.cursorLogo, value: "87%"),
        ])
        let withMaximum = MenuBarLabelImage.make(segments: [
            MenuBarSegment(provider: .codex, logo: AppTheme.codexLogo, value: "99%"),
            MenuBarSegment(provider: .claude, logo: AppTheme.claudeLogo, value: MenuBarSegment.reservedValue),
            MenuBarSegment(provider: .cursor, logo: AppTheme.cursorLogo, value: "87%"),
        ])
        XCTAssertEqual(withPlaceholder.size.width, withMaximum.size.width, accuracy: 0.5)
        XCTAssertEqual(
            largestClearRunPoints(in: withPlaceholder),
            largestClearRunPoints(in: withMaximum),
            accuracy: 8
        )
        XCTAssertGreaterThan(
            largestClearRunPoints(in: withDash) - largestClearRunPoints(in: withPlaceholder),
            8
        )
    }

    func testMenuBarSegmentIdentityIncludesProvider() {
        let codex = MenuBarSegment(provider: .codex, logo: nil, value: "50%")
        let cursor = MenuBarSegment(provider: .cursor, logo: nil, value: "50%")

        XCTAssertNotEqual(codex.identity, cursor.identity)
    }

    @MainActor
    func testClaudeSegmentKeepsItsPlaceWithoutData() {
        let model = UsageModel(
            previewBuckets: [codexBucket],
            planType: "prolite",
            lastUpdated: Date()
        )

        XCTAssertNil(model.menuBarClaudeText)
        XCTAssertEqual(model.menuBarClaudeDisplay, MenuBarSegment.placeholder)
        XCTAssertEqual(model.menuBarSegments.map(\.value), ["99%", MenuBarSegment.placeholder])
    }

    @MainActor
    func testMenuBarOmitsHiddenProviders() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let model = UsageModel(
            previewBuckets: [codexBucket],
            planType: "prolite",
            lastUpdated: Date(),
            claudeBuckets: [claudeSessionBucket],
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

    private var claudeSessionBucket: LimitBucket {
        LimitBucket(
            provider: .claude,
            kind: .session,
            name: "Current session",
            usedPercent: 0,
            resetAt: nil,
            resetAfterSeconds: nil,
            limitWindowSeconds: 18_000,
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

    private func trailingClearPoints(in image: NSImage) -> CGFloat {
        let columns = inkColumns(in: image)
        guard let lastInk = columns.lastIndex(of: true) else {
            return image.size.width
        }
        let clearPixels = columns.count - lastInk - 1
        return points(clearPixels, in: image, pixelCount: columns.count)
    }

    private func largestClearRunPoints(in image: NSImage) -> CGFloat {
        let columns = inkColumns(in: image)
        var largest = 0
        var index = 0
        while index < columns.count {
            if columns[index] {
                index += 1
                continue
            }
            let start = index
            index += 1
            while index < columns.count, !columns[index] {
                index += 1
            }
            largest = max(largest, index - start)
        }
        return points(largest, in: image, pixelCount: columns.count)
    }

    private func inkColumns(in image: NSImage) -> [Bool] {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else {
            return []
        }
        let width = representation.pixelsWide
        let height = representation.pixelsHigh
        return (0..<width).map { x in
            (0..<height).contains { y in
                (representation.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.08
            }
        }
    }

    private func points(_ pixels: Int, in image: NSImage, pixelCount: Int) -> CGFloat {
        guard pixelCount > 0 else { return 0 }
        return CGFloat(pixels) * image.size.width / CGFloat(pixelCount)
    }
}
