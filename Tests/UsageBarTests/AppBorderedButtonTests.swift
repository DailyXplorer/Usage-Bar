import AppKit
import SwiftUI
import XCTest
@testable import UsageBar

final class AppBorderedButtonTests: XCTestCase {
    func testControlFaceIsInstrumentSansAtElevenPointMedium() throws {
        AppTheme.loadFont()
        let font = try XCTUnwrap(AppTheme.nsFont(size: 11, weight: .medium))

        XCTAssertEqual(font.familyName, "Instrument Sans")
        XCTAssertEqual(font.pointSize, 11)
    }

    @MainActor
    func testLabelFontChangesTheRenderedButton() throws {
        AppTheme.loadFont()

        let styled = try pngData(
            for: AppBorderedButton(title: "Check for Updates", action: {})
        )
        let systemTitle = try pngData(
            for: Button("Check for Updates", action: {})
                .buttonStyle(.bordered)
                .controlSize(.small)
        )

        XCTAssertNotEqual(
            styled,
            systemTitle,
            "Instrument Sans on the Text label must change the bordered button from the system face"
        )
    }
}

@MainActor
private func pngData(for view: some View) throws -> Data {
    let renderer = ImageRenderer(
        content: view
            .padding(12)
            .background(Color.white)
    )
    renderer.scale = 2
    let image = try XCTUnwrap(renderer.nsImage)
    let tiffData = try XCTUnwrap(image.tiffRepresentation)
    let representation = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
    return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
}
