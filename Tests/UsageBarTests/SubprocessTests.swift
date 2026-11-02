import XCTest
@testable import UsageBar

final class SubprocessTests: XCTestCase {
    func testCapturesStdoutFromStdin() async throws {
        let output = try await Subprocess.run(
            URL(fileURLWithPath: "/bin/cat"),
            input: Data("synthetic input".utf8),
            timeout: 5
        )

        XCTAssertEqual(output, Subprocess.Output(status: 0, stdout: Data("synthetic input".utf8), timedOut: false))
    }

    func testReportsTheExitStatus() async throws {
        let output = try await Subprocess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 44"], timeout: 5)

        XCTAssertEqual(output.status, 44)
        XCTAssertFalse(output.timedOut)
    }

    func testTimeoutTerminatesTheProcess() async throws {
        let started = Date()
        let output = try await Subprocess.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.2)

        XCTAssertTrue(output.timedOut)
        XCTAssertNotEqual(output.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testTimeoutKillsAProcessThatIgnoresTermination() async throws {
        let started = Date()
        let output = try await Subprocess.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; sleep 30 & wait"],
            timeout: 0.2
        )

        XCTAssertTrue(output.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testMissingExecutableThrows() async {
        do {
            _ = try await Subprocess.run(URL(fileURLWithPath: "/nonexistent/tool"), timeout: 1)
            XCTFail("Expected a launch error")
        } catch {}
    }

    func testWaitingProcessesDoNotHoldTheCooperativePool() async throws {
        let count = ProcessInfo.processInfo.activeProcessorCount * 3
        let started = Date()

        try await withThrowingTaskGroup(of: Subprocess.Output.self) { group in
            for _ in 0..<count {
                group.addTask {
                    try await Subprocess.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"], timeout: 10)
                }
            }
            for try await output in group {
                XCTAssertEqual(output.status, 0)
            }
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }
}
