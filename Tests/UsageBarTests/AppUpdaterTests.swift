import XCTest
@testable import UsageBar

final class AppUpdaterTests: XCTestCase {
    func testVersionOrderTreatsMissingComponentsAsZero() {
        XCTAssertEqual(AppVersion("v1.2.0"), AppVersion("1.2.0"))
        XCTAssertLessThan(AppVersion("1.0"), AppVersion("1.0.1"))
        XCTAssertLessThan(AppVersion("1.9.0"), AppVersion("1.10.0"))
        XCTAssertFalse(AppVersion("1.2.0") < AppVersion("1.2"))
        XCTAssertFalse(AppVersion("1.2") < AppVersion("1.2.0"))
    }

    func testVersionOrderFollowsSemanticPrereleaseRules() {
        XCTAssertLessThan(AppVersion("1.3.0-beta.1"), AppVersion("1.3.0-beta.2"))
        XCTAssertLessThan(AppVersion("1.3.0-beta.2"), AppVersion("1.3.0"))
        XCTAssertLessThan(AppVersion("1.3.0-1"), AppVersion("1.3.0-beta"))
        XCTAssertEqual(AppVersion("1.3.0+build.1"), AppVersion("1.3.0+build.2"))
        XCTAssertEqual(AppVersion("v1.3.0+build.42").description, "1.3.0")
    }

    func testGitHubReleaseDecodesNotesAndZipAsset() throws {
        let json = """
        {
          "tag_name": "v1.2.0",
          "name": "1.2.0",
          "body": "## What's Changed\\n* Add launch at login by @daily in https://github.com/DailyXplorer/Usage-Bar/pull/12",
          "html_url": "https://github.com/DailyXplorer/Usage-Bar/releases/tag/v1.2.0",
          "assets": [
            {
              "name": "UsageBar.app.zip",
              "browser_download_url": "https://github.com/DailyXplorer/Usage-Bar/releases/download/v1.2.0/UsageBar.app.zip"
            },
            {
              "name": "UsageBar.app.zip.sha256",
              "browser_download_url": "https://github.com/DailyXplorer/Usage-Bar/releases/download/v1.2.0/UsageBar.app.zip.sha256"
            }
          ]
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.versionString, "1.2.0")
        XCTAssertEqual(release.zipAsset?.name, "UsageBar.app.zip")
        XCTAssertEqual(release.checksumAsset?.name, "UsageBar.app.zip.sha256")
        XCTAssertTrue(release.assetsAreTrusted)
        XCTAssertTrue(release.displayNotes?.contains("pull/12") == true)
    }

    @MainActor
    func testAutomaticInstallationRequiresOptInByDefault() throws {
        let defaults = try makeDefaults(named: #function)
        let updater = AppUpdater(
            client: MockGitHub(release: sampleRelease(tag: "v1.1.0")),
            installer: MockInstaller(),
            defaults: defaults,
            currentVersion: "1.0.0"
        )

        XCTAssertTrue(updater.automaticallyChecks)
        XCTAssertFalse(updater.automaticallyInstalls)
    }

    @MainActor
    func testCheckMarksCurrentVersionAsUpToDate() async throws {
        let defaults = try makeDefaults(named: #function)
        let updater = AppUpdater(
            client: MockGitHub(release: sampleRelease(tag: "v1.0.0")),
            installer: MockInstaller(),
            defaults: defaults,
            currentVersion: "1.0.0"
        )

        updater.checkForUpdates(force: true)
        await waitForState(updater) { $0 == .upToDate }

        XCTAssertEqual(updater.state, .upToDate)
        XCTAssertEqual(updater.buttonTitle, "Check for Updates")
        XCTAssertNotNil(defaults.object(forKey: UpdatePreferences.lastCheckKey) as? Date)
        XCTAssertNotNil(defaults.object(forKey: UpdatePreferences.lastAttemptKey) as? Date)
    }

    @MainActor
    func testCheckSurfacesANewerGitHubRelease() async throws {
        let defaults = try makeDefaults(named: #function)
        let release = sampleRelease(tag: "v1.4.0")
        let updater = AppUpdater(
            client: MockGitHub(release: release),
            installer: MockInstaller(),
            defaults: defaults,
            currentVersion: "1.0.0"
        )

        updater.checkForUpdates(force: true, installIfAvailable: false)
        await waitForState(updater) { if case .available = $0 { return true }; return false }

        XCTAssertEqual(updater.availableRelease?.versionString, "1.4.0")
        XCTAssertEqual(updater.buttonTitle, "Install 1.4.0")
        XCTAssertEqual(updater.statusLine, Optional("Version 1.4.0 is available"))
    }

    @MainActor
    func testCheckRejectsAReleaseWithoutItsChecksum() async throws {
        let defaults = try makeDefaults(named: #function)
        let release = GitHubRelease(
            tagName: "v1.4.0",
            name: "1.4.0",
            body: nil,
            htmlURL: "https://github.com/DailyXplorer/Usage-Bar/releases/tag/v1.4.0",
            assets: [
                GitHubRelease.Asset(
                    name: AppDistribution.assetName,
                    browserDownloadURL: URL(string: "https://example.com/UsageBar.app.zip")!
                )
            ]
        )
        let updater = AppUpdater(
            client: MockGitHub(release: release),
            installer: MockInstaller(),
            defaults: defaults,
            currentVersion: "1.0.0"
        )

        updater.checkForUpdates(force: true)
        await waitForState(updater) {
            $0 == .failed(UpdateError.missingChecksum.localizedDescription)
        }

        XCTAssertNil(updater.availableRelease)
    }

    @MainActor
    func testCheckRejectsAssetsOutsideTheExpectedRelease() async throws {
        let defaults = try makeDefaults(named: #function)
        let release = GitHubRelease(
            tagName: "v1.4.0",
            name: "1.4.0",
            body: nil,
            htmlURL: "https://github.com/DailyXplorer/Usage-Bar/releases/tag/v1.4.0",
            assets: [
                GitHubRelease.Asset(
                    name: AppDistribution.assetName,
                    browserDownloadURL: URL(string: "https://example.com/UsageBar.app.zip")!
                ),
                GitHubRelease.Asset(
                    name: AppDistribution.checksumAssetName,
                    browserDownloadURL: URL(string: "https://example.com/UsageBar.app.zip.sha256")!
                ),
            ]
        )
        let updater = AppUpdater(
            client: MockGitHub(release: release),
            installer: MockInstaller(),
            defaults: defaults,
            currentVersion: "1.0.0"
        )

        updater.checkForUpdates(force: true)
        await waitForState(updater) {
            $0 == .failed(UpdateError.untrustedAsset.localizedDescription)
        }

        XCTAssertNil(updater.availableRelease)
    }

    @MainActor
    func testFailedCheckUsesShortRetryThrottleWithoutClaimingSuccess() async throws {
        let defaults = try makeDefaults(named: #function)
        let client = FailingGitHub()
        let updater = AppUpdater(
            client: client,
            installer: MockInstaller(),
            defaults: defaults,
            currentVersion: "1.0.0"
        )

        updater.checkForUpdates(force: true)
        await waitForState(updater) {
            $0 == .failed(UpdateError.network("offline").localizedDescription)
        }

        XCTAssertNil(defaults.object(forKey: UpdatePreferences.lastCheckKey) as? Date)
        XCTAssertNotNil(defaults.object(forKey: UpdatePreferences.lastAttemptKey) as? Date)

        updater.startAutomaticChecks()

        XCTAssertEqual(client.callCount, 1)
    }

    @MainActor
    func testAutomaticCheckRetriesAfterTheFailureBackoff() async throws {
        let defaults = try makeDefaults(named: #function)
        let now = Date(timeIntervalSince1970: 1_786_402_800)
        defaults.set(
            now.addingTimeInterval(-UpdatePreferences.retryInterval - 1),
            forKey: UpdatePreferences.lastAttemptKey
        )
        let client = MockGitHub(release: sampleRelease(tag: "v1.0.0"))
        let updater = AppUpdater(
            client: client,
            installer: MockInstaller(),
            defaults: defaults,
            now: { now },
            currentVersion: "1.0.0"
        )

        updater.startAutomaticChecks()
        await waitForState(updater) { $0 == .upToDate }

        XCTAssertEqual(client.callCount, 1)
        XCTAssertEqual(defaults.object(forKey: UpdatePreferences.lastCheckKey) as? Date, now)
    }

    @MainActor
    func testAutomaticCheckRespectsTheDailyThrottle() throws {
        let defaults = try makeDefaults(named: #function)
        defaults.set(Date(), forKey: UpdatePreferences.lastCheckKey)
        let client = MockGitHub(release: sampleRelease(tag: "v9.0.0"))
        let updater = AppUpdater(
            client: client,
            installer: MockInstaller(),
            defaults: defaults,
            currentVersion: "1.0.0"
        )

        updater.startAutomaticChecks()

        XCTAssertEqual(client.callCount, 0)
        XCTAssertEqual(updater.state, .idle)
        XCTAssertNil(updater.statusLine)
    }

    @MainActor
    func testForcedCheckBypassesTheDailyThrottle() async throws {
        let defaults = try makeDefaults(named: #function)
        defaults.set(Date(), forKey: UpdatePreferences.lastCheckKey)
        defaults.set(Date(), forKey: UpdatePreferences.lastAttemptKey)
        let client = MockGitHub(release: sampleRelease(tag: "v1.0.0"))
        let updater = AppUpdater(
            client: client,
            installer: MockInstaller(),
            defaults: defaults,
            currentVersion: "1.0.0"
        )

        updater.checkForUpdates()
        XCTAssertEqual(client.callCount, 0)

        updater.checkForUpdates(force: true)
        await waitForState(updater) { $0 == .upToDate }
        XCTAssertEqual(client.callCount, 1)
    }

    func testUpdateActionStaysVisibleForEveryActionableState() {
        let release = sampleRelease(tag: "v1.1.0")

        XCTAssertFalse(UpdateState.idle.showsUpdateAction)
        XCTAssertFalse(UpdateState.checking.showsUpdateAction)
        XCTAssertFalse(UpdateState.upToDate.showsUpdateAction)
        XCTAssertTrue(UpdateState.available(release).showsUpdateAction)
        XCTAssertTrue(UpdateState.downloading.showsUpdateAction)
        XCTAssertTrue(UpdateState.installing.showsUpdateAction)
        XCTAssertTrue(UpdateState.failed("offline").showsUpdateAction)
    }

    func testChecksumVerificationAcceptsThePublishedArchiveHash() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent(AppDistribution.assetName)
        try Data("abc".utf8).write(to: archive)
        let checksum = Data(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  UsageBar.app.zip\n".utf8
        )

        XCTAssertNoThrow(try UpdateChecksum.verify(fileURL: archive, checksumData: checksum))
        XCTAssertThrowsError(
            try UpdateChecksum.verify(
                fileURL: archive,
                checksumData: Data("0000000000000000000000000000000000000000000000000000000000000000\n".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? UpdateError, .checksumMismatch)
        }
    }

    func testRelaunchWaitsForTheCurrentProcessWithoutMatchingItsOwnShell() {
        let appURL = URL(fileURLWithPath: "/Applications/Usage Bar.app")
        let arguments = AppRelaunchCommand.arguments(processIdentifier: 12_345, appURL: appURL)

        XCTAssertEqual(arguments[0], "-c")
        XCTAssertTrue(arguments[1].contains("/bin/kill -0 \"$1\""))
        XCTAssertFalse(arguments[1].contains("pgrep"))
        XCTAssertEqual(arguments.suffix(2), ["12345", appURL.path])
    }

    func testInstallerRejectsABundleWithTheWrongIdentifier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Other.app")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(at: app, bundleIdentifier: "com.example.other", signed: false)

        let installer = AppUpdateInstaller(destination: root.appendingPathComponent("UsageBar.app"))
        XCTAssertThrowsError(try installer.verifyBundle(at: app)) { error in
            XCTAssertEqual(error as? UpdateError, .invalidAppBundle)
        }
    }

    func testInstallerRejectsAnUnsignedUsageBarBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("UsageBar.app")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(at: app, signed: false)

        let installer = AppUpdateInstaller(destination: root.appendingPathComponent("Installed.app"))
        XCTAssertThrowsError(try installer.verifyBundle(at: app)) { error in
            XCTAssertEqual(error as? UpdateError, .invalidCodeSignature)
        }
    }

    func testInstallerReplacesAnExistingAppWithAVerifiedBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("UsageBar.app")
        let destination = root.appendingPathComponent("Applications/UsageBar.app")
        let oldMarker = destination.appendingPathComponent("Contents/old")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(at: source, signed: true)
        try FileManager.default.createDirectory(
            at: oldMarker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: oldMarker)

        let installer = AppUpdateInstaller(destination: destination)
        try installer.install(fromAppBundle: source)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldMarker.path))
        XCTAssertNoThrow(try installer.verifyBundle(at: destination))
    }

    func testExtractFindsTheAppInsideAZip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("UsageBar.app")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(at: app, signed: true)

        let zip = root.appendingPathComponent("UsageBar.app.zip")
        let zipProcess = Process()
        zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zipProcess.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        try zipProcess.run()
        zipProcess.waitUntilExit()
        XCTAssertEqual(zipProcess.terminationStatus, 0)

        let installer = AppUpdateInstaller()
        let extracted = root.appendingPathComponent("extracted")
        let found = try installer.extractApp(fromZip: zip, to: extracted)
        try installer.verifyBundle(at: found)
        XCTAssertEqual(found.lastPathComponent, "UsageBar.app")
    }

    @MainActor
    func testFailedInstallRemovesItsWorkDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workDirectory = root.appendingPathComponent("work", isDirectory: true)
        defer {
            UpdateURLProtocol.responses = [:]
            try? FileManager.default.removeItem(at: root)
        }

        let release = sampleRelease(tag: "v2.0.0")
        let zipURL = try XCTUnwrap(release.zipAsset?.browserDownloadURL)
        let checksumURL = try XCTUnwrap(release.checksumAsset?.browserDownloadURL)
        UpdateURLProtocol.responses = [
            zipURL: Data("not a zip".utf8),
            checksumURL: Data("0000000000000000000000000000000000000000000000000000000000000000\n".utf8),
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateURLProtocol.self]
        let defaults = try makeDefaults(named: #function)
        let updater = AppUpdater(
            client: MockGitHub(release: release),
            installer: MockInstaller(),
            defaults: defaults,
            session: URLSession(configuration: configuration),
            makeWorkDirectory: { workDirectory },
            currentVersion: "1.0.0"
        )

        updater.install(release)
        await waitForState(updater) {
            $0 == .failed(UpdateError.checksumMismatch.localizedDescription)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: workDirectory.path))
    }

    @MainActor
    private func waitForState(
        _ updater: AppUpdater,
        timeout: TimeInterval = 2,
        predicate: @escaping (UpdateState) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(updater.state) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for updater state, last state: \(updater.state)")
    }

    private func makeDefaults(named name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        return defaults
    }

    private func sampleRelease(tag: String) -> GitHubRelease {
        GitHubRelease(
            tagName: tag,
            name: tag,
            body: "Notes from PRs",
            htmlURL: "https://github.com/DailyXplorer/Usage-Bar/releases/tag/\(tag)",
            assets: [
                GitHubRelease.Asset(
                    name: "UsageBar.app.zip",
                    browserDownloadURL: AppDistribution.trustedAssetURL(
                        named: AppDistribution.assetName,
                        releaseTag: tag
                    )!
                ),
                GitHubRelease.Asset(
                    name: "UsageBar.app.zip.sha256",
                    browserDownloadURL: AppDistribution.trustedAssetURL(
                        named: AppDistribution.checksumAssetName,
                        releaseTag: tag
                    )!
                )
            ]
        )
    }

    private func writeInfo(bundleIdentifier: String, to app: URL) throws {
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "Usage Bar",
            "CFBundleExecutable": AppDistribution.executableName,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
    }

    private func makeApp(
        at app: URL,
        bundleIdentifier: String = AppDistribution.bundleIdentifier,
        signed: Bool
    ) throws {
        let executable = app.appendingPathComponent("Contents/MacOS/UsageBar")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        try writeInfo(bundleIdentifier: bundleIdentifier, to: app)
        guard signed else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private final class MockGitHub: GitHubReleasing, @unchecked Sendable {
    let release: GitHubRelease
    private let counter = LockedCounter()

    var callCount: Int { counter.value }

    init(release: GitHubRelease) {
        self.release = release
    }

    func latestRelease() async throws -> GitHubRelease {
        counter.increment()
        return release
    }
}

private final class FailingGitHub: GitHubReleasing, @unchecked Sendable {
    private let counter = LockedCounter()

    var callCount: Int { counter.value }

    func latestRelease() async throws -> GitHubRelease {
        counter.increment()
        throw UpdateError.network("offline")
    }
}

private struct MockInstaller: AppUpdateInstalling {
    func install(fromAppBundle url: URL) throws {}
    func relaunch() throws {}
}

private final class UpdateURLProtocol: URLProtocol {
    private static let responseStore = LockedResponses()

    static var responses: [URL: Data] {
        get { responseStore.value }
        set { responseStore.value = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let data = Self.responses[url],
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class LockedResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL: Data] = [:]

    var value: [URL: Data] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
