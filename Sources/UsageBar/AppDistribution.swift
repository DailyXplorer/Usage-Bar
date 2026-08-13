import Foundation

enum AppDistribution {
    static let githubOwner = "DailyXplorer"
    static let githubRepo = "Usage-Bar"
    static let assetName = "UsageBar.app.zip"
    static let checksumAssetName = "\(assetName).sha256"
    static let bundleIdentifier = "com.usagebar.app"
    static let executableName = "UsageBar"
    static let installURL = URL(fileURLWithPath: "/Applications/UsageBar.app")

    static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest")!
    }

    static var latestZipURL: URL {
        URL(string: "https://github.com/\(githubOwner)/\(githubRepo)/releases/latest/download/\(assetName)")!
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
        original = trimmed
        let withoutBuildMetadata = trimmed.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )[0]
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

struct GitHubRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
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

    var displayNotes: String? {
        guard let body else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum UpdateError: LocalizedError, Equatable {
    case network(String)
    case httpStatus(Int)
    case noReleases
    case missingAsset
    case missingChecksum
    case invalidChecksum
    case checksumMismatch
    case extractFailed
    case invalidAppBundle
    case invalidCodeSignature

    var errorDescription: String? {
        switch self {
        case .network(let message):
            return "Network error: \(message)"
        case .httpStatus(let code):
            return "GitHub returned HTTP \(code)."
        case .noReleases:
            return "No GitHub release is published yet."
        case .missingAsset:
            return "This GitHub release has no \(AppDistribution.assetName) yet."
        case .missingChecksum:
            return "This GitHub release has no \(AppDistribution.checksumAssetName) yet."
        case .invalidChecksum:
            return "The update checksum is invalid."
        case .checksumMismatch:
            return "The downloaded update did not match its checksum."
        case .extractFailed:
            return "Could not unpack the downloaded app."
        case .invalidAppBundle:
            return "The download was not a Usage Bar app."
        case .invalidCodeSignature:
            return "The downloaded app has an invalid code signature."
        }
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
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }
}

enum UpdatePreferences {
    static let checksKey = "automaticallyCheckForUpdates"
    static let installsKey = "automaticallyInstallUpdates"
    static let lastCheckKey = "lastUpdateCheckAt"
    static let checkInterval: TimeInterval = 24 * 60 * 60
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(GitHubRelease)
    case downloading
    case installing
    case failed(String)
}
