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

    func testCardFillUsesAppearanceAwareInkAtExpectedOpacity() {
        let cases: [(ColorScheme, String)] = [
            (.light, "#000000"),
            (.dark, "#FFFFFF"),
        ]

        for (colorScheme, expectedHex) in cases {
            let fill = NSColor(AppTheme.cardFill(colorScheme: colorScheme))
                .usingColorSpace(.sRGB) ?? NSColor(AppTheme.cardFill(colorScheme: colorScheme))

            XCTAssertEqual(AppTheme.ink(colorScheme: colorScheme).hexString, expectedHex)
            XCTAssertEqual(AppTheme.cardFill(colorScheme: colorScheme).hexString, expectedHex)
            XCTAssertEqual(fill.alphaComponent, 0.045, accuracy: 0.001)
        }
    }

    func testMenuBackgroundIsOpaqueInEveryAppearance() {
        for colorScheme in [ColorScheme.light, .dark] {
            for contrast in [ColorSchemeContrast.standard, .increased] {
                let backgroundColor = AppTheme.menuBackground(
                    colorScheme: colorScheme,
                    contrast: contrast
                )
                let background = NSColor(backgroundColor).usingColorSpace(.sRGB)
                    ?? NSColor(backgroundColor)

                XCTAssertEqual(background.alphaComponent, 1, accuracy: 0.001)
            }
        }
    }

    func testSecondaryLabelMatchesColorSchemeInEveryContrastMode() {
        for contrast in [ColorSchemeContrast.standard, .increased] {
            let lightColor = AppTheme.secondaryLabel(colorScheme: .light, contrast: contrast)
            let darkColor = AppTheme.secondaryLabel(colorScheme: .dark, contrast: contrast)
            let light = NSColor(lightColor).usingColorSpace(.sRGB) ?? NSColor(lightColor)
            let dark = NSColor(darkColor).usingColorSpace(.sRGB) ?? NSColor(darkColor)

            let lightLuma = light.redComponent + light.greenComponent + light.blueComponent
            let darkLuma = dark.redComponent + dark.greenComponent + dark.blueComponent

            XCTAssertLessThan(lightLuma, 1.5)
            XCTAssertGreaterThan(darkLuma, 1.5)
        }
    }

    func testSystemColorAppearanceHonorsContrastPreference() {
        let cases: [(ColorScheme, ColorSchemeContrast, NSAppearance.Name)] = [
            (.light, .standard, .aqua),
            (.dark, .standard, .darkAqua),
            (.light, .increased, .accessibilityHighContrastAqua),
            (.dark, .increased, .accessibilityHighContrastDarkAqua),
        ]

        for (colorScheme, contrast, expectedName) in cases {
            XCTAssertEqual(
                AppTheme.appearanceName(colorScheme: colorScheme, contrast: contrast),
                expectedName
            )
        }
    }
}
