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
            }
          ]
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.versionString, "1.2.0")
        XCTAssertEqual(release.zipAsset?.name, "UsageBar.app.zip")
        XCTAssertTrue(release.displayNotes?.contains("pull/12") == true)
    }

    @MainActor
    func testCheckMarksCurrentVersionAsUpToDate() async {
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
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
    }

    @MainActor
    func testCheckSurfacesANewerGitHubRelease() async {
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
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
        XCTAssertEqual(updater.statusLine, "Version 1.4.0 is available")
    }

    @MainActor
    func testAutomaticCheckRespectsTheDailyThrottle() {
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
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
    }

    func testInstallerRejectsABundleWithTheWrongIdentifier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Other.app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
        try writeInfo(bundleIdentifier: "com.example.other", to: app)

        let installer = AppUpdateInstaller(destination: root.appendingPathComponent("UsageBar.app"))
        XCTAssertThrowsError(try installer.verifyBundle(at: app)) { error in
            XCTAssertEqual(error as? UpdateError, .invalidAppBundle)
        }
    }

    func testExtractFindsTheAppInsideAZip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("UsageBar.app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try writeInfo(bundleIdentifier: AppDistribution.bundleIdentifier, to: app)
        try Data("binary".utf8).write(to: app.appendingPathComponent("Contents/MacOS/UsageBar"))

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

    private func sampleRelease(tag: String) -> GitHubRelease {
        GitHubRelease(
            tagName: tag,
            name: tag,
            body: "Notes from PRs",
            htmlURL: "https://github.com/DailyXplorer/Usage-Bar/releases/tag/\(tag)",
            assets: [
                GitHubRelease.Asset(
                    name: "UsageBar.app.zip",
                    browserDownloadURL: URL(string: "https://example.com/UsageBar.app.zip")!
                )
            ]
        )
    }

    private func writeInfo(bundleIdentifier: String, to app: URL) throws {
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "Usage Bar"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
    }
}

private final class MockGitHub: GitHubReleasing {
    let release: GitHubRelease
    private(set) var callCount = 0

    init(release: GitHubRelease) {
        self.release = release
    }

    func latestRelease() async throws -> GitHubRelease {
        callCount += 1
        return release
    }
}

private final class MockInstaller: AppUpdateInstalling {
    func install(fromAppBundle url: URL) throws {}
    func relaunch() {}
}
