import AppKit
import SwiftUI
import XCTest
@testable import UsageBar

final class AppControlFontTests: XCTestCase {
    func testApplyUsesInstrumentSansOnAnEnclosingButton() throws {
        AppTheme.loadFont()
        let font = try XCTUnwrap(AppTheme.nsFont(size: 11, weight: .medium))
        let button = NSButton(title: "Try Again", target: nil, action: nil)
        button.font = NSFont.systemFont(ofSize: 13)
        let probe = NSView(frame: .zero)
        button.addSubview(probe)

        AppControlFont.apply(font, startingAt: probe)

        XCTAssertEqual(button.font?.familyName, "Instrument Sans")
        XCTAssertEqual(button.font?.pointSize, 11)
    }

    func testApplyUsesInstrumentSansOnASiblingButton() throws {
        AppTheme.loadFont()
        let font = try XCTUnwrap(AppTheme.nsFont(size: 11, weight: .medium))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 32))
        let button = NSButton(title: "Try Again", target: nil, action: nil)
        button.font = NSFont.systemFont(ofSize: 13)
        let probe = NSView(frame: .zero)
        container.addSubview(button)
        container.addSubview(probe)

        AppControlFont.apply(font, startingAt: probe)

        XCTAssertEqual(button.font?.familyName, "Instrument Sans")
        XCTAssertEqual(button.font?.pointSize, 11)
    }

    func testEnclosingButtonIgnoresAncestorsWithSeveralButtons() {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        let first = NSButton(title: "One", target: nil, action: nil)
        let second = NSButton(title: "Two", target: nil, action: nil)
        let host = NSView(frame: .zero)
        let probe = NSView(frame: .zero)
        host.addSubview(second)
        host.addSubview(probe)
        row.addSubview(first)
        row.addSubview(host)

        XCTAssertEqual(AppControlFont.enclosingButton(from: probe), second)
    }
}
