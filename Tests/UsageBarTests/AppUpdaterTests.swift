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

        updater.checkForUpdates(trigger: .manual)
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

        updater.checkForUpdates(trigger: .manual, installIfAvailable: false)
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

        updater.checkForUpdates(trigger: .manual)
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

        updater.checkForUpdates(trigger: .manual)
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

        updater.checkForUpdates(trigger: .manual)
        await waitForState(updater) {
            $0 == .failed(UpdateError.network.localizedDescription)
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
    func testMenuAppearanceChecksAtMostEverySixHours() async throws {
        let defaults = try makeDefaults(named: #function)
        let clock = TestClock(Date(timeIntervalSince1970: 1_786_402_800))
        defaults.set(clock.date.addingTimeInterval(-60 * 60), forKey: UpdatePreferences.lastAttemptKey)
        let client = MockGitHub(release: sampleRelease(tag: "v1.0.0"))
        let updater = AppUpdater(
            client: client,
            installer: MockInstaller(),
            defaults: defaults,
            now: { clock.date },
            currentVersion: "1.0.0"
        )

        updater.checkWhenMenuAppears()
        XCTAssertEqual(client.callCount, 0)
        XCTAssertEqual(updater.state, .idle)

        clock.date = clock.date.addingTimeInterval(UpdatePreferences.menuCheckInterval)
        updater.checkWhenMenuAppears()
        await waitForState(updater) { $0 == .upToDate }
        XCTAssertEqual(client.callCount, 1)

        updater.checkWhenMenuAppears()
        XCTAssertEqual(client.callCount, 1)
        XCTAssertEqual(UpdatePreferences.menuCheckInterval, 6 * 60 * 60)
    }

    @MainActor
    func testManualCheckRunsRightAfterAMenuCheck() async throws {
        let defaults = try makeDefaults(named: #function)
        let client = MockGitHub(release: sampleRelease(tag: "v1.0.0"))
        let updater = AppUpdater(
            client: client,
            installer: MockInstaller(),
            defaults: defaults,
            currentVersion: "1.0.0"
        )

        updater.checkWhenMenuAppears()
        await waitForState(updater) { $0 == .upToDate }
        updater.performButtonAction()
        await waitForState(updater) { $0 == .upToDate && client.callCount == 2 }

        XCTAssertEqual(client.callCount, 2)
    }

    @MainActor
    func testRateLimitPausesEveryCheckUntilGitHubResets() async throws {
        let defaults = try makeDefaults(named: #function)
        let clock = TestClock(Date(timeIntervalSince1970: 1_786_402_800))
        let client = RateLimitedGitHub(until: clock.date.addingTimeInterval(10 * 60))
        let updater = AppUpdater(
            client: client,
            installer: MockInstaller(),
            defaults: defaults,
            now: { clock.date },
            currentVersion: "1.0.0"
        )

        updater.performButtonAction()
        await waitForState(updater) {
            $0 == .failed("GitHub is limiting update checks. Try again in 10 minutes.")
        }
        XCTAssertEqual(
            defaults.object(forKey: UpdatePreferences.rateLimitedUntilKey) as? Date,
            clock.date.addingTimeInterval(10 * 60)
        )

        clock.date = clock.date.addingTimeInterval(9 * 60 + 30)
        defaults.set(
            clock.date.addingTimeInterval(-UpdatePreferences.menuCheckInterval - 1),
            forKey: UpdatePreferences.lastAttemptKey
        )
        updater.checkWhenMenuAppears()
        updater.performButtonAction()
        XCTAssertEqual(client.callCount, 1)
        XCTAssertEqual(updater.state, .failed("GitHub is limiting update checks. Try again in 1 minute."))

        clock.date = clock.date.addingTimeInterval(31)
        updater.performButtonAction()
        await waitForState(updater) { _ in client.callCount == 2 }
        XCTAssertEqual(client.callCount, 2)
    }

    @MainActor
    func testFailingAutomaticInstallBacksOffForThatVersionWithoutDownloading() async throws {
        let defaults = try makeDefaults(named: #function)
        defer { UpdateURLProtocol.responses = [:] }
        UpdateURLProtocol.responses = [:]
        UpdateURLProtocol.requests.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = TestClock(Date(timeIntervalSince1970: 1_786_402_800))
        let installer = ReadOnlyInstaller()
        defaults.set(true, forKey: UpdatePreferences.installsKey)
        let client = MockGitHub(release: sampleRelease(tag: "v1.4.0"))
        let firstLaunch = AppUpdater(
            client: client,
            installer: installer,
            defaults: defaults,
            session: session,
            now: { clock.date },
            currentVersion: "1.0.0"
        )

        firstLaunch.startAutomaticChecks()
        await waitForState(firstLaunch) {
            $0 == .failed(UpdateError.destinationNotWritable.localizedDescription)
        }
        XCTAssertEqual(installer.checkCount, 1)
        XCTAssertEqual(UpdateURLProtocol.requests.value, 0)
        XCTAssertTrue(firstLaunch.isInstallBackingOff(for: "1.4.0"))

        clock.date = clock.date.addingTimeInterval(UpdatePreferences.menuCheckInterval + 1)
        let secondLaunch = AppUpdater(
            client: client,
            installer: installer,
            defaults: defaults,
            session: session,
            now: { clock.date },
            currentVersion: "1.0.0"
        )
        secondLaunch.checkWhenMenuAppears()
        await waitForState(secondLaunch) { if case .available = $0 { return true }; return false }
        XCTAssertEqual(client.callCount, 2)
        XCTAssertEqual(installer.checkCount, 1)

        secondLaunch.performButtonAction()
        await waitForState(secondLaunch) {
            $0 == .failed(UpdateError.destinationNotWritable.localizedDescription)
        }
        XCTAssertEqual(installer.checkCount, 2)
        XCTAssertEqual(UpdateURLProtocol.requests.value, 0)
        XCTAssertEqual(defaults.integer(forKey: UpdatePreferences.failedInstallCountKey), 2)

        clock.date = clock.date.addingTimeInterval(UpdatePreferences.installBackoff(afterFailures: 2))
        XCTAssertFalse(secondLaunch.isInstallBackingOff(for: "1.4.0"))
        XCTAssertFalse(secondLaunch.isInstallBackingOff(for: "1.5.0"))
    }

    func testInstallBackoffDoublesUpToAWeek() {
        XCTAssertEqual(UpdatePreferences.installBackoff(afterFailures: 1), 24 * 60 * 60)
        XCTAssertEqual(UpdatePreferences.installBackoff(afterFailures: 2), 48 * 60 * 60)
        XCTAssertEqual(UpdatePreferences.installBackoff(afterFailures: 30), 7 * 24 * 60 * 60)
    }

    func testUpdateErrorsReadAsPlainSentences() {
        let errors: [UpdateError] = [
            .network, .unexpectedResponse, .rateLimited(until: Date()), .noReleases,
            .missingAsset, .missingChecksum, .untrustedAsset, .downloadFailed,
            .invalidChecksum, .checksumMismatch, .extractFailed, .invalidAppBundle,
            .invalidCodeSignature, .quarantineRemovalFailed, .destinationNotWritable,
            .installFailed,
        ]
        for error in errors {
            let message = error.localizedDescription
            XCTAssertTrue(message.hasSuffix("."), message)
            XCTAssertNil(message.range(of: "HTTP", options: .caseInsensitive), message)
            XCTAssertNil(message.range(of: "://"), message)
            XCTAssertNil(message.range(of: ".zip"), message)
            XCTAssertNil(message.rangeOfCharacter(from: .decimalDigits), message)
        }
        XCTAssertEqual(
            UpdateError.plain(URLError(.notConnectedToInternet), fallback: .installFailed),
            .installFailed
        )
    }

    func testReleaseServiceTurnsAnExhaustedRateLimitIntoAPause() async throws {
        let now = Date(timeIntervalSince1970: 1_786_402_800)
        let reset = Int(now.timeIntervalSince1970) + 20 * 60
        let service = stubbedService(now: now, status: 403, headers: [
            "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset": String(reset),
        ])

        do {
            _ = try await service.latestRelease()
            XCTFail("expected a rate limit")
        } catch {
            XCTAssertEqual(
                error as? UpdateError,
                .rateLimited(until: Date(timeIntervalSince1970: TimeInterval(reset)))
            )
        }
    }

    func testReleaseServiceCapsRateLimitPausesAndHonorsRetryAfter() throws {
        let now = Date(timeIntervalSince1970: 1_786_402_800)
        let url = AppDistribution.latestReleaseURL
        let farReset = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: [
            "x-ratelimit-remaining": "0",
            "x-ratelimit-reset": String(Int(now.timeIntervalSince1970) + 86_400),
        ]))
        let retryAfter = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: [
            "Retry-After": "120",
        ]))
        let forbidden = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: [
            "X-RateLimit-Remaining": "12",
        ]))

        XCTAssertEqual(
            GitHubReleaseService.rateLimitEnd(of: farReset, now: now),
            now.addingTimeInterval(UpdatePreferences.maximumRateLimitWait)
        )
        XCTAssertEqual(GitHubReleaseService.rateLimitEnd(of: retryAfter, now: now), now.addingTimeInterval(120))
        XCTAssertNil(GitHubReleaseService.rateLimitEnd(of: forbidden, now: now))
    }

    func testReleaseServiceReportsOtherFailuresWithoutTheirDetails() async {
        let now = Date(timeIntervalSince1970: 1_786_402_800)
        let forbidden = stubbedService(now: now, status: 403, headers: [:])
        let offline = stubbedService(now: now, status: nil, headers: [:])

        do {
            _ = try await forbidden.latestRelease()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? UpdateError, .unexpectedResponse)
        }
        do {
            _ = try await offline.latestRelease()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? UpdateError, .network)
        }
    }

    func testReleaseServiceUsesTheUncachedProviderSession() {
        XCTAssertTrue(GitHubReleaseService().session === ProviderSession.shared)
        XCTAssertNil(AppUpdater.downloadSession.configuration.urlCache)
        XCTAssertEqual(
            AppUpdater.downloadSession.configuration.requestCachePolicy,
            .reloadIgnoringLocalAndRemoteCacheData
        )
    }

    @MainActor
    func testMenuAppearanceCheckStaysOffWhenAutomaticChecksAreDisabled() throws {
        let defaults = try makeDefaults(named: #function)
        defaults.set(false, forKey: UpdatePreferences.checksKey)
        let client = MockGitHub(release: sampleRelease(tag: "v9.0.0"))
        let updater = AppUpdater(
            client: client,
            installer: MockInstaller(),
            defaults: defaults,
            currentVersion: "1.0.0"
        )

        updater.checkWhenMenuAppears()

        XCTAssertEqual(client.callCount, 0)
        XCTAssertEqual(updater.state, .idle)
    }

    @MainActor
    func testMenuAppearanceCheckKeepsAKnownAvailableRelease() async throws {
        let defaults = try makeDefaults(named: #function)
        let client = MockGitHub(release: sampleRelease(tag: "v1.4.0"))
        let updater = AppUpdater(
            client: client,
            installer: MockInstaller(),
            defaults: defaults,
            currentVersion: "1.0.0"
        )

        updater.checkForUpdates(trigger: .manual)
        await waitForState(updater) { if case .available = $0 { return true }; return false }

        updater.checkWhenMenuAppears()

        XCTAssertEqual(client.callCount, 1)
        XCTAssertEqual(updater.availableRelease?.versionString, "1.4.0")
        XCTAssertEqual(updater.buttonTitle, "Install 1.4.0")
    }

    @MainActor
    func testMenuAppearanceWaitsSixHoursAfterAFailedCheck() async throws {
        let defaults = try makeDefaults(named: #function)
        let clock = TestClock(Date(timeIntervalSince1970: 1_786_402_800))
        let client = FailingGitHub()
        let updater = AppUpdater(
            client: client,
            installer: MockInstaller(),
            defaults: defaults,
            now: { clock.date },
            currentVersion: "1.0.0"
        )

        updater.checkWhenMenuAppears()
        await waitForState(updater) {
            $0 == .failed(UpdateError.network.localizedDescription)
        }

        clock.date = clock.date.addingTimeInterval(60 * 60)
        updater.checkWhenMenuAppears()
        XCTAssertEqual(client.callCount, 1)

        clock.date = clock.date.addingTimeInterval(UpdatePreferences.menuCheckInterval)
        updater.checkWhenMenuAppears()
        await waitForState(updater) { _ in client.callCount == 2 }
        XCTAssertEqual(client.callCount, 2)
    }

    @MainActor
    func testManualCheckBypassesTheDailyThrottle() async throws {
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

        updater.checkForUpdates(trigger: .manual)
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

    func testRelaunchWaitsForTheCurrentProcessThenVerifiesTheNewOne() {
        let appURL = URL(fileURLWithPath: "/Applications/Usage Bar.app")
        let logURL = URL(fileURLWithPath: "/tmp/UsageBarTests/updater.log")
        let arguments = AppRelaunchCommand.arguments(
            processIdentifier: 12_345,
            appURL: appURL,
            logURL: logURL
        )

        XCTAssertEqual(arguments[0], "-c")
        XCTAssertEqual(arguments[2], "UsageBar updater")
        XCTAssertEqual(arguments.suffix(4), ["12345", appURL.path, "UsageBar", logURL.path])
        let script = arguments[1]
        XCTAssertTrue(script.contains("/bin/kill -0 \"$pid\""))
        XCTAssertTrue(script.contains("/usr/bin/pgrep -x \"$name\""))
        XCTAssertFalse(script.contains("pgrep -f"))
        XCTAssertTrue(script.contains("for attempt in 1 2; do"))
        XCTAssertTrue(script.contains("/usr/bin/open \"$app\""))
        XCTAssertTrue(script.contains(">> \"$log\""))
    }

    func testRelaunchLogsUnderTheUserLibraryLogs() {
        XCTAssertTrue(AppRelaunchCommand.logURL.path.hasSuffix("/Library/Logs/UsageBar/updater.log"))
    }

    func testRelaunchScriptIsValidShell() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", AppRelaunchCommand.script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
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

    private func stubbedService(
        now: Date,
        status: Int?,
        headers: [String: String]
    ) -> GitHubReleaseService {
        let host = "\(UUID().uuidString.lowercased()).example"
        GitHubStubProtocol.register(host, status: status, headers: headers)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubStubProtocol.self]
        return GitHubReleaseService(
            session: URLSession(configuration: configuration),
            endpoint: URL(string: "https://\(host)/releases/latest")!,
            now: { now }
        )
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
        throw UpdateError.network
    }
}

private struct MockInstaller: AppUpdateInstalling {
    func checkCanInstall() throws {}
    func install(fromAppBundle url: URL) throws {}
    func relaunch() throws {}
}

private final class ReadOnlyInstaller: AppUpdateInstalling, @unchecked Sendable {
    private let counter = LockedCounter()

    var checkCount: Int { counter.value }

    func checkCanInstall() throws {
        counter.increment()
        throw UpdateError.destinationNotWritable
    }

    func install(fromAppBundle url: URL) throws {
        XCTFail("a read-only destination must not be installed into")
    }

    func relaunch() throws {
        XCTFail("a read-only destination must not relaunch")
    }
}

private final class RateLimitedGitHub: GitHubReleasing, @unchecked Sendable {
    let until: Date
    private let counter = LockedCounter()

    var callCount: Int { counter.value }

    init(until: Date) {
        self.until = until
    }

    func latestRelease() async throws -> GitHubRelease {
        counter.increment()
        throw UpdateError.rateLimited(until: until)
    }
}

private final class TestClock: @unchecked Sendable {
    var date: Date

    init(_ date: Date) {
        self.date = date
    }
}

private final class GitHubStubProtocol: URLProtocol {
    private static let store = GitHubStubStore()

    static func register(_ host: String, status: Int?, headers: [String: String]) {
        store.set(GitHubStub(status: status, headers: headers), for: host)
    }

    private static func stub(for host: String) -> GitHubStub? {
        store.stub(for: host)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let stub = Self.stub(for: url.host ?? ""),
              let status = stub.status,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: stub.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"message\":\"API rate limit exceeded\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct GitHubStub {
    let status: Int?
    let headers: [String: String]
}

private final class GitHubStubStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stubs: [String: GitHubStub] = [:]

    func set(_ stub: GitHubStub, for host: String) {
        lock.lock()
        stubs[host] = stub
        lock.unlock()
    }

    func stub(for host: String) -> GitHubStub? {
        lock.lock()
        defer { lock.unlock() }
        return stubs[host]
    }
}

private final class UpdateURLProtocol: URLProtocol {
    private static let responseStore = LockedResponses()
    static let requests = LockedCounter()

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
        Self.requests.increment()
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

    func reset() {
        lock.lock()
        storage = 0
        lock.unlock()
    }
}
