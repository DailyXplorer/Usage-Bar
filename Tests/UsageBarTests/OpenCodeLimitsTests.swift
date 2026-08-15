import XCTest
@testable import UsageBar

final class OpenCodeLimitsTests: XCTestCase {
    private let payload = """
    {
      "usage": {
        "rolling": {"status": "ok", "percent": 4, "resetsAt": "2026-08-13T16:27:38.287Z"},
        "weekly": {"status": "ok", "percent": 3, "resetsAt": "2026-08-17T00:00:00.287Z"},
        "monthly": {"status": "ok", "percent": 1, "resetsAt": "2026-09-13T06:06:01.287Z"}
      }
    }
    """

    private func decode() throws -> OpenCodeUsageResponse {
        try JSONDecoder().decode(OpenCodeUsageResponse.self, from: Data(payload.utf8))
    }

    func testBucketsMatchOpenCodeGoWindows() throws {
        let now = Date(timeIntervalSince1970: 1_786_632_000)
        let buckets = OpenCodeLimits.buckets(from: try decode(), now: now)

        XCTAssertEqual(buckets.map(\.kind), [.rolling, .weekly, .monthly])
        XCTAssertEqual(LimitBucket.Provider.opencode.title, "OpenCode")
        XCTAssertEqual(OpenCodeLimits.planName, "Go")
        XCTAssertEqual(buckets.map(\.displayName), [
            OpenCodeLimits.rollingDisplayName,
            OpenCodeLimits.weeklyDisplayName,
            OpenCodeLimits.monthlyDisplayName,
        ])
        XCTAssertEqual(OpenCodeLimits.rollingDisplayName, "Current session")
        XCTAssertEqual(buckets.map(\.usedPercent), [4, 3, 1])
        XCTAssertEqual(buckets.map(\.remainingPercent), [96, 97, 99])
        XCTAssertEqual(buckets.map(\.limitWindowSeconds), [
            OpenCodeLimits.rollingWindowSeconds,
            OpenCodeLimits.weeklyWindowSeconds,
            OpenCodeLimits.monthlyWindowSeconds,
        ])
        XCTAssertTrue(buckets.allSatisfy { $0.provider == .opencode })
        XCTAssertTrue(buckets.allSatisfy { $0.reached == false })
        XCTAssertTrue(buckets.allSatisfy { $0.detail == nil })
    }

    func testRelabeledRewritesCachedRollingTitle() {
        let cached = LimitBucket(
            provider: .opencode,
            kind: .rolling,
            name: "Rolling 5h",
            usedPercent: 4,
            resetAt: nil,
            resetAfterSeconds: nil,
            limitWindowSeconds: OpenCodeLimits.rollingWindowSeconds,
            reached: false
        )

        XCTAssertEqual(OpenCodeLimits.relabeled(cached).name, OpenCodeLimits.rollingDisplayName)
        XCTAssertEqual(
            OpenCodeLimits.relabeled(
                LimitBucket(
                    provider: .opencode,
                    kind: .weekly,
                    name: "Weekly",
                    usedPercent: 3,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: OpenCodeLimits.weeklyWindowSeconds,
                    reached: false
                )
            ).name,
            OpenCodeLimits.weeklyDisplayName
        )
    }

    func testRateLimitedWindowIsMarkedReached() throws {
        let limited = """
        {"usage":{"rolling":{"status":"rate-limited","percent":99.9,"resetsAt":"2026-08-13T16:27:38.287Z"},
         "weekly":{"status":"ok","percent":30,"resetsAt":"2026-08-17T00:00:00.287Z"},
         "monthly":{"status":"ok","percent":12,"resetsAt":"2026-09-13T06:06:01.287Z"}}}
        """
        let response = try JSONDecoder().decode(OpenCodeUsageResponse.self, from: Data(limited.utf8))
        let buckets = OpenCodeLimits.buckets(from: response)

        XCTAssertEqual(buckets.map(\.reached), [true, false, false])
        XCTAssertEqual(buckets[0].usedPercent, 100)
        XCTAssertEqual(buckets[0].remainingPercent, 0)
    }

    func testMissingWindowsAreSkipped() throws {
        let partial = """
        {"usage":{"rolling":{"status":"ok","percent":8,"resetsAt":"2026-08-13T16:27:38Z"},
         "weekly":null,"monthly":{"status":"ok","percent":2,"resetsAt":"2026-09-13T06:06:01Z"}}}
        """
        let response = try JSONDecoder().decode(OpenCodeUsageResponse.self, from: Data(partial.utf8))
        let buckets = OpenCodeLimits.buckets(from: response)

        XCTAssertEqual(buckets.map(\.kind), [.rolling, .monthly])
        XCTAssertEqual(buckets.map(\.remainingPercent), [92, 98])
    }

    func testPercentIsFlooredToMatchTheGoDashboard() throws {
        let fractional = """
        {"usage":{"rolling":{"status":"ok","percent":4.9,"resetsAt":"2026-08-13T16:27:38Z"},
         "weekly":{"status":"ok","percent":0,"resetsAt":"2026-08-17T00:00:00Z"},
         "monthly":{"status":"ok","percent":99.1,"resetsAt":"2026-09-13T06:06:01Z"}}}
        """
        let response = try JSONDecoder().decode(OpenCodeUsageResponse.self, from: Data(fractional.utf8))
        let buckets = OpenCodeLimits.buckets(from: response)

        XCTAssertEqual(buckets.map(\.usedPercent), [4, 0, 99])
    }

    func testResetCountdownUsesResetsAt() throws {
        let now = Date(timeIntervalSince1970: 1_786_632_000)
        let buckets = OpenCodeLimits.buckets(from: try decode(), now: now)

        XCTAssertEqual(buckets[0].resetAfterSeconds, 6_458)
        XCTAssertNotNil(buckets[0].resetAt)
    }

    func testAuthFileCandidatesPreferXDGThenLocalShare() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let files = OpenCodeUsageService.authFileCandidates(
            home: home,
            environment: ["XDG_DATA_HOME": "/Users/tester/custom-data"]
        )

        XCTAssertEqual(files.map(\.path), [
            "/Users/tester/custom-data/opencode/auth.json",
            "/Users/tester/.local/share/opencode/auth.json",
            "/Users/tester/Library/Application Support/opencode/auth.json",
        ])
    }

    func testLoadCredentialsReadsOpencodeGoApiKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("auth.json")
        try Data(#"{ "xai": { "type": "oauth" }, "opencode-go": { "type": "api", "key": "sk-test" } }"#.utf8)
            .write(to: file)

        let credentials = try OpenCodeUsageService.loadCredentials(from: [file])
        XCTAssertEqual(credentials.apiKey, "sk-test")
    }

    func testLoadCredentialsSkipsFilesWithoutAGoKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let empty = directory.appendingPathComponent("empty.json")
        try Data(#"{ "xai": { "type": "oauth" } }"#.utf8).write(to: empty)
        let missing = directory.appendingPathComponent("missing.json")

        XCTAssertThrowsError(try OpenCodeUsageService.loadCredentials(from: [missing, empty])) { error in
            guard case OpenCodeUsageError.notSignedIn = error else {
                return XCTFail("expected notSignedIn, got \(error)")
            }
        }
    }

    @MainActor
    func testMenuBarUsesRollingWindow() throws {
        let model = UsageModel(
            previewBuckets: [
                LimitBucket(
                    kind: .primary,
                    name: "weekly",
                    usedPercent: 1,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: 604_800,
                    reached: false
                )
            ],
            planType: "prolite",
            lastUpdated: Date(),
            opencodeBuckets: OpenCodeLimits.buckets(from: try decode()),
            menuBarProviders: [.codex, .opencode]
        )

        XCTAssertEqual(model.menuBarText, "99%")
        XCTAssertEqual(model.menuBarOpenCodeText, "96%")
        XCTAssertEqual(model.opencodeRolling?.kind, .rolling)
        XCTAssertEqual(model.menuBarSegments.map(\.value), ["99%", "96%"])
    }

    @MainActor
    func testMissingKeyOmitsOpenCodeFromTheMenu() {
        let model = UsageModel(
            previewBuckets: [
                LimitBucket(
                    kind: .primary,
                    name: "weekly",
                    usedPercent: 1,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: 604_800,
                    reached: false
                )
            ],
            planType: "pro",
            lastUpdated: Date(),
            menuBarProviders: [.codex, .opencode],
            errorMessage: "ChatGPT is unreachable.",
            opencodeAvailable: false
        )

        XCTAssertFalse(model.showsOpenCode)
        XCTAssertNil(model.sectionMessage(for: .opencode))
        XCTAssertEqual(model.menuBarSegments.map(\.value), ["99%"])
        XCTAssertFalse(model.menuBarAccessibilityLabel.contains("OpenCode"))
    }

    @MainActor
    func testMenuBarDoesNotUseWeeklyOrMonthlyAsRolling() throws {
        let partial = """
        {"usage":{"weekly":{"status":"ok","percent":30,"resetsAt":"2026-08-17T00:00:00Z"},
         "monthly":{"status":"ok","percent":12,"resetsAt":"2026-09-13T06:06:01Z"}}}
        """
        let response = try JSONDecoder().decode(OpenCodeUsageResponse.self, from: Data(partial.utf8))
        let model = UsageModel(
            previewBuckets: [
                LimitBucket(
                    kind: .primary,
                    name: "weekly",
                    usedPercent: 1,
                    resetAt: nil,
                    resetAfterSeconds: nil,
                    limitWindowSeconds: 604_800,
                    reached: false
                )
            ],
            planType: "prolite",
            lastUpdated: Date(),
            opencodeBuckets: OpenCodeLimits.buckets(from: response),
            menuBarProviders: [.codex, .opencode]
        )

        XCTAssertNil(model.opencodeRolling)
        XCTAssertNil(model.menuBarOpenCodeText)
        XCTAssertEqual(model.menuBarOpenCodeDisplay, "–")
        XCTAssertEqual(model.menuBarSegments.map(\.value), ["99%", "–"])
        XCTAssertTrue(model.showsOpenCode)
    }

    @MainActor
    func testSignedInOpenCodeWithoutWindowsDoesNotLookSignedOut() {
        let model = UsageModel(
            previewBuckets: [],
            planType: "pro",
            lastUpdated: Date(),
            menuBarProviders: [.opencode],
            opencodeAvailable: true
        )

        XCTAssertEqual(model.sectionMessage(for: .opencode), "OpenCode returned no limits.")
    }
}
