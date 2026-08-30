import AppKit
import XCTest
@testable import UsageBar

final class MenuBarStatusItemTests: XCTestCase {
    @MainActor
    func testApplyLengthGrowsAStatusItemToTheImageWidth() {
        AppTheme.loadFont()
        let short = MenuBarLabelImage.make(segments: [
            MenuBarSegment(provider: .codex, logo: AppTheme.codexLogo, value: "8%")
        ])
        let long = MenuBarLabelImage.make(segments: [
            MenuBarSegment(provider: .codex, logo: AppTheme.codexLogo, value: "100%")
        ])
        XCTAssertLessThan(short.size.width, long.size.width)

        let item = NSStatusBar.system.statusItem(withLength: short.size.width)
        defer { NSStatusBar.system.removeStatusItem(item) }
        item.button?.image = short
        XCTAssertEqual(item.length, short.size.width, accuracy: 0.5)

        MenuBarStatusItem.applyLength(long.size.width, to: item)
        XCTAssertEqual(item.length, long.size.width, accuracy: 0.5)
    }

    @MainActor
    func testSyncLengthFindsAnInstalledStatusItem() {
        AppTheme.loadFont()
        let image = MenuBarLabelImage.make(segments: [
            MenuBarSegment(provider: .claude, logo: AppTheme.claudeLogo, value: "100%")
        ])
        let item = NSStatusBar.system.statusItem(withLength: 12)
        defer { NSStatusBar.system.removeStatusItem(item) }
        item.button?.image = image
        XCTAssertNotNil(item.button?.window)

        XCTAssertTrue(
            MenuBarStatusItem.items().contains(where: { $0 === item }),
            "NSStatusBarWindow.statusItem should resolve the installed extra"
        )

        MenuBarStatusItem.syncLength(to: image.size.width)
        XCTAssertEqual(item.length, image.size.width, accuracy: 0.5)
    }
}
