import Foundation

enum AppDistribution {
    static let githubOwner = "DailyXplorer"
    static let githubRepo = "Usage-Bar"
    static let assetName = "UsageBar.app.zip"
    static let checksumAssetName = "\(assetName).sha256"
    static let bundleIdentifier = "com.usagebar.app"
    static let executableName = "UsageBar"
    static let installURL = URL(fileURLWithPath: "/Applications/UsageBar.app")

    static var repositoryURL: URL {
        URL(string: "https://github.com/\(githubOwner)/\(githubRepo)")!
    }

    static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest")!
    }

    static func trustedAssetURL(named name: String, releaseTag: String) -> URL? {
        let tagPattern = #"^v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#
        guard releaseTag.range(of: tagPattern, options: .regularExpression) != nil,
              name == assetName || name == checksumAssetName else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(githubOwner)/\(githubRepo)/releases/download/\(releaseTag)/\(name)"
        return components.url
    }

    static func isTrustedAsset(name: String, url: URL, releaseTag: String) -> Bool {
        url == trustedAssetURL(named: name, releaseTag: releaseTag)
    }
}

struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    let parts: [Int]
    let prerelease: [String]?
    let original: String

    init(_ string: String) {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "v" || trimmed.first == "V" {
            trimmed.removeFirst()
        }
        let withoutBuildMetadata = trimmed.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )[0]
        original = String(withoutBuildMetadata)
        let components = withoutBuildMetadata.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        parts = components[0]
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        if components.count == 2, !components[1].isEmpty {
            prerelease = components[1]
                .split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)
        } else {
            prerelease = nil
        }
    }

    var description: String { original.isEmpty ? "0" : original }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right {
                return left < right
            }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (.some(let left), .some(let right)):
            return prereleaseIsLower(left, than: right)
        }
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    private static func prereleaseIsLower(_ lhs: [String], than rhs: [String]) -> Bool {
        for index in 0..<min(lhs.count, rhs.count) {
            let left = lhs[index]
            let right = rhs[index]
            if left == right { continue }

            switch (Int(left), Int(right)) {
            case (.some(let leftNumber), .some(let rightNumber)):
                return leftNumber < rightNumber
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                return left < right
            }
        }
        return lhs.count < rhs.count
    }
}

struct GitHubRelease: Decodable, Equatable, Sendable {
    struct Asset: Decodable, Equatable, Sendable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case assets
    }

    var versionString: String {
        AppVersion(tagName).original
    }

    var zipAsset: Asset? {
        assets.first { $0.name == AppDistribution.assetName }
    }

    var checksumAsset: Asset? {
        assets.first { $0.name == AppDistribution.checksumAssetName }
    }

    var assetsAreTrusted: Bool {
        guard let zipAsset, let checksumAsset else { return false }
        return AppDistribution.isTrustedAsset(
            name: zipAsset.name,
            url: zipAsset.browserDownloadURL,
            releaseTag: tagName
        ) && AppDistribution.isTrustedAsset(
            name: checksumAsset.name,
            url: checksumAsset.browserDownloadURL,
            releaseTag: tagName
        )
    }

    var displayNotes: String? {
        guard let body else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum UpdateError: LocalizedError, Equatable {
    case network
    case unexpectedResponse
    case rateLimited(until: Date)
    case noReleases
    case missingAsset
    case missingChecksum
    case untrustedAsset
    case downloadFailed
    case invalidChecksum
    case checksumMismatch
    case extractFailed
    case invalidAppBundle
    case invalidCodeSignature
    case quarantineRemovalFailed
    case destinationNotWritable
    case installFailed

    var errorDescription: String? {
        switch self {
        case .network:
            return "Usage Bar could not reach GitHub. Check your internet connection and try again."
        case .unexpectedResponse:
            return "GitHub sent an unexpected reply. Try again later."
        case .rateLimited:
            return "GitHub is limiting update checks. Try again later."
        case .noReleases:
            return "No Usage Bar release is published yet."
        case .missingAsset, .missingChecksum:
            return "The latest release is not ready to install yet. Try again later."
        case .untrustedAsset:
            return "This update did not come from the official Usage Bar release, so it was not installed."
        case .downloadFailed:
            return "The update could not be downloaded. Check your internet connection and try again."
        case .invalidChecksum:
            return "The update could not be verified. Try again later."
        case .checksumMismatch:
            return "The downloaded update was damaged. Try again."
        case .extractFailed:
            return "The downloaded update could not be opened. Try again."
        case .invalidAppBundle:
            return "The download was not a Usage Bar app, so it was not installed."
        case .invalidCodeSignature:
            return "The downloaded app failed its signature check, so it was not installed."
        case .quarantineRemovalFailed:
            return "The downloaded app could not be prepared for launch. Try again."
        case .destinationNotWritable:
            return "Usage Bar does not have permission to replace itself in Applications. Install the update with the Usage Bar installer."
        case .installFailed:
            return "The update could not be installed. Try again."
        }
    }

    static func rateLimitMessage(until: Date, now: Date) -> String {
        let minutes = max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
        let unit = minutes == 1 ? "minute" : "minutes"
        return "GitHub is limiting update checks. Try again in \(minutes) \(unit)."
    }

    static func plain(_ error: Error, fallback: UpdateError) -> UpdateError {
        if let error = error as? UpdateError {
            return error
        }
        return fallback
    }
}

enum AppBundleReplacement {
    static func install(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let staging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).staging"
        )
        defer {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
        }

        try fileManager.copyItem(at: source, to: staging)
        if fileManager.fileExists(atPath: destination.path) {
            let backupName = ".\(destination.lastPathComponent).\(UUID().uuidString).previous"
            let backup = parent.appendingPathComponent(backupName)
            do {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: staging,
                    backupItemName: backupName,
                    options: [.usingNewMetadataOnly, .withoutDeletingBackupItem]
                )
            } catch {
                if !fileManager.fileExists(atPath: destination.path),
                   fileManager.fileExists(atPath: backup.path) {
                    try? fileManager.moveItem(at: backup, to: destination)
                }
                throw error
            }
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        removeLeftovers(of: destination, fileManager: fileManager)
    }

    static func checkCanReplace(_ destination: URL, fileManager: FileManager = .default) throws {
        let parent = destination.deletingLastPathComponent()
        let probe = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).probe"
        )
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data().write(to: probe, options: .withoutOverwriting)
            try fileManager.removeItem(at: probe)
        } catch {
            throw UpdateError.destinationNotWritable
        }
        guard fileManager.fileExists(atPath: destination.path) else { return }
        let contents = destination.appendingPathComponent("Contents", isDirectory: true)
        guard fileManager.isWritableFile(atPath: destination.path),
              !fileManager.fileExists(atPath: contents.path)
                || fileManager.isWritableFile(atPath: contents.path) else {
            throw UpdateError.destinationNotWritable
        }
    }

    static func clearQuarantine(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.quarantineRemovalFailed
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.quarantineRemovalFailed
        }
    }

    static func bundleVersion(at url: URL) -> AppVersion? {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = plist as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return AppVersion(version)
    }

    private static func removeLeftovers(of destination: URL, fileManager: FileManager) {
        let parent = destination.deletingLastPathComponent()
        let prefix = ".\(destination.lastPathComponent)."
        guard let names = try? fileManager.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix(prefix)
            && (name.hasSuffix(".previous") || name.hasSuffix(".staging") || name.hasSuffix(".probe")) {
            try? fileManager.removeItem(at: parent.appendingPathComponent(name))
        }
    }
}

enum UpdatePreferences {
    static let checksKey = "automaticallyCheckForUpdates"
    static let installsKey = "automaticallyInstallUpdates"
    static let lastCheckKey = "lastUpdateCheckAt"
    static let lastAttemptKey = "lastUpdateCheckAttemptAt"
    static let rateLimitedUntilKey = "updateCheckRateLimitedUntil"
    static let failedInstallVersionKey = "failedUpdateInstallVersion"
    static let failedInstallAtKey = "failedUpdateInstallAt"
    static let failedInstallCountKey = "failedUpdateInstallCount"
    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let retryInterval: TimeInterval = 15 * 60
    static let menuCheckInterval: TimeInterval = 6 * 60 * 60
    static let maximumRateLimitWait: TimeInterval = 60 * 60
    static let installBackoffBase: TimeInterval = 24 * 60 * 60
    static let maximumInstallBackoff: TimeInterval = 7 * 24 * 60 * 60

    static func installBackoff(afterFailures count: Int) -> TimeInterval {
        let doublings = max(0, min(count - 1, 8))
        return min(installBackoffBase * pow(2, Double(doublings)), maximumInstallBackoff)
    }
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(GitHubRelease)
    case downloading
    case installing
    case failed(String)

    var showsUpdateAction: Bool {
        switch self {
        case .available, .downloading, .installing, .failed:
            return true
        case .idle, .checking, .upToDate:
            return false
        }
    }
}
