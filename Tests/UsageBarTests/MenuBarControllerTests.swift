import AppKit
import XCTest
@testable import UsageBar

@MainActor
final class MenuBarControllerTests: XCTestCase {
    func testPanelDismissesAfterItResignsKey() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        fixture.panel.orderFrontRegardless()
        fixture.panel.makeKey()
        XCTAssertTrue(waitUntil { fixture.panel.isKeyWindow })

        fixture.panel.resignKey()

        XCTAssertTrue(waitUntil { !fixture.panel.isVisible })
    }

    func testStaleResignDoesNotDismissPanelAfterItRegainsKey() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        fixture.panel.orderFrontRegardless()
        fixture.panel.makeKey()
        XCTAssertTrue(waitUntil { fixture.panel.isKeyWindow })

        fixture.panel.resignKey()
        fixture.panel.makeKey()
        let mainQueueDrained = expectation(description: "main queue drained")
        DispatchQueue.main.async {
            mainQueueDrained.fulfill()
        }
        wait(for: [mainQueueDrained], timeout: 1)

        XCTAssertTrue(fixture.panel.isVisible)
        XCTAssertTrue(fixture.panel.isKeyWindow)
    }

    func testCommandQClosesThePanelInsteadOfQuitting() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        fixture.panel.orderFrontRegardless()
        fixture.panel.makeKey()
        XCTAssertTrue(waitUntil { fixture.panel.isKeyWindow })

        let quit = try XCTUnwrap(keyEvent("q", modifiers: .command, window: fixture.panel))
        XCTAssertTrue(fixture.panel.performKeyEquivalent(with: quit))
        XCTAssertTrue(waitUntil { !fixture.panel.isVisible })
    }

    func testOnlyCommandQIsTreatedAsQuit() throws {
        XCTAssertTrue(MenuBarPanel.isQuitShortcut(try XCTUnwrap(keyEvent("q", modifiers: .command))))
        XCTAssertTrue(MenuBarPanel.isQuitShortcut(try XCTUnwrap(keyEvent("Q", modifiers: [.command, .capsLock]))))
        XCTAssertFalse(MenuBarPanel.isQuitShortcut(try XCTUnwrap(keyEvent("q", modifiers: []))))
        XCTAssertFalse(MenuBarPanel.isQuitShortcut(try XCTUnwrap(keyEvent("q", modifiers: [.command, .option]))))
        XCTAssertFalse(MenuBarPanel.isQuitShortcut(try XCTUnwrap(keyEvent("w", modifiers: .command))))
    }

    private func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags, window: NSWindow? = nil) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 12
        )
    }

    private func makeFixture() throws -> Fixture {
        AppTheme.loadFont()
        let application = NSApplication.shared
        let knownPanels = Set(
            application.windows.compactMap { $0 as? NSPanel }.map(ObjectIdentifier.init)
        )
        let suiteName = "MenuBarControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let model = UsageModel(defaults: defaults)
        let updater = AppUpdater(defaults: defaults, currentVersion: "1.0")
        let controller = MenuBarController(model: model, updater: updater)
        let panel = try XCTUnwrap(
            application.windows
                .compactMap { $0 as? NSPanel }
                .first { !knownPanels.contains(ObjectIdentifier($0)) }
        )
        return Fixture(
            controller: controller,
            panel: panel,
            defaults: defaults,
            suiteName: suiteName
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

@MainActor
private struct Fixture {
    let controller: MenuBarController
    let panel: NSPanel
    let defaults: UserDefaults
    let suiteName: String

    func cleanUp() {
        controller.stop()
        defaults.removePersistentDomain(forName: suiteName)
    }
}
