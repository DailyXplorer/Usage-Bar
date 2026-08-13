import Foundation

enum AppDistribution {
    static let githubOwner = "DailyXplorer"
    static let githubRepo = "Usage-Bar"
    static let assetName = "UsageBar.app.zip"
    static let bundleIdentifier = "com.usagebar.app"
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
    let original: String

    init(_ string: String) {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "v" || trimmed.first == "V" {
            trimmed.removeFirst()
        }
        original = trimmed
        parts = trimmed.split(separator: ".").map { Int($0) ?? 0 }
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
        return false
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
            ?? assets.first { $0.name.hasSuffix(".app.zip") }
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
    case extractFailed
    case invalidAppBundle

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
        case .extractFailed:
            return "Could not unpack the downloaded app."
        case .invalidAppBundle:
            return "The download was not a Usage Bar app."
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
