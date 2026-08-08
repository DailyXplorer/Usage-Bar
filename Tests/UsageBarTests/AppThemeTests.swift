import AppKit
import SwiftUI
import XCTest
@testable import UsageBar

final class AppThemeTests: XCTestCase {
    /// Garde-fou : Instrument Sans est un fichier variable, donc demander
    /// « InstrumentSans-SemiBold » par son nom retombe en silence sur la police
    /// système. Chaque graisse doit rester dans la famille Instrument Sans.
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
}
