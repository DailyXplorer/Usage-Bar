import AppKit
import SwiftUI
import XCTest
@testable import UsageBar

final class AppBorderedButtonTests: XCTestCase {
    func testLabelFontIsDMSansMediumAtElevenPoints() throws {
        AppTheme.loadFont()
        let font = try XCTUnwrap(
            AppTheme.nsFont(
                size: AppBorderedButton.fontSize,
                weight: AppBorderedButton.fontWeight
            )
        )
        let regular = try XCTUnwrap(
            AppTheme.nsFont(size: AppBorderedButton.fontSize, weight: .regular)
        )

        XCTAssertEqual(AppBorderedButton.fontSize, 11)
        XCTAssertEqual(AppBorderedButton.fontWeight, Font.Weight.medium)
        XCTAssertEqual(font.familyName, "DM Sans")
        XCTAssertEqual(font.pointSize, 11)
        XCTAssertNotEqual(font.fontName, regular.fontName)
    }

    @MainActor
    func testRenderedLabelMatchesDMSansMediumReference() throws {
        AppTheme.loadFont()
        let title = "Check for Updates"
        let actual = try pngData(for: AppBorderedButton(title: title, action: {}))
        let expected = try pngData(
            for: Button(action: {}) {
                Text(title)
                    .font(AppBorderedButton.labelFont)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        )
        let systemTitle = try pngData(
            for: Button(title, action: {})
                .buttonStyle(.bordered)
                .controlSize(.small)
        )
        let regularWeight = try pngData(
            for: Button(action: {}) {
                Text(title)
                    .font(AppTheme.font(size: AppBorderedButton.fontSize, weight: .regular))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        )

        XCTAssertEqual(actual, expected)
        XCTAssertNotEqual(actual, systemTitle)
        XCTAssertNotEqual(actual, regularWeight)
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
