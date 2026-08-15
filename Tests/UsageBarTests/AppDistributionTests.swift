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
}
