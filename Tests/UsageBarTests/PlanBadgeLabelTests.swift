import XCTest
@testable import UsageBar

final class PlanBadgeLabelTests: XCTestCase {
    func testCodexMapsProliteToPro5x() {
        XCTAssertEqual(PlanBadgeLabel.text(for: "prolite", provider: .codex), "Pro 5x")
        XCTAssertEqual(PlanBadgeLabel.text(for: "pro_lite", provider: .codex), "Pro 5x")
        XCTAssertEqual(PlanBadgeLabel.text(for: "pro-lite", provider: .codex), "Pro 5x")
    }

    func testCodexMapsProToPro20x() {
        XCTAssertEqual(PlanBadgeLabel.text(for: "pro", provider: .codex), "Pro 20x")
        XCTAssertEqual(PlanBadgeLabel.text(for: "Pro", provider: .codex), "Pro 20x")
    }

    func testCursorKeepsProAndProPlus() {
        XCTAssertEqual(PlanBadgeLabel.text(for: "pro", provider: .cursor), "Pro")
        XCTAssertEqual(PlanBadgeLabel.text(for: "pro+", provider: .cursor), "Pro+")
        XCTAssertEqual(PlanBadgeLabel.text(for: "pro_plus", provider: .cursor), "Pro+")
        XCTAssertEqual(PlanBadgeLabel.text(for: "proplus", provider: .cursor), "Pro+")
    }

    func testClaudeMapsMaxMultipliers() {
        XCTAssertEqual(PlanBadgeLabel.text(for: "max_5x", provider: .claude), "Max 5x")
        XCTAssertEqual(PlanBadgeLabel.text(for: "max-20x", provider: .claude), "Max 20x")
        XCTAssertEqual(PlanBadgeLabel.text(for: "max", provider: .claude), "Max")
        XCTAssertEqual(PlanBadgeLabel.text(for: "pro", provider: .claude), "Pro")
    }

    func testSharedLabelsStayUnchanged() {
        XCTAssertEqual(PlanBadgeLabel.text(for: "plus", provider: .codex), "Plus")
        XCTAssertEqual(PlanBadgeLabel.text(for: "team", provider: .codex), "Team")
        XCTAssertEqual(PlanBadgeLabel.text(for: "ultra", provider: .cursor), "Ultra")
        XCTAssertEqual(PlanBadgeLabel.text(for: "enterprise", provider: .opencode), "Enterprise")
    }
}
