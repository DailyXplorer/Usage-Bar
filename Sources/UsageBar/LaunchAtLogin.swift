import Combine
import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
}

private enum LaunchAtLoginEnableResult {
    case enabled
    case relaunchScheduled
}

protocol LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus { get }
    func setEnabled(_ enabled: Bool) throws
}

enum LaunchAtLoginPaths {
    static func bundleURL(
        bundle: Bundle = .main,
        executablePath: String? = Bundle.main.executablePath,
        arguments: [String] = CommandLine.arguments
    ) -> URL {
        let bundleURL = bundle.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }
        if let executablePath {
            let executable = URL(fileURLWithPath: executablePath)
            let macosDirectory = executable.deletingLastPathComponent()
            if macosDirectory.lastPathComponent == "MacOS" {
                let appURL = macosDirectory
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                if appURL.pathExtension == "app" {
                    return appURL
                }
            }
        }
        return URL(fileURLWithPath: arguments[0]).standardizedFileURL
    }

    static func programArguments(for url: URL) -> [String] {
        if url.pathExtension == "app" {
            return ["/usr/bin/open", url.path]
        }
        return [url.path]
    }
}

enum AppInstallError: LocalizedError {
    case notAnApp

    var errorDescription: String? {
        switch self {
        case .notAnApp:
            return "Usage Bar needs to be installed as an app in Applications."
        }
    }
}

struct AppInstallLocation {
    static let defaultDestination = URL(fileURLWithPath: "/Applications/UsageBar.app")
    static let pendingKey = "pendingLaunchAtLogin"

    let destination: URL
    private let fileManager: FileManager
    private let runningBundle: () -> URL
    let relaunch: (URL) throws -> Void

    init(
        destination: URL = AppInstallLocation.defaultDestination,
        fileManager: FileManager = .default,
        runningBundle: @escaping () -> URL = { LaunchAtLoginPaths.bundleURL() },
        relaunch: @escaping (URL) throws -> Void = AppInstallLocation.openAndQuit
    ) {
        self.destination = destination.standardizedFileURL
        self.fileManager = fileManager
        self.runningBundle = {
            runningBundle().standardizedFileURL
        }
        self.relaunch = relaunch
    }

    var isRunningFromDestination: Bool {
        runningBundle().path == destination.path
    }

    func installIfNeeded() throws -> URL {
        let source = runningBundle()
        guard source.pathExtension == "app" else {
            throw AppInstallError.notAnApp
        }
        if source.path == destination.path {
            return destination
        }
        try AppBundleReplacement.install(
            from: source,
            to: destination,
            fileManager: fileManager
        )
        return destination
    }

    static func openAndQuit(at url: URL) throws {
        try AppRelaunchCommand.relaunch(appURL: url)
    }
}

struct LaunchAgentStore {
    static let label = "com.usagebar.app.login"

    private let fileManager: FileManager
    let plistURL: URL

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        plistURL = home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.label).plist")
    }

    var isInstalled: Bool {
        fileManager.fileExists(atPath: plistURL.path)
    }

    func install(appURL: URL) throws {
        try fileManager.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": LaunchAtLoginPaths.programArguments(for: appURL),
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    func uninstall() throws {
        guard isInstalled else { return }
        try fileManager.removeItem(at: plistURL)
    }
}

enum LaunchAtLoginResolver {
    static func status(
        appService: SMAppService.Status,
        agentInstalled: Bool
    ) -> LaunchAtLoginStatus {
        switch appService {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        default:
            return agentInstalled ? .enabled : .notRegistered
        }
    }

    static func usesLaunchAgent(appService: SMAppService.Status) -> Bool {
        appService == .notFound
    }
}

protocol MainAppServiceControlling {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

struct SystemMainAppServiceController: MainAppServiceControlling {
    var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

struct SMAppServiceLaunchAtLogin: LaunchAtLoginServicing {
    private let agent: LaunchAgentStore
    private let installLocation: AppInstallLocation
    private let defaults: UserDefaults
    private let appService: any MainAppServiceControlling

    init(
        agent: LaunchAgentStore = LaunchAgentStore(),
        installLocation: AppInstallLocation = AppInstallLocation(),
        defaults: UserDefaults = .standard,
        appService: any MainAppServiceControlling = SystemMainAppServiceController()
    ) {
        self.agent = agent
        self.installLocation = installLocation
        self.defaults = defaults
        self.appService = appService
    }

    var status: LaunchAtLoginStatus {
        LaunchAtLoginResolver.status(
            appService: appService.status,
            agentInstalled: agent.isInstalled
        )
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            _ = try enable()
        } else {
            try disable()
        }
    }

    static func pendingEnableCompleted(
        defaults: UserDefaults = .standard,
        makeService: () throws -> SMAppServiceLaunchAtLogin = { SMAppServiceLaunchAtLogin() }
    ) -> Bool {
        guard defaults.bool(forKey: AppInstallLocation.pendingKey) else { return false }
        do {
            return try makeService().enable() == .enabled
        } catch {
            return false
        }
    }

    private func enable() throws -> LaunchAtLoginEnableResult {
        let installed = try installLocation.installIfNeeded()
        if !installLocation.isRunningFromDestination {
            defaults.set(true, forKey: AppInstallLocation.pendingKey)
            try installLocation.relaunch(installed)
            return .relaunchScheduled
        }

        let current = appService.status
        if current == .enabled || current == .requiresApproval {
            try agent.uninstall()
            return .enabled
        }
        if LaunchAtLoginResolver.usesLaunchAgent(appService: current) {
            try agent.install(appURL: installed)
            return .enabled
        }
        try appService.register()
        try agent.uninstall()
        return .enabled
    }

    private func disable() throws {
        let current = appService.status
        if current == .enabled || current == .requiresApproval {
            try appService.unregister()
        }
        try agent.uninstall()
        defaults.set(false, forKey: AppInstallLocation.pendingKey)
    }
}

final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var status: LaunchAtLoginStatus
    @Published private(set) var errorMessage: String?

    private let service: any LaunchAtLoginServicing

    init(service: any LaunchAtLoginServicing = SMAppServiceLaunchAtLogin()) {
        self.service = service
        status = service.status
    }

    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    var footer: String? {
        if let errorMessage {
            return errorMessage
        }
        if status == .requiresApproval {
            return "Allow Usage Bar in System Settings → General → Login Items & Extensions."
        }
        return nil
    }

    var accessibilityHint: String {
        if status == .requiresApproval {
            return "Waiting for permission in Login Items"
        }
        return "Start Usage Bar when you log in to this Mac"
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            try service.setEnabled(enabled)
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        status = service.status
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
