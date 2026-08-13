import AppKit
import SwiftUI
import XCTest
@testable import UsageBar

final class AppThemeTests: XCTestCase {
    func testEveryWeightStaysInInstrumentSans() throws {
        AppTheme.loadFont()

        for weight in [Font.Weight.regular, .medium, .semibold, .bold] {
            let font = try XCTUnwrap(AppTheme.nsFont(size: 13, weight: weight))
            XCTAssertEqual(font.familyName, "Instrument Sans")
            XCTAssertEqual(font.pointSize, 13)
        }
    }

    func testHeavierWeightsResolveToDistinctFaces() throws {
        AppTheme.loadFont()

        let regular = try XCTUnwrap(AppTheme.nsFont(size: 13)).fontName
        let semibold = try XCTUnwrap(AppTheme.nsFont(size: 13, weight: .semibold)).fontName
        let bold = try XCTUnwrap(AppTheme.nsFont(size: 13, weight: .bold)).fontName

        XCTAssertNotEqual(regular, semibold)
        XCTAssertNotEqual(semibold, bold)
    }

    func testCardFillUsesOpaqueInkInsteadOfVibrantPrimary() {
        XCTAssertEqual(AppTheme.ink(colorScheme: .light).hexString, "#000000")
        XCTAssertEqual(AppTheme.ink(colorScheme: .dark).hexString, "#FFFFFF")
        XCTAssertEqual(AppTheme.cardFill(colorScheme: .light).hexString, "#000000")
        XCTAssertEqual(AppTheme.cardFill(colorScheme: .dark).hexString, "#FFFFFF")
    }

    func testMenuBackgroundIsOpaqueInEveryAppearance() {
        for colorScheme in [ColorScheme.light, .dark] {
            let background = NSColor(AppTheme.menuBackground(colorScheme: colorScheme))
                .usingColorSpace(.sRGB) ?? NSColor(AppTheme.menuBackground(colorScheme: colorScheme))

            XCTAssertEqual(background.alphaComponent, 1, accuracy: 0.001)
        }
    }

    func testSecondaryLabelStaysDarkInLightAppearance() throws {
        let light = NSColor(AppTheme.secondaryLabel(colorScheme: .light))
            .usingColorSpace(.sRGB) ?? NSColor(AppTheme.secondaryLabel(colorScheme: .light))
        let dark = NSColor(AppTheme.secondaryLabel(colorScheme: .dark))
            .usingColorSpace(.sRGB) ?? NSColor(AppTheme.secondaryLabel(colorScheme: .dark))

        let lightLuma = light.redComponent + light.greenComponent + light.blueComponent
        let darkLuma = dark.redComponent + dark.greenComponent + dark.blueComponent

        XCTAssertLessThan(lightLuma, 1.5)
        XCTAssertGreaterThan(darkLuma, 1.5)
    }
}
