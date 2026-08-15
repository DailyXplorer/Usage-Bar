import AppKit
import SwiftUI
import XCTest
@testable import UsageBar

final class SettingsSectionHeaderTests: XCTestCase {
    func testLabelFontIsInstrumentSansMediumAtElevenPoints() throws {
        AppTheme.loadFont()
        let font = try XCTUnwrap(
            AppTheme.nsFont(
                size: SettingsSectionHeader.fontSize,
                weight: SettingsSectionHeader.fontWeight
            )
        )
        let regular = try XCTUnwrap(
            AppTheme.nsFont(size: SettingsSectionHeader.fontSize, weight: .regular)
        )

        XCTAssertEqual(SettingsSectionHeader.fontSize, 11)
        XCTAssertEqual(SettingsSectionHeader.fontWeight, Font.Weight.medium)
        XCTAssertEqual(font.familyName, "Instrument Sans")
        XCTAssertEqual(font.pointSize, 11)
        XCTAssertNotEqual(font.fontName, regular.fontName)
    }

    @MainActor
    func testRenderedHeaderMatchesMenuSectionTitleFace() throws {
        AppTheme.loadFont()
        let title = "Visible plans"
        let actual = try pngData(for: SettingsSectionHeader(title: title))
        let expected = try pngData(
            for: Text(title)
                .font(SettingsSectionHeader.labelFont)
                .appSecondaryLabelStyle()
                .textCase(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        )
        let rowSized = try pngData(
            for: Text(title)
                .font(AppTheme.font(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        )

        XCTAssertEqual(actual, expected)
        XCTAssertNotEqual(actual, rowSized)
    }

    @MainActor
    func testEverySettingsSectionTitleRendersAtTheSameHeight() throws {
        AppTheme.loadFont()
        let heights = try ["Visible plans", "General", "Updates"].map { title in
            try pngSize(for: SettingsSectionHeader(title: title)).height
        }

        XCTAssertEqual(heights[0], heights[1])
        XCTAssertEqual(heights[1], heights[2])
    }
}

@MainActor
private func pngData(for view: some View) throws -> Data {
    let renderer = ImageRenderer(
        content: view
            .frame(width: 200)
            .padding(12)
            .background(Color.white)
            .environment(\.colorScheme, .light)
    )
    renderer.scale = 2
    let image = try XCTUnwrap(renderer.nsImage)
    let tiffData = try XCTUnwrap(image.tiffRepresentation)
    let representation = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
    return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
}

@MainActor
private func pngSize(for view: some View) throws -> CGSize {
    let renderer = ImageRenderer(
        content: view
            .frame(width: 200)
            .environment(\.colorScheme, .light)
    )
    renderer.scale = 2
    let image = try XCTUnwrap(renderer.nsImage)
    return image.size
}
