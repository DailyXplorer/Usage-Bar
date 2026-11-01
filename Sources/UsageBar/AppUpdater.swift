import AppKit
import Combine
import CryptoKit
import Foundation

protocol GitHubReleasing: Sendable {
    func latestRelease() async throws -> GitHubRelease
}

protocol AppUpdateInstalling: Sendable {
    func checkCanInstall() throws
    func install(fromAppBundle url: URL) throws
    func relaunch() throws
}

extension AppUpdateInstalling {
    func checkCanInstall() throws {}
}

enum AppRelaunchCommand {
    static let script = """
    pid="$1"
    app="$2"
    name="$3"
    log="$4"
    while /bin/kill -0 "$pid" >/dev/null 2>&1; do
      /bin/sleep 0.2
    done
    note() {
      /bin/mkdir -p "$(/usr/bin/dirname "$log")" >/dev/null 2>&1
      echo "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ) $1" >> "$log" 2>/dev/null
    }
    started() {
      checks=0
      while [ "$checks" -lt 50 ]; do
        if /usr/bin/pgrep -x "$name" >/dev/null 2>&1; then
          return 0
        fi
        checks=$((checks + 1))
        /bin/sleep 0.2
      done
      return 1
    }
    for attempt in 1 2; do
      /usr/bin/open "$app" >/dev/null 2>&1
      status=$?
      if [ "$status" -eq 0 ] && started; then
        exit 0
      fi
      note "Relaunch attempt $attempt did not start Usage Bar (open exit status $status)."
      /bin/sleep 1
    done
    note "Usage Bar was updated but did not restart. Open it from Applications."
    exit 1
    """

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/UsageBar", isDirectory: true)
            .appendingPathComponent("updater.log")
    }

    static func arguments(
        processIdentifier: Int32,
        appURL: URL,
        executableName: String = AppDistribution.executableName,
        logURL: URL = AppRelaunchCommand.logURL
    ) -> [String] {
        [
            "-c",
            script,
            "UsageBar updater",
            String(processIdentifier),
            appURL.path,
            executableName,
            logURL.path,
        ]
    }

    static func relaunch(
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        appURL: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(processIdentifier: processIdentifier, appURL: appURL)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
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
    var session: URLSession = ProviderSession.shared
    var endpoint: URL = AppDistribution.latestReleaseURL
    var now: @Sendable () -> Date = { Date() }

    func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("UsageBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.unexpectedResponse
        }
        if http.statusCode == 404 {
            throw UpdateError.noReleases
        }
        if let until = Self.rateLimitEnd(of: http, now: now()) {
            throw UpdateError.rateLimited(until: until)
        }
        guard http.statusCode == 200 else {
            throw UpdateError.unexpectedResponse
        }

        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.unexpectedResponse
        }
    }

    static func rateLimitEnd(of response: HTTPURLResponse, now: Date) -> Date? {
        guard response.statusCode == 403 || response.statusCode == 429 else { return nil }
        let latest = now.addingTimeInterval(UpdatePreferences.maximumRateLimitWait)
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), retryAfter >= 0 {
            return min(now.addingTimeInterval(TimeInterval(max(retryAfter, 1))), latest)
        }
        if response.value(forHTTPHeaderField: "X-RateLimit-Remaining")?
            .trimmingCharacters(in: .whitespaces) == "0" {
            if let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
                .flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), reset.isFinite {
                return min(max(Date(timeIntervalSince1970: reset), now.addingTimeInterval(60)), latest)
            }
            return now.addingTimeInterval(60)
        }
        if response.statusCode == 429 {
            return now.addingTimeInterval(60)
        }
        return nil
    }
}

struct AppUpdateInstaller: AppUpdateInstalling {
    var destination: URL = AppDistribution.installURL

    func checkCanInstall() throws {
        try AppBundleReplacement.checkCanReplace(destination)
    }

    func install(fromAppBundle url: URL) throws {
        try verifyBundle(at: url)
        try AppBundleReplacement.clearQuarantine(at: url)
        try AppBundleReplacement.install(from: url, to: destination)
    }

    func relaunch() throws {
        try AppRelaunchCommand.relaunch(appURL: destination)
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
        let fileManager = FileManager.default
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
}

enum UpdateCheckTrigger {
    case launch
    case menu
    case manual
}

@MainActor
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
    private let makeWorkDirectory: () -> URL
    private let now: () -> Date
    private var checkTask: Task<Void, Never>?

    init(
        client: any GitHubReleasing = GitHubReleaseService(),
        installer: any AppUpdateInstalling = AppUpdateInstaller(),
        unpacker: AppUpdateInstaller = AppUpdateInstaller(),
        defaults: UserDefaults = .standard,
        session: URLSession = AppUpdater.downloadSession,
        makeWorkDirectory: @escaping () -> URL = {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("UsageBarUpdate-\(UUID().uuidString)", isDirectory: true)
        },
        now: @escaping () -> Date = Date.init,
        currentVersion: String? = nil
    ) {
        self.client = client
        self.installer = installer
        self.unpacker = unpacker
        self.defaults = defaults
        self.session = session
        self.makeWorkDirectory = makeWorkDirectory
        self.now = now
        self.currentVersion = currentVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0"
        automaticallyChecks = defaults.object(forKey: UpdatePreferences.checksKey) as? Bool ?? true
        automaticallyInstalls = defaults.object(forKey: UpdatePreferences.installsKey) as? Bool ?? false
    }

    nonisolated static let downloadSession: URLSession = {
        let configuration = ProviderSession.configuration
        configuration.timeoutIntervalForResource = 10 * 60
        return URLSession(configuration: configuration)
    }()

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

    var statusLine: String? {
        switch state {
        case .idle:
            return nil
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
        checkForUpdates(trigger: .launch, installIfAvailable: automaticallyInstalls)
    }

    func checkWhenMenuAppears() {
        guard automaticallyChecks else { return }
        switch state {
        case .available, .checking, .downloading, .installing:
            return
        case .idle, .upToDate, .failed:
            checkForUpdates(trigger: .menu, installIfAvailable: automaticallyInstalls)
        }
    }

    func performButtonAction() {
        if case .available(let release) = state {
            install(release)
            return
        }
        checkForUpdates(trigger: .manual, installIfAvailable: false)
    }

    func checkForUpdates(trigger: UpdateCheckTrigger = .launch, installIfAvailable: Bool = false) {
        if isBusy { return }
        let checkDate = now()
        if let until = defaults.object(forKey: UpdatePreferences.rateLimitedUntilKey) as? Date,
           checkDate < until {
            if trigger == .manual {
                state = .failed(UpdateError.rateLimitMessage(until: until, now: checkDate))
            }
            return
        }
        let lastAttempt = defaults.object(forKey: UpdatePreferences.lastAttemptKey) as? Date
        switch trigger {
        case .manual:
            break
        case .menu:
            if let lastAttempt,
               checkDate.timeIntervalSince(lastAttempt) < UpdatePreferences.menuCheckInterval {
                return
            }
        case .launch:
            if let lastCheck = defaults.object(forKey: UpdatePreferences.lastCheckKey) as? Date,
               checkDate.timeIntervalSince(lastCheck) < UpdatePreferences.checkInterval {
                return
            }
            if let lastAttempt,
               checkDate.timeIntervalSince(lastAttempt) < UpdatePreferences.retryInterval {
                return
            }
        }
        defaults.set(checkDate, forKey: UpdatePreferences.lastAttemptKey)
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            await self?.performCheck(installIfAvailable: installIfAvailable)
        }
    }

    func install(_ release: GitHubRelease) {
        if isBusy { return }
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            _ = await self?.performInstall(release)
        }
    }

    func isInstallBackingOff(for version: String) -> Bool {
        guard defaults.string(forKey: UpdatePreferences.failedInstallVersionKey) == version,
              let failedAt = defaults.object(forKey: UpdatePreferences.failedInstallAtKey) as? Date else {
            return false
        }
        let failures = defaults.integer(forKey: UpdatePreferences.failedInstallCountKey)
        return now().timeIntervalSince(failedAt) < UpdatePreferences.installBackoff(afterFailures: failures)
    }

    private func performCheck(installIfAvailable: Bool) async {
        state = .checking
        do {
            let release = try await client.latestRelease()
            if Task.isCancelled {
                state = .idle
                return
            }
            defaults.removeObject(forKey: UpdatePreferences.rateLimitedUntilKey)
            if AppVersion(release.versionString) <= AppVersion(currentVersion) {
                recordSuccessfulCheck()
                state = .upToDate
                return
            }
            guard release.zipAsset != nil else {
                state = .failed(UpdateError.missingAsset.localizedDescription)
                return
            }
            guard release.checksumAsset != nil else {
                state = .failed(UpdateError.missingChecksum.localizedDescription)
                return
            }
            guard release.assetsAreTrusted else {
                state = .failed(UpdateError.untrustedAsset.localizedDescription)
                return
            }
            if installIfAvailable, !isInstallBackingOff(for: release.versionString) {
                if await performInstall(release) {
                    recordSuccessfulCheck()
                }
            } else {
                recordSuccessfulCheck()
                state = .available(release)
            }
        } catch {
            if Task.isCancelled {
                state = .idle
                return
            }
            let failure = UpdateError.plain(error, fallback: .unexpectedResponse)
            if case .rateLimited(let until) = failure {
                defaults.set(until, forKey: UpdatePreferences.rateLimitedUntilKey)
                state = .failed(UpdateError.rateLimitMessage(until: until, now: now()))
                return
            }
            state = .failed(failure.localizedDescription)
        }
    }

    private func performInstall(_ release: GitHubRelease) async -> Bool {
        guard let asset = release.zipAsset else {
            state = .failed(UpdateError.missingAsset.localizedDescription)
            return false
        }
        guard let checksumAsset = release.checksumAsset else {
            state = .failed(UpdateError.missingChecksum.localizedDescription)
            return false
        }
        guard release.assetsAreTrusted else {
            state = .failed(UpdateError.untrustedAsset.localizedDescription)
            return false
        }
        do {
            try installer.checkCanInstall()
        } catch {
            recordFailedInstall(of: release)
            state = .failed(UpdateError.plain(error, fallback: .destinationNotWritable).localizedDescription)
            return false
        }
        state = .downloading
        do {
            let checksumData: Data
            let checksumResponse: URLResponse
            do {
                (checksumData, checksumResponse) = try await session.data(
                    from: checksumAsset.browserDownloadURL
                )
            } catch {
                throw UpdateError.downloadFailed
            }
            if Task.isCancelled {
                state = .idle
                return false
            }
            guard let checksumHTTP = checksumResponse as? HTTPURLResponse,
                  checksumHTTP.statusCode == 200 else {
                throw UpdateError.downloadFailed
            }
            let tempURL: URL
            let response: URLResponse
            do {
                (tempURL, response) = try await session.download(from: asset.browserDownloadURL)
            } catch {
                throw UpdateError.downloadFailed
            }
            defer { try? FileManager.default.removeItem(at: tempURL) }
            if Task.isCancelled {
                state = .idle
                return false
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdateError.downloadFailed
            }
            state = .installing
            let workDirectory = makeWorkDirectory()
            let unpacker = self.unpacker
            let installer = self.installer
            let installationTask = Task.detached(priority: .userInitiated) {
                let fileManager = FileManager.default
                try Task.checkCancellation()
                try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
                defer { try? fileManager.removeItem(at: workDirectory) }
                let zipURL = workDirectory.appendingPathComponent(AppDistribution.assetName)
                if fileManager.fileExists(atPath: zipURL.path) {
                    try fileManager.removeItem(at: zipURL)
                }
                try fileManager.moveItem(at: tempURL, to: zipURL)
                try Task.checkCancellation()
                try UpdateChecksum.verify(fileURL: zipURL, checksumData: checksumData)
                try Task.checkCancellation()
                let extracted = workDirectory.appendingPathComponent("extracted", isDirectory: true)
                let appURL = try unpacker.extractApp(fromZip: zipURL, to: extracted)
                try Task.checkCancellation()
                try installer.install(fromAppBundle: appURL)
            }
            try await withTaskCancellationHandler {
                try await installationTask.value
            } onCancel: {
                installationTask.cancel()
            }
            if Task.isCancelled {
                state = .idle
                return false
            }
            clearFailedInstall()
            try installer.relaunch()
            return true
        } catch {
            if Task.isCancelled {
                state = .idle
                return false
            }
            recordFailedInstall(of: release)
            state = .failed(UpdateError.plain(error, fallback: .installFailed).localizedDescription)
            return false
        }
    }

    private func recordSuccessfulCheck() {
        defaults.set(now(), forKey: UpdatePreferences.lastCheckKey)
    }

    private func recordFailedInstall(of release: GitHubRelease) {
        let version = release.versionString
        let previous = defaults.string(forKey: UpdatePreferences.failedInstallVersionKey) == version
            ? defaults.integer(forKey: UpdatePreferences.failedInstallCountKey)
            : 0
        defaults.set(version, forKey: UpdatePreferences.failedInstallVersionKey)
        defaults.set(now(), forKey: UpdatePreferences.failedInstallAtKey)
        defaults.set(previous + 1, forKey: UpdatePreferences.failedInstallCountKey)
    }

    private func clearFailedInstall() {
        defaults.removeObject(forKey: UpdatePreferences.failedInstallVersionKey)
        defaults.removeObject(forKey: UpdatePreferences.failedInstallAtKey)
        defaults.removeObject(forKey: UpdatePreferences.failedInstallCountKey)
    }
}
