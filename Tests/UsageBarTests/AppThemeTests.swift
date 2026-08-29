import AppKit
import SwiftUI
import XCTest
@testable import UsageBar

final class AppThemeTests: XCTestCase {
    func testProviderLogosLoadAsTemplates() throws {
        for provider in LimitBucket.Provider.allCases {
            let logo = try XCTUnwrap(
                AppTheme.logo(for: provider),
                "Missing logo for \(provider.rawValue)"
            )
            XCTAssertTrue(logo.isTemplate, provider.rawValue)
            XCTAssertGreaterThan(logo.size.width, 0, provider.rawValue)
            XCTAssertGreaterThan(logo.size.height, 0, provider.rawValue)
        }
    }

    func testEveryWeightStaysInDMSans() throws {
        AppTheme.loadFont()

        for weight in [Font.Weight.regular, .medium, .semibold, .bold] {
            let font = try XCTUnwrap(AppTheme.nsFont(size: 13, weight: weight))
            XCTAssertEqual(font.familyName, "DM Sans")
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

    func testOpticalSizeTracksPointSizeWithinSupportedRange() throws {
        AppTheme.loadFont()
        let variationKey = NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String)
        let opticalSizeKey = NSNumber(value: 1_869_640_570)
        let cases: [(size: CGFloat, expected: Double)] = [
            (8, 9),
            (13, 13),
            (48, 40),
        ]

        for testCase in cases {
            let font = try XCTUnwrap(AppTheme.nsFont(size: testCase.size))
            let variations = font.fontDescriptor.object(forKey: variationKey)
                as? [NSNumber: NSNumber]
            let opticalSize = variations?[opticalSizeKey]?.doubleValue ?? 9
            XCTAssertEqual(opticalSize, testCase.expected)
        }
    }

    func testCardFillUsesAppearanceAwareInkAtExpectedOpacity() {
        let cases: [(ColorScheme, ColorSchemeContrast, String, CGFloat)] = [
            (.light, .standard, "#000000", 0.045),
            (.dark, .standard, "#FFFFFF", 0.045),
            (.light, .increased, "#000000", 0.09),
            (.dark, .increased, "#FFFFFF", 0.09),
        ]

        for (colorScheme, contrast, expectedHex, expectedAlpha) in cases {
            let fillColor = AppTheme.cardFill(
                colorScheme: colorScheme,
                contrast: contrast
            )
            let fill = NSColor(fillColor).usingColorSpace(.sRGB) ?? NSColor(fillColor)

            XCTAssertEqual(fillColor.hexString, expectedHex)
            XCTAssertEqual(fill.alphaComponent, expectedAlpha, accuracy: 0.001)
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
