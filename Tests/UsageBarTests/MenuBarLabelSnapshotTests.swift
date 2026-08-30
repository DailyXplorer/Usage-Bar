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
            Image(nsImage: label)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.menuBarAccessibilityLabel),
            to: buildDirectory.appendingPathComponent("UsageBar-menubar.png")
        )
    }

    @MainActor
    func testMenuBarLabelWidthFollowsDigitCount() {
        AppTheme.loadFont()
        let oneDigit = labelImage(values: ["8%", "8%"])
        let twoDigit = labelImage(values: ["81%", "86%"])
        let threeDigit = labelImage(values: ["100%", "100%"])

        XCTAssertLessThan(oneDigit.size.width, twoDigit.size.width)
        XCTAssertLessThan(twoDigit.size.width, threeDigit.size.width)
        for image in [oneDigit, twoDigit, threeDigit] {
            XCTAssertLessThanOrEqual(trailingClearPoints(in: image), 2)
        }
        XCTAssertTrue(twoDigit.isTemplate)
    }

    @MainActor
    func testMenuBarLabelKeepsEvenGapsAsPercentagesChange() {
        AppTheme.loadFont()
        let compact = labelImage(values: ["8%", "8%", "8%", "8%"])
        let maximum = labelImage(values: ["100%", "100%", "100%", "100%"])

        XCTAssertLessThan(compact.size.width, maximum.size.width)
        XCTAssertEqual(
            largestInternalClearRunPoints(in: compact),
            largestInternalClearRunPoints(in: maximum),
            accuracy: 2
        )
        XCTAssertLessThanOrEqual(trailingClearPoints(in: compact), 2)
        XCTAssertLessThanOrEqual(trailingClearPoints(in: maximum), 2)
    }

    @MainActor
    func testMenuBarPlaceholderHasCompactFrame() {
        AppTheme.loadFont()
        let placeholder = MenuBarLabelImage.make(segments: [
            MenuBarSegment(provider: .claude, logo: AppTheme.claudeLogo, value: MenuBarSegment.placeholder)
        ])
        let twoDigit = MenuBarLabelImage.make(segments: [
            MenuBarSegment(provider: .claude, logo: AppTheme.claudeLogo, value: "22%")
        ])
        let maximum = MenuBarLabelImage.make(segments: [
            MenuBarSegment(provider: .claude, logo: AppTheme.claudeLogo, value: "100%")
        ])

        XCTAssertLessThan(placeholder.size.width, maximum.size.width)
        XCTAssertLessThan(twoDigit.size.width, maximum.size.width)
        for image in [placeholder, twoDigit, maximum] {
            XCTAssertLessThanOrEqual(trailingClearPoints(in: image), 2)
        }
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
    private func labelImage(values: [String]) -> NSImage {
        let providers = Array(LimitBucket.Provider.allCases.prefix(values.count))
        let segments = zip(providers, values).map { provider, value in
            MenuBarSegment(provider: provider, logo: AppTheme.logo(for: provider), value: value)
        }
        return MenuBarLabelImage.make(segments: segments)
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

    private func largestInternalClearRunPoints(in image: NSImage) -> CGFloat {
        let columns = inkColumns(in: image)
        guard let firstInk = columns.firstIndex(of: true),
              let lastInk = columns.lastIndex(of: true) else {
            return 0
        }
        var largest = 0
        var index = firstInk
        while index <= lastInk {
            if columns[index] {
                index += 1
                continue
            }
            let start = index
            index += 1
            while index <= lastInk, !columns[index] {
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
