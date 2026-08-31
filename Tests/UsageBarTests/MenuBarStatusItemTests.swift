import AppKit
import XCTest
@testable import UsageBar

@MainActor
final class MenuBarStatusItemTests: XCTestCase {
    func testVariableLengthTracksCompactImageWidthInBothDirections() throws {
        AppTheme.loadFont()
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }

        let button = try XCTUnwrap(statusItem.button)
        let buttonIdentifier = ObjectIdentifier(button)
        let compact = image(values: ["8%"])
        let maximum = image(values: ["100%"])

        let compactWidth = apply(compact, to: button)
        let maximumWidth = apply(maximum, to: button)
        let compactAgainWidth = apply(compact, to: button)

        XCTAssertEqual(statusItem.length, NSStatusItem.variableLength)
        XCTAssertEqual(ObjectIdentifier(button), buttonIdentifier)
        XCTAssertEqual(
            maximumWidth - compactWidth,
            maximum.size.width - compact.size.width,
            accuracy: 1
        )
        XCTAssertEqual(compactAgainWidth, compactWidth, accuracy: 1)
        XCTAssertEqual(
            compactWidth - compact.size.width,
            maximumWidth - maximum.size.width,
            accuracy: 1
        )
    }

    func testVariableLengthTracksProviderCountInBothDirections() throws {
        AppTheme.loadFont()
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }

        let button = try XCTUnwrap(statusItem.button)
        let single = image(values: ["81%"])
        let maximum = image(values: Array(repeating: "81%", count: 5))

        let singleWidth = apply(single, to: button)
        let maximumWidth = apply(maximum, to: button)
        let singleAgainWidth = apply(single, to: button)

        XCTAssertEqual(
            maximumWidth - singleWidth,
            maximum.size.width - single.size.width,
            accuracy: 1
        )
        XCTAssertEqual(singleAgainWidth, singleWidth, accuracy: 1)
    }

    private func apply(_ image: NSImage, to button: NSStatusBarButton) -> CGFloat {
        let previousButtonWidth = button.frame.width
        let previousImageWidth = button.image?.size.width
        let expectsWidthChange = previousImageWidth.map {
            abs($0 - image.size.width) > 0.01
        } ?? true
        button.image = image
        var previous = button.frame.width
        var sawExpectedChange = !expectsWidthChange
        var stableReadCount = 0
        let deadline = Date().addingTimeInterval(1)

        while stableReadCount < 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            let current = button.frame.width
            if abs(current - previousButtonWidth) > 0.01 {
                sawExpectedChange = true
            }
            if sawExpectedChange, abs(current - previous) <= 0.01 {
                stableReadCount += 1
            } else {
                stableReadCount = 0
            }
            previous = current
        }

        XCTAssertTrue(sawExpectedChange)
        return button.frame.width
    }

    private func image(values: [String]) -> NSImage {
        let providers = Array(LimitBucket.Provider.allCases.prefix(values.count))
        let segments = zip(providers, values).map { provider, value in
            MenuBarSegment(
                provider: provider,
                logo: AppTheme.logo(for: provider),
                value: value
            )
        }
        return MenuBarLabelImage.make(segments: segments, scale: 2)
    }
}
