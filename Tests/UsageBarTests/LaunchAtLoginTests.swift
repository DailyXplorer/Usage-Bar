import ServiceManagement
import XCTest
@testable import UsageBar

final class LaunchAtLoginTests: XCTestCase {
    @MainActor
    func testEnablingRegistersAndClearsPreviousError() {
        let service = MockLaunchAtLoginService(status: .notRegistered)
        let model = LaunchAtLoginModel(service: service)
        model.setEnabled(true)

        XCTAssertEqual(service.setEnabledCalls, [true])
        XCTAssertEqual(model.status, .enabled)
        XCTAssertTrue(model.isEnabled)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(
            model.footer,
            "Usage Bar starts in the menu bar after you log in to this Mac."
        )
    }

    @MainActor
    func testDisablingUnregisters() {
        let service = MockLaunchAtLoginService(status: .enabled)
        let model = LaunchAtLoginModel(service: service)
        XCTAssertTrue(model.isEnabled)

        model.setEnabled(false)

        XCTAssertEqual(service.setEnabledCalls, [false])
        XCTAssertEqual(model.status, .notRegistered)
        XCTAssertFalse(model.isEnabled)
    }

    @MainActor
    func testRequiresApprovalCountsAsEnabled() {
        let service = MockLaunchAtLoginService(status: .requiresApproval)
        let model = LaunchAtLoginModel(service: service)

        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(
            model.footer,
            "Allow Usage Bar in System Settings → General → Login Items & Extensions."
        )
        XCTAssertEqual(model.accessibilityHint, "Waiting for permission in Login Items")
    }

    @MainActor
    func testFailureKeepsCurrentStatusAndShowsTheError() {
        let service = MockLaunchAtLoginService(status: .notRegistered)
        service.errorToThrow = SimpleError("Could not register login item")
        let model = LaunchAtLoginModel(service: service)

        model.setEnabled(true)

        XCTAssertEqual(model.status, .notRegistered)
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.errorMessage, "Could not register login item")
        XCTAssertEqual(model.footer, "Could not register login item")
    }

    @MainActor
    func testRefreshPicksUpExternalStatusChanges() {
        let service = MockLaunchAtLoginService(status: .requiresApproval)
        let model = LaunchAtLoginModel(service: service)
        service.status = .enabled

        model.refresh()

        XCTAssertEqual(model.status, .enabled)
        XCTAssertTrue(model.isEnabled)
        XCTAssertNil(model.errorMessage)
    }

    func testResolverPrefersAppServiceThenFallsBackToLaunchAgent() {
        XCTAssertEqual(
            LaunchAtLoginResolver.status(appService: .enabled, agentInstalled: false),
            .enabled
        )
        XCTAssertEqual(
            LaunchAtLoginResolver.status(appService: .requiresApproval, agentInstalled: false),
            .requiresApproval
        )
        XCTAssertEqual(
            LaunchAtLoginResolver.status(appService: .notFound, agentInstalled: false),
            .notRegistered
        )
        XCTAssertEqual(
            LaunchAtLoginResolver.status(appService: .notFound, agentInstalled: true),
            .enabled
        )
        XCTAssertEqual(
            LaunchAtLoginResolver.status(appService: .notRegistered, agentInstalled: true),
            .enabled
        )
        XCTAssertTrue(LaunchAtLoginResolver.usesLaunchAgent(appService: .notFound))
        XCTAssertFalse(LaunchAtLoginResolver.usesLaunchAgent(appService: .notRegistered))
    }

    func testLaunchAgentInstallsAndRemovesALoginPlist() throws {
        let home = temporaryRoot()
        let store = LaunchAgentStore(home: home)
        let appURL = URL(fileURLWithPath: "/tmp/Usage Bar.app")

        XCTAssertFalse(store.isInstalled)

        try store.install(appURL: appURL)
        XCTAssertTrue(store.isInstalled)

        let payload = try plist(at: store.plistURL)
        XCTAssertEqual(payload["Label"] as? String, LaunchAgentStore.label)
        XCTAssertEqual(payload["ProgramArguments"] as? [String], ["/usr/bin/open", appURL.path])
        XCTAssertEqual(payload["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(payload["LimitLoadToSessionType"] as? String, "Aqua")

        try store.uninstall()
        XCTAssertFalse(store.isInstalled)
    }

    func testLaunchAgentUsesTheExecutableDirectlyWhenThereIsNoAppBundle() throws {
        let home = temporaryRoot()
        let store = LaunchAgentStore(home: home)
        let executable = URL(fileURLWithPath: "/tmp/UsageBar")

        try store.install(appURL: executable)

        let payload = try plist(at: store.plistURL)
        XCTAssertEqual(payload["ProgramArguments"] as? [String], [executable.path])
    }

    func testBundleURLPrefersTheAppWrapperOverTheRawExecutable() {
        let appURL = LaunchAtLoginPaths.bundleURL(
            bundle: Bundle(path: "/tmp") ?? .main,
            executablePath: "/tmp/UsageBar.app/Contents/MacOS/UsageBar",
            arguments: ["/tmp/UsageBar"]
        )
        XCTAssertEqual(appURL.path, "/tmp/UsageBar.app")
    }

    func testInstallCopiesTheAppIntoApplications() throws {
        let root = temporaryRoot()
        let source = root.appendingPathComponent("Source.app")
        let destination = root.appendingPathComponent("Applications/UsageBar.app")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        try Data("ok".utf8).write(to: source.appendingPathComponent("Contents/Info.plist"))

        var relaunched: URL?
        let location = AppInstallLocation(
            destination: destination,
            runningBundle: { source },
            relaunch: { relaunched = $0 }
        )

        XCTAssertFalse(location.isRunningFromDestination)
        let installed = try location.installIfNeeded()
        XCTAssertEqual(installed.path, destination.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertNil(relaunched)
    }

    func testInstallReplacesAnExistingAppOnlyAfterStagingTheNewCopy() throws {
        let root = temporaryRoot()
        let sourceMarker = root.appendingPathComponent("Source.app/Contents/version")
        let destination = root.appendingPathComponent("Applications/UsageBar.app")
        let destinationMarker = destination.appendingPathComponent("Contents/version")
        try FileManager.default.createDirectory(
            at: sourceMarker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationMarker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("new".utf8).write(to: sourceMarker)
        try Data("old".utf8).write(to: destinationMarker)

        let location = AppInstallLocation(
            destination: destination,
            runningBundle: { sourceMarker.deletingLastPathComponent().deletingLastPathComponent() },
            relaunch: { _ in XCTFail("installIfNeeded does not relaunch directly") }
        )

        _ = try location.installIfNeeded()

        XCTAssertEqual(try String(contentsOf: destinationMarker), "new")
        let stagedItems = try FileManager.default.contentsOfDirectory(
            at: destination.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(stagedItems.map(\.lastPathComponent), ["UsageBar.app"])
    }

    func testInstallIsANoOpWhenAlreadyInApplications() throws {
        let root = temporaryRoot()
        let destination = root.appendingPathComponent("UsageBar.app")
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        let location = AppInstallLocation(
            destination: destination,
            runningBundle: { destination },
            relaunch: { _ in XCTFail("should not relaunch") }
        )

        XCTAssertTrue(location.isRunningFromDestination)
        let installed = try location.installIfNeeded()
        XCTAssertEqual(installed.path, destination.path)
    }

    func testFailedReplacementPreservesTheInstalledApp() throws {
        let root = temporaryRoot()
        let source = root.appendingPathComponent("Missing.app")
        let destination = root.appendingPathComponent("Applications/UsageBar.app")
        let marker = destination.appendingPathComponent("Contents/installed-version")
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("previous".utf8).write(to: marker)

        let location = AppInstallLocation(
            destination: destination,
            runningBundle: { source },
            relaunch: { _ in XCTFail("a failed install must not relaunch") }
        )

        XCTAssertThrowsError(try location.installIfNeeded())
        XCTAssertEqual(try String(contentsOf: marker), "previous")
    }

    func testEnableCopiesToApplicationsThenRelaunches() throws {
        let root = temporaryRoot()
        let source = root.appendingPathComponent("Source.app")
        let destination = root.appendingPathComponent("Applications/UsageBar.app")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        try Data("ok".utf8).write(to: source.appendingPathComponent("Contents/Info.plist"))

        let defaultsName = UUID().uuidString
        let defaults = try makeDefaults(named: defaultsName)

        var relaunched: URL?
        let store = LaunchAgentStore(home: root)
        let location = AppInstallLocation(
            destination: destination,
            runningBundle: { source },
            relaunch: { relaunched = $0 }
        )
        let service = SMAppServiceLaunchAtLogin(
            agent: store,
            installLocation: location,
            defaults: defaults,
            appService: MockMainAppService(status: .notFound)
        )

        try service.setEnabled(true)

        XCTAssertEqual(relaunched?.path, destination.path)
        XCTAssertTrue(defaults.bool(forKey: AppInstallLocation.pendingKey))
        XCTAssertFalse(store.isInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSystemServiceFallsBackToALaunchAgentWhenAppServiceIsMissing() throws {
        let root = temporaryRoot()
        let appURL = root.appendingPathComponent("UsageBar.app")
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        let defaultsName = UUID().uuidString
        let defaults = try makeDefaults(named: defaultsName)
        let appService = MockMainAppService(status: .notFound)
        let store = LaunchAgentStore(home: root)
        let location = AppInstallLocation(
            destination: appURL,
            runningBundle: { appURL },
            relaunch: { _ in XCTFail("already running from Applications") }
        )
        let service = SMAppServiceLaunchAtLogin(
            agent: store,
            installLocation: location,
            defaults: defaults,
            appService: appService
        )

        try service.setEnabled(true)
        XCTAssertTrue(store.isInstalled)
        XCTAssertEqual(service.status, .enabled)
        XCTAssertEqual(appService.registerCallCount, 0)

        try service.setEnabled(false)
        XCTAssertFalse(store.isInstalled)
        XCTAssertEqual(service.status, .notRegistered)
        XCTAssertEqual(appService.unregisterCallCount, 0)
    }

    func testSystemServiceUsesTheInjectedRegistrationController() throws {
        let root = temporaryRoot()
        let appURL = root.appendingPathComponent("UsageBar.app")
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        let defaults = try makeDefaults(named: UUID().uuidString)
        let appService = MockMainAppService(status: .notRegistered)
        let service = SMAppServiceLaunchAtLogin(
            agent: LaunchAgentStore(home: root),
            installLocation: AppInstallLocation(
                destination: appURL,
                runningBundle: { appURL },
                relaunch: { _ in XCTFail("already running from Applications") }
            ),
            defaults: defaults,
            appService: appService
        )

        try service.setEnabled(true)

        XCTAssertEqual(appService.registerCallCount, 1)
        XCTAssertEqual(service.status, .enabled)

        try service.setEnabled(false)

        XCTAssertEqual(appService.unregisterCallCount, 1)
        XCTAssertEqual(service.status, .notRegistered)
    }

    func testPendingEnableRegistersAfterRelaunchFromApplications() throws {
        let root = temporaryRoot()
        let appURL = root.appendingPathComponent("UsageBar.app")
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        let defaultsName = UUID().uuidString
        let defaults = try makeDefaults(named: defaultsName)
        defaults.set(true, forKey: AppInstallLocation.pendingKey)

        let store = LaunchAgentStore(home: root)
        let location = AppInstallLocation(
            destination: appURL,
            runningBundle: { appURL },
            relaunch: { _ in XCTFail("already running from Applications") }
        )

        let completed = SMAppServiceLaunchAtLogin.pendingEnableCompleted(defaults: defaults) {
            SMAppServiceLaunchAtLogin(
                agent: store,
                installLocation: location,
                defaults: defaults,
                appService: MockMainAppService(status: .notFound)
            )
        }
        if completed {
            defaults.set(false, forKey: AppInstallLocation.pendingKey)
        }

        XCTAssertTrue(completed)
        XCTAssertFalse(defaults.bool(forKey: AppInstallLocation.pendingKey))
        XCTAssertTrue(store.isInstalled)
    }

    func testPendingEnableSurvivesAnotherRequiredRelaunch() throws {
        let root = temporaryRoot()
        let source = root.appendingPathComponent("Downloaded/UsageBar.app")
        let destination = root.appendingPathComponent("Applications/UsageBar.app")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        try Data("ok".utf8).write(to: source.appendingPathComponent("Contents/Info.plist"))
        let defaultsName = UUID().uuidString
        let defaults = try makeDefaults(named: defaultsName)
        defaults.set(true, forKey: AppInstallLocation.pendingKey)

        var relaunched: URL?
        let location = AppInstallLocation(
            destination: destination,
            runningBundle: { source },
            relaunch: { relaunched = $0 }
        )

        let completed = SMAppServiceLaunchAtLogin.pendingEnableCompleted(defaults: defaults) {
            SMAppServiceLaunchAtLogin(
                agent: LaunchAgentStore(home: root),
                installLocation: location,
                defaults: defaults,
                appService: MockMainAppService(status: .notFound)
            )
        }

        XCTAssertFalse(completed)
        XCTAssertTrue(defaults.bool(forKey: AppInstallLocation.pendingKey))
        XCTAssertEqual(relaunched?.path, destination.path)
    }

    func testPendingEnableIsRetainedWhenRegistrationFails() throws {
        let defaultsName = UUID().uuidString
        let defaults = try makeDefaults(named: defaultsName)
        defaults.set(true, forKey: AppInstallLocation.pendingKey)

        let completed = SMAppServiceLaunchAtLogin.pendingEnableCompleted(defaults: defaults) {
            throw SimpleError("registration failed")
        }

        XCTAssertFalse(completed)
        XCTAssertTrue(defaults.bool(forKey: AppInstallLocation.pendingKey))
    }

    private func plist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func temporaryRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeDefaults(named name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        return defaults
    }
}

private struct SimpleError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

private final class MockLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    var errorToThrow: Error?
    private(set) var setEnabledCalls: [Bool] = []

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func setEnabled(_ enabled: Bool) throws {
        setEnabledCalls.append(enabled)
        if let errorToThrow {
            throw errorToThrow
        }
        status = enabled ? .enabled : .notRegistered
    }
}

private final class MockMainAppService: MainAppServiceControlling {
    var status: SMAppService.Status
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        status = .notRegistered
    }
}
