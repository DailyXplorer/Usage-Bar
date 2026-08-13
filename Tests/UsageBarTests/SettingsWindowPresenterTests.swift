import AppKit
import XCTest
@testable import UsageBar

@MainActor
final class SettingsWindowPresenterTests: XCTestCase {
    func testSwiftUIIdentifierIsTreatedAsSettings() {
        let traits = SettingsWindowTraits(
            identifier: SettingsWindowPresenter.swiftUISettingsIdentifier,
            isPanel: false,
            canBecomeMain: false,
            isTitled: false
        )

        XCTAssertTrue(SettingsWindowPresenter.isSettingsWindow(traits))
    }

    func testTitledMainWindowIsTreatedAsSettings() {
        let traits = SettingsWindowTraits(
            identifier: nil,
            isPanel: false,
            canBecomeMain: true,
            isTitled: true
        )

        XCTAssertTrue(SettingsWindowPresenter.isSettingsWindow(traits))
    }

    func testMenuPanelIsNotSettings() {
        let traits = SettingsWindowTraits(
            identifier: nil,
            isPanel: true,
            canBecomeMain: false,
            isTitled: true
        )

        XCTAssertFalse(SettingsWindowPresenter.isSettingsWindow(traits))
    }

    func testBorderlessWindowIsNotSettings() {
        let traits = SettingsWindowTraits(
            identifier: nil,
            isPanel: false,
            canBecomeMain: false,
            isTitled: false
        )

        XCTAssertFalse(SettingsWindowPresenter.isSettingsWindow(traits))
    }

    func testActiveSpaceBehaviorMovesWithoutJoiningEverySpace() {
        let current: NSWindow.CollectionBehavior = [.managed, .canJoinAllSpaces, .fullScreenNone]
        let pinned = SettingsWindowPresenter.collectionBehaviorForActiveSpace(current)

        XCTAssertTrue(pinned.contains(.moveToActiveSpace))
        XCTAssertTrue(pinned.contains(.fullScreenAuxiliary))
        XCTAssertTrue(pinned.contains(.managed))
        XCTAssertFalse(pinned.contains(.canJoinAllSpaces))
        XCTAssertFalse(pinned.contains(.fullScreenNone))
        XCTAssertFalse(pinned.contains(.fullScreenPrimary))
    }
}
