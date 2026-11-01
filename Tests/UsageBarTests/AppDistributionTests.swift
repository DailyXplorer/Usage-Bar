import XCTest
@testable import UsageBar

final class AppDistributionTests: XCTestCase {
    func testRepositoryURLPointsAtTheGitHubProject() {
        XCTAssertEqual(
            AppDistribution.repositoryURL.absoluteString,
            "https://github.com/\(AppDistribution.githubOwner)/\(AppDistribution.githubRepo)"
        )
        XCTAssertEqual(
            AppDistribution.repositoryURL.absoluteString,
            "https://github.com/DailyXplorer/Usage-Bar"
        )
    }

    func testReplacementRemovesBackupsLeftByEarlierInstalls() throws {
        let root = temporaryRoot()
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let destination = applications.appendingPathComponent("UsageBar.app")
        let source = root.appendingPathComponent("Source/UsageBar.app")
        let leftover = applications.appendingPathComponent(".UsageBar.app.\(UUID().uuidString).previous")
        let unrelated = applications.appendingPathComponent(".Other.app.previous")
        try makeBundle(at: source, marker: "new")
        try makeBundle(at: destination, marker: "old")
        try makeBundle(at: leftover, marker: "older")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        try AppBundleReplacement.install(from: source, to: destination)

        let names = try FileManager.default.contentsOfDirectory(atPath: applications.path).sorted()
        XCTAssertEqual(names, [".Other.app.previous", "UsageBar.app"])
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Contents/marker")),
            "new"
        )
    }

    func testReplacementCheckAcceptsAWritableDestinationWithoutLeavingAProbe() throws {
        let root = temporaryRoot()
        let destination = root.appendingPathComponent("Applications/UsageBar.app")
        try makeBundle(at: destination, marker: "old")

        XCTAssertNoThrow(try AppBundleReplacement.checkCanReplace(destination))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path),
            ["UsageBar.app"]
        )
    }

    func testReplacementCheckRejectsAReadOnlyApplicationsFolder() throws {
        let root = temporaryRoot()
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let destination = applications.appendingPathComponent("UsageBar.app")
        try makeBundle(at: destination, marker: "old")
        try makeReadOnly(applications)

        XCTAssertThrowsError(try AppBundleReplacement.checkCanReplace(destination)) { error in
            XCTAssertEqual(error as? UpdateError, .destinationNotWritable)
        }
    }

    func testReplacementCheckRejectsAnAppBundleTheUserCannotWrite() throws {
        let root = temporaryRoot()
        let destination = root.appendingPathComponent("Applications/UsageBar.app")
        try makeBundle(at: destination, marker: "old")
        try makeReadOnly(destination.appendingPathComponent("Contents"))

        XCTAssertThrowsError(try AppBundleReplacement.checkCanReplace(destination)) { error in
            XCTAssertEqual(error as? UpdateError, .destinationNotWritable)
        }
    }

    func testBundleVersionReadsTheShortVersionString() throws {
        let root = temporaryRoot()
        let app = root.appendingPathComponent("UsageBar.app")
        try makeBundle(at: app, marker: "x", version: "1.4.2")

        XCTAssertEqual(AppBundleReplacement.bundleVersion(at: app), AppVersion("1.4.2"))
        XCTAssertNil(AppBundleReplacement.bundleVersion(at: root.appendingPathComponent("Missing.app")))
    }

    private func makeBundle(at url: URL, marker: String, version: String? = nil) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: contents.appendingPathComponent("marker"))
        guard let version else { return }
        let info: [String: Any] = ["CFBundleShortVersionString": version]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func makeReadOnly(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private func temporaryRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
