import AppKit
import Combine
import CryptoKit
import Foundation

protocol GitHubReleasing {
    func latestRelease() async throws -> GitHubRelease
}

protocol AppUpdateInstalling {
    func install(fromAppBundle url: URL) throws
    func relaunch() throws
}

enum AppRelaunchCommand {
    static let script = """
    while /bin/kill -0 "$1" >/dev/null 2>&1; do
      /bin/sleep 0.2
    done
    /usr/bin/open "$2"
    """

    static func arguments(processIdentifier: Int32, appURL: URL) -> [String] {
        [
            "-c",
            script,
            "UsageBar updater",
            String(processIdentifier),
            appURL.path,
        ]
    }
}

enum UpdateChecksum {
    static func expectedHash(from data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8),
              let hash = text.split(whereSeparator: \.isWhitespace).first else {
            throw UpdateError.invalidChecksum
        }
        let normalized = hash.lowercased()
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        guard normalized.count == 64,
              normalized.unicodeScalars.allSatisfy(hexadecimal.contains) else {
            throw UpdateError.invalidChecksum
        }
        return normalized
    }

    static func hash(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verify(fileURL: URL, checksumData: Data) throws {
        guard try hash(of: fileURL) == expectedHash(from: checksumData) else {
            throw UpdateError.checksumMismatch
        }
    }
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
        try AppBundleReplacement.install(from: url, to: destination, fileManager: fileManager)
        try clearQuarantine(at: destination)
    }

    func relaunch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = AppRelaunchCommand.arguments(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            appURL: destination
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
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
              identifier == AppDistribution.bundleIdentifier,
              let executable = info["CFBundleExecutable"] as? String,
              executable == AppDistribution.executableName else {
            throw UpdateError.invalidAppBundle
        }
        try verifyCodeSignature(at: url)
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
        let app = directory.appendingPathComponent(AppDistribution.installURL.lastPathComponent)
        let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw UpdateError.extractFailed
        }
        return app
    }

    private func verifyCodeSignature(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.invalidCodeSignature
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.invalidCodeSignature
        }
    }

    private func clearQuarantine(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
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
    private let fileManager: FileManager
    private let makeWorkDirectory: () -> URL
    private var checkTask: Task<Void, Never>?

    init(
        client: any GitHubReleasing = GitHubReleaseService(),
        installer: any AppUpdateInstalling = AppUpdateInstaller(),
        unpacker: AppUpdateInstaller = AppUpdateInstaller(),
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        makeWorkDirectory: @escaping () -> URL = {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("UsageBarUpdate-\(UUID().uuidString)", isDirectory: true)
        },
        currentVersion: String? = nil
    ) {
        self.client = client
        self.installer = installer
        self.unpacker = unpacker
        self.defaults = defaults
        self.session = session
        self.fileManager = fileManager
        self.makeWorkDirectory = makeWorkDirectory
        self.currentVersion = currentVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0"
        automaticallyChecks = defaults.object(forKey: UpdatePreferences.checksKey) as? Bool ?? true
        automaticallyInstalls = defaults.object(forKey: UpdatePreferences.installsKey) as? Bool ?? false
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
        if !force,
           let last = defaults.object(forKey: UpdatePreferences.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < UpdatePreferences.checkInterval {
            return
        }
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            await self?.performCheck(installIfAvailable: installIfAvailable)
        }
    }

    func install(_ release: GitHubRelease) {
        if isBusy { return }
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            await self?.performInstall(release)
        }
    }

    private func performCheck(installIfAvailable: Bool) async {
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
            guard release.checksumAsset != nil else {
                await setState(.failed(UpdateError.missingChecksum.localizedDescription))
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
        guard let checksumAsset = release.checksumAsset else {
            await setState(.failed(UpdateError.missingChecksum.localizedDescription))
            return
        }
        await setState(.downloading)
        do {
            let (checksumData, checksumResponse) = try await session.data(
                from: checksumAsset.browserDownloadURL
            )
            guard let checksumHTTP = checksumResponse as? HTTPURLResponse,
                  checksumHTTP.statusCode == 200 else {
                throw UpdateError.network("checksum download failed")
            }
            let (tempURL, response) = try await session.download(from: asset.browserDownloadURL)
            if Task.isCancelled { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdateError.network("download failed")
            }
            await setState(.installing)
            let workDirectory = makeWorkDirectory()
            try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: workDirectory) }
            let zipURL = workDirectory.appendingPathComponent(AppDistribution.assetName)
            if fileManager.fileExists(atPath: zipURL.path) {
                try fileManager.removeItem(at: zipURL)
            }
            try fileManager.moveItem(at: tempURL, to: zipURL)
            try UpdateChecksum.verify(fileURL: zipURL, checksumData: checksumData)
            let extracted = workDirectory.appendingPathComponent("extracted", isDirectory: true)
            let appURL = try unpacker.extractApp(fromZip: zipURL, to: extracted)
            try installer.install(fromAppBundle: appURL)
            try installer.relaunch()
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
