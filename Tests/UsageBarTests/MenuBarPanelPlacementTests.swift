import CoreGraphics
import XCTest
@testable import UsageBar

final class MenuBarPanelPlacementTests: XCTestCase {
    func testPanelIsCenteredBelowButton() throws {
        let screen = MenuBarPanelPlacement.ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )
        let buttonFrame = CGRect(x: 580, y: 760, width: 40, height: 24)

        let panelFrame = try XCTUnwrap(
            MenuBarPanelPlacement.frame(
                for: CGSize(width: 320, height: 240),
                below: buttonFrame,
                on: [screen]
            )
        )

        XCTAssertEqual(panelFrame, CGRect(x: 440, y: 518, width: 320, height: 240))
        XCTAssertEqual(buttonFrame.minY - panelFrame.maxY, 2)
    }

    func testPanelStaysAnchoredToButtonOutsideVisibleFrame() throws {
        let screen = MenuBarPanelPlacement.ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 875)
        )
        let buttonFrame = CGRect(x: 700, y: 875, width: 40, height: 25)

        let panelFrame = try XCTUnwrap(
            MenuBarPanelPlacement.frame(
                for: CGSize(width: 304, height: 240),
                below: buttonFrame,
                on: [screen]
            )
        )

        XCTAssertEqual(panelFrame, CGRect(x: 568, y: 633, width: 304, height: 240))
        XCTAssertEqual(buttonFrame.minY - panelFrame.maxY, 2)
    }

    func testPanelClampsToLeftAndRightMargins() throws {
        let screen = MenuBarPanelPlacement.ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 700),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 700)
        )
        let panelSize = CGSize(width: 300, height: 100)

        let leftFrame = try XCTUnwrap(
            MenuBarPanelPlacement.frame(
                for: panelSize,
                below: CGRect(x: 4, y: 650, width: 24, height: 22),
                on: [screen],
                margin: 12
            )
        )
        let rightFrame = try XCTUnwrap(
            MenuBarPanelPlacement.frame(
                for: panelSize,
                below: CGRect(x: 972, y: 650, width: 24, height: 22),
                on: [screen],
                margin: 12
            )
        )

        XCTAssertEqual(leftFrame, CGRect(x: 12, y: 548, width: 300, height: 100))
        XCTAssertEqual(rightFrame, CGRect(x: 688, y: 548, width: 300, height: 100))
    }

    func testNegativeScreenOriginIsPreserved() throws {
        let screen = MenuBarPanelPlacement.ScreenGeometry(
            frame: CGRect(x: -1_440, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: -1_440, y: 0, width: 1_440, height: 875)
        )
        let buttonFrame = CGRect(x: -740, y: 850, width: 40, height: 24)

        let panelFrame = try XCTUnwrap(
            MenuBarPanelPlacement.frame(
                for: CGSize(width: 300, height: 180),
                below: buttonFrame,
                on: [screen]
            )
        )

        XCTAssertEqual(panelFrame, CGRect(x: -870, y: 668, width: 300, height: 180))
    }

    func testScreenWithLargestButtonIntersectionIsSelected() throws {
        let leftScreen = MenuBarPanelPlacement.ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        let rightScreen = MenuBarPanelPlacement.ScreenGeometry(
            frame: CGRect(x: 1_000, y: 0, width: 1_200, height: 800),
            visibleFrame: CGRect(x: 1_000, y: 0, width: 1_200, height: 800)
        )

        let panelFrame = try XCTUnwrap(
            MenuBarPanelPlacement.frame(
                for: CGSize(width: 200, height: 150),
                below: CGRect(x: 990, y: 740, width: 30, height: 24),
                on: [leftScreen, rightScreen]
            )
        )

        XCTAssertEqual(panelFrame, CGRect(x: 1_008, y: 588, width: 200, height: 150))
    }

    func testOversizedPanelIsReducedToAvailableSpace() throws {
        let screen = MenuBarPanelPlacement.ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 600, height: 400),
            visibleFrame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        let buttonFrame = CGRect(x: 280, y: 370, width: 40, height: 20)

        let panelFrame = try XCTUnwrap(
            MenuBarPanelPlacement.frame(
                for: CGSize(width: 900, height: 600),
                below: buttonFrame,
                on: [screen]
            )
        )

        XCTAssertEqual(panelFrame, CGRect(x: 8, y: 8, width: 584, height: 360))
        XCTAssertEqual(buttonFrame.minY - panelFrame.maxY, 2)
    }

    func testNoMatchingScreenReturnsNil() {
        let screen = MenuBarPanelPlacement.ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 600, height: 400),
            visibleFrame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )

        let panelFrame = MenuBarPanelPlacement.frame(
            for: CGSize(width: 300, height: 200),
            below: CGRect(x: 700, y: 370, width: 40, height: 20),
            on: [screen]
        )

        XCTAssertNil(panelFrame)
    }
}
