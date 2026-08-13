import AppKit
import Combine
import Foundation

protocol GitHubReleasing {
    func latestRelease() async throws -> GitHubRelease
}

protocol AppUpdateInstalling {
    func install(fromAppBundle url: URL) throws
    func relaunch()
}

struct GitHubReleaseService: GitHubReleasing {
    var session: URLSession = .shared
    var endpoint: URL = AppDistribution.latestReleaseURL

    func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue("UsageBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.network("invalid response")
        }
        if http.statusCode == 404 {
            throw UpdateError.noReleases
        }
        guard http.statusCode == 200 else {
            throw UpdateError.httpStatus(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
    }
}

struct AppUpdateInstaller: AppUpdateInstalling {
    var destination: URL = AppDistribution.installURL
    var fileManager: FileManager = .default

    func install(fromAppBundle url: URL) throws {
        try verifyBundle(at: url)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: url)
        } else {
            try fileManager.copyItem(at: url, to: destination)
        }
        try clearQuarantine(at: destination)
    }

    func relaunch() {
        let appPath = destination.path
        let script = """
        while /usr/bin/pgrep -f '\(appPath)/Contents/MacOS/UsageBar' >/dev/null 2>&1; do
          /bin/sleep 0.2
        done
        /usr/bin/open '\(appPath)'
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    func verifyBundle(at url: URL) throws {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = plist as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              identifier == AppDistribution.bundleIdentifier else {
            throw UpdateError.invalidAppBundle
        }
    }

    func extractApp(fromZip zipURL: URL, to directory: URL) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.extractFailed
        }
        return try findApp(in: directory)
    }

    func findApp(in directory: URL) throws -> URL {
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        if let app = contents.first(where: { $0.pathExtension == "app" }) {
            return app
        }
        for item in contents {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true, let nested = try? findApp(in: item) {
                return nested
            }
        }
        throw UpdateError.extractFailed
    }

    private func clearQuarantine(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-cr", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }
}

final class AppUpdater: ObservableObject {
    @Published private(set) var state: UpdateState = .idle
    @Published var automaticallyChecks: Bool {
        didSet { defaults.set(automaticallyChecks, forKey: UpdatePreferences.checksKey) }
    }
    @Published var automaticallyInstalls: Bool {
        didSet {
            defaults.set(automaticallyInstalls, forKey: UpdatePreferences.installsKey)
            if automaticallyInstalls, case .available(let release) = state {
                install(release)
            }
        }
    }

    let currentVersion: String

    private let client: any GitHubReleasing
    private let installer: any AppUpdateInstalling
    private let unpacker: AppUpdateInstaller
    private let defaults: UserDefaults
    private let session: URLSession
    private var checkTask: Task<Void, Never>?

    init(
        client: any GitHubReleasing = GitHubReleaseService(),
        installer: any AppUpdateInstalling = AppUpdateInstaller(),
        unpacker: AppUpdateInstaller = AppUpdateInstaller(),
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        currentVersion: String? = nil
    ) {
        self.client = client
        self.installer = installer
        self.unpacker = unpacker
        self.defaults = defaults
        self.session = session
        self.currentVersion = currentVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0"
        automaticallyChecks = defaults.object(forKey: UpdatePreferences.checksKey) as? Bool ?? true
        automaticallyInstalls = defaults.object(forKey: UpdatePreferences.installsKey) as? Bool ?? true
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing:
            return true
        default:
            return false
        }
    }

    var availableRelease: GitHubRelease? {
        if case .available(let release) = state {
            return release
        }
        return nil
    }

    var statusLine: String {
        switch state {
        case .idle:
            return "Checks GitHub for new releases"
        case .checking:
            return "Checking GitHub…"
        case .upToDate:
            return "You’re up to date"
        case .available(let release):
            return "Version \(release.versionString) is available"
        case .downloading:
            return "Downloading…"
        case .installing:
            return "Installing…"
        case .failed(let message):
            return message
        }
    }

    var buttonTitle: String {
        switch state {
        case .available(let release):
            return "Install \(release.versionString)"
        case .checking:
            return "Checking…"
        case .downloading:
            return "Downloading…"
        case .installing:
            return "Installing…"
        case .failed:
            return "Try Again"
        default:
            return "Check for Updates"
        }
    }

    func startAutomaticChecks() {
        guard automaticallyChecks else { return }
        if let last = defaults.object(forKey: UpdatePreferences.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < UpdatePreferences.checkInterval {
            return
        }
        checkForUpdates(installIfAvailable: automaticallyInstalls)
    }

    func performButtonAction() {
        if case .available(let release) = state {
            install(release)
            return
        }
        checkForUpdates(force: true, installIfAvailable: false)
    }

    func checkForUpdates(force: Bool = false, installIfAvailable: Bool = false) {
        if isBusy { return }
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            await self?.performCheck(force: force, installIfAvailable: installIfAvailable)
        }
    }

    func install(_ release: GitHubRelease) {
        if isBusy { return }
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            await self?.performInstall(release)
        }
    }

    private func performCheck(force: Bool, installIfAvailable: Bool) async {
        await setState(.checking)
        do {
            let release = try await client.latestRelease()
            if Task.isCancelled { return }
            defaults.set(Date(), forKey: UpdatePreferences.lastCheckKey)
            if AppVersion(release.versionString) <= AppVersion(currentVersion) {
                await setState(.upToDate)
                return
            }
            guard release.zipAsset != nil else {
                await setState(.failed(UpdateError.missingAsset.localizedDescription))
                return
            }
            await setState(.available(release))
            if installIfAvailable {
                await performInstall(release)
            }
        } catch {
            if Task.isCancelled { return }
            await setState(.failed(error.localizedDescription))
        }
    }

    private func performInstall(_ release: GitHubRelease) async {
        guard let asset = release.zipAsset else {
            await setState(.failed(UpdateError.missingAsset.localizedDescription))
            return
        }
        await setState(.downloading)
        do {
            let (tempURL, response) = try await session.download(from: asset.browserDownloadURL)
            if Task.isCancelled { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdateError.network("download failed")
            }
            await setState(.installing)
            let workDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("UsageBarUpdate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            let zipURL = workDirectory.appendingPathComponent(AppDistribution.assetName)
            if FileManager.default.fileExists(atPath: zipURL.path) {
                try FileManager.default.removeItem(at: zipURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: zipURL)
            let extracted = workDirectory.appendingPathComponent("extracted", isDirectory: true)
            let appURL = try unpacker.extractApp(fromZip: zipURL, to: extracted)
            try installer.install(fromAppBundle: appURL)
            try? FileManager.default.removeItem(at: workDirectory)
            installer.relaunch()
        } catch {
            if Task.isCancelled { return }
            await setState(.failed(error.localizedDescription))
        }
    }

    @MainActor
    private func setState(_ newState: UpdateState) {
        state = newState
    }
}
