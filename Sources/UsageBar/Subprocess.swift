import Foundation

enum Subprocess {
    struct Output: Equatable, Sendable {
        let status: Int32
        let stdout: Data
        let timedOut: Bool
    }

    static let killGrace: TimeInterval = 1

    private static let queue = DispatchQueue(
        label: "com.usagebar.subprocess",
        qos: .utility,
        attributes: .concurrent
    )

    static func run(
        _ executable: URL,
        arguments: [String] = [],
        input: Data? = nil,
        timeout: TimeInterval
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try runBlocking(executable, arguments: arguments, input: input, timeout: timeout)
                })
            }
        }
    }

    private static func runBlocking(
        _ executable: URL,
        arguments: [String],
        input: Data?,
        timeout: TimeInterval
    ) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let inputPipe = input == nil ? nil : Pipe()
        process.standardInput = inputPipe ?? FileHandle.nullDevice

        let collected = OutputBuffer()
        let reader = output.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                collected.finish()
            } else {
                collected.append(chunk)
            }
        }

        do {
            try process.run()
        } catch {
            reader.readabilityHandler = nil
            throw error
        }

        let expired = TimeoutFlag()
        let deadline = DispatchWorkItem {
            guard process.isRunning else { return }
            expired.set()
            process.terminate()
            queue.asyncAfter(deadline: .now() + killGrace) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)

        if let input, let inputPipe {
            let handle = inputPipe.fileHandleForWriting
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            queue.async {
                try? handle.write(contentsOf: input)
                try? handle.close()
            }
        }

        process.waitUntilExit()
        deadline.cancel()
        let stdout = collected.data(waitingAtMost: killGrace)
        reader.readabilityHandler = nil
        try? reader.close()
        return Output(status: process.terminationStatus, stdout: stdout, timedOut: expired.value)
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var buffer = Data()

    func append(_ chunk: Data) {
        lock.withLock { buffer.append(chunk) }
    }

    func finish() {
        finished.signal()
    }

    func data(waitingAtMost grace: TimeInterval) -> Data {
        _ = finished.wait(timeout: .now() + grace)
        return lock.withLock { buffer }
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    var value: Bool {
        lock.withLock { isSet }
    }

    func set() {
        lock.withLock { isSet = true }
    }
}
