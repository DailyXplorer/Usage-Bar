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
