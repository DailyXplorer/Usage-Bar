import SQLite3
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
        XCTAssertEqual(OpenCodeLimits.plan(for: buckets), OpenCodeLimits.planName)
        XCTAssertNil(OpenCodeLimits.plan(for: []))
        XCTAssertEqual(buckets.map(\.displayName), [
            OpenCodeLimits.rollingDisplayName,
            OpenCodeLimits.weeklyDisplayName,
            OpenCodeLimits.monthlyDisplayName,
        ])
        XCTAssertEqual(OpenCodeLimits.rollingDisplayName, "Current Session")
        XCTAssertEqual(OpenCodeLimits.weeklyDisplayName, "Weekly Limit")
        XCTAssertEqual(OpenCodeLimits.monthlyDisplayName, "Monthly Limit")
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
        XCTAssertEqual(model.menuBarOpenCodeDisplay, MenuBarSegment.placeholder)
        XCTAssertEqual(model.menuBarSegments.map(\.value), ["99%", MenuBarSegment.placeholder])
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
    func testDatabaseCandidatesHonourOverrideThenDataDirectories() {
        let home = URL(fileURLWithPath: "/tmp/opencode-home", isDirectory: true)
        let files = OpenCodeUsageService.databaseCandidates(
            home: home,
            environment: ["OPENCODE_DB": "/tmp/custom/opencode.db", "XDG_DATA_HOME": "/tmp/xdg"]
        )

        XCTAssertEqual(files.map(\.path), [
            "/tmp/custom/opencode.db",
            "/tmp/xdg/opencode/opencode.db",
            "/tmp/opencode-home/.local/share/opencode/opencode.db",
            "/tmp/opencode-home/Library/Application Support/opencode/opencode.db",
        ])
        XCTAssertFalse(
            OpenCodeUsageService.databaseCandidates(home: home, environment: ["OPENCODE_DB": ":memory:"])
                .contains { $0.path.hasSuffix(":memory:") }
        )
    }

    func testDatabaseKeyWinsOverLegacyAuthFile() async throws {
        let directory = try temporaryDirectory()
        let database = directory.appendingPathComponent("opencode.db")
        try createCredentialTable(at: database, rows: [
            ("c1", "opencode-go", #"{"type":"key","key":"sk-old"}"#, 0, 100),
            ("c2", "opencode-go", #"{"type":"key","key":"sk-new"}"#, 0, 200),
            ("c3", "cursor", #"{"type":"oauth","access":"other"}"#, 1, 300),
        ])
        let auth = directory.appendingPathComponent("auth.json")
        try Data(#"{"opencode-go":{"type":"api","key":"sk-legacy"}}"#.utf8).write(to: auth)

        let credentials = try await OpenCodeUsageService.loadCredentials(databases: [database], authFiles: [auth])

        XCTAssertEqual(credentials.apiKey, "sk-new")
    }

    func testActiveDatabaseCredentialIsPreferred() async throws {
        let directory = try temporaryDirectory()
        let database = directory.appendingPathComponent("opencode.db")
        try createCredentialTable(at: database, rows: [
            ("c1", "opencode-go", #"{"type":"key","key":"sk-active"}"#, 1, 100),
            ("c2", "opencode-go", #"{"type":"key","key":"sk-newer"}"#, 0, 200),
        ])

        let credentials = try await OpenCodeUsageService.loadCredentials(databases: [database], authFiles: [])

        XCTAssertEqual(credentials.apiKey, "sk-active")
    }

    func testAuthFileIsTheFallbackWhenTheDatabaseHasNoGoKey() async throws {
        let directory = try temporaryDirectory()
        let database = directory.appendingPathComponent("opencode.db")
        try createCredentialTable(at: database, rows: [
            ("c1", "opencode-go", #"{"type":"oauth","access":"not-a-key"}"#, 1, 100),
        ])
        let auth = directory.appendingPathComponent("auth.json")
        try Data(#"{"opencode-go":{"type":"api","key":"sk-legacy"}}"#.utf8).write(to: auth)
        let missing = directory.appendingPathComponent("missing.db")

        let credentials = try await OpenCodeUsageService.loadCredentials(databases: [missing, database], authFiles: [auth])

        XCTAssertEqual(credentials.apiKey, "sk-legacy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testDatabaseReadLeavesTheFileUnchanged() async throws {
        let directory = try temporaryDirectory()
        let database = directory.appendingPathComponent("opencode.db")
        try createCredentialTable(at: database, rows: [
            ("c1", "opencode-go", #"{"type":"key","key":"sk-test"}"#, 1, 100),
        ])
        let before = try Data(contentsOf: database)

        _ = try await OpenCodeUsageService.loadCredentials(databases: [database], authFiles: [])

        XCTAssertEqual(try Data(contentsOf: database), before)
    }

    func testMissingOrMalformedWindowsDoNotFailTheResponse() throws {
        let json = """
        {"usage":{"rolling":{"status":"ok","percent":"12.5","resetsAt":1793570400000},"weekly":"broken","monthly":{"status":"new-status","percent":30}}}
        """
        let response = try JSONDecoder().decode(OpenCodeUsageResponse.self, from: Data(json.utf8))
        let buckets = OpenCodeLimits.buckets(from: response, now: Date(timeIntervalSince1970: 1_793_560_000))

        XCTAssertEqual(buckets.map(\.kind), [.rolling, .monthly])
        XCTAssertEqual(buckets[0].usedPercent, 12)
        XCTAssertEqual(buckets[0].resetAt, Date(timeIntervalSince1970: 1_793_570_400))
        XCTAssertFalse(buckets[1].reached)

        let empty = try JSONDecoder().decode(OpenCodeUsageResponse.self, from: Data("{}".utf8))
        XCTAssertTrue(OpenCodeLimits.buckets(from: empty).isEmpty)
    }

    func testErrorTextHasNoStatusCodesOrExceptionText() {
        let errors: [OpenCodeUsageError] = [
            .notSignedIn, .invalidKey, .notSubscribed, .throttled(retryAfter: nil),
            .network("The request timed out."), .httpStatus(502), .decoding("keyNotFound"),
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.contains("502"), text)
            XCTAssertFalse(text.contains("HTTP"), text)
            XCTAssertFalse(text.contains("timed out"), text)
            XCTAssertFalse(text.contains("keyNotFound"), text)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func createCredentialTable(
        at file: URL,
        rows: [(String, String, String, Int, Int)]
    ) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statements = [
            "CREATE TABLE credential (id TEXT PRIMARY KEY, integration_id TEXT, label TEXT NOT NULL, value TEXT NOT NULL, connector_id TEXT, method_id TEXT, active INTEGER, time_created INTEGER, time_updated INTEGER)",
        ]
        for row in rows {
            statements.append(
                "INSERT INTO credential (id, integration_id, label, value, active, time_created, time_updated) VALUES ('\(row.0)', '\(row.1)', 'label', '\(row.2)', \(row.3), \(row.4), \(row.4))"
            )
        }
        for sql in statements {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
    }
}
