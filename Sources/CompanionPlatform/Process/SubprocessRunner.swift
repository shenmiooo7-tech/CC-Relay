import Darwin
import Foundation

public struct SubprocessResult: Equatable, Sendable {
    public let exitStatus: Int32
    public let stdout: Data
    public let stderr: Data
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public let timedOut: Bool

    public init(
        exitStatus: Int32, stdout: Data = Data(), stderr: Data = Data(),
        stdoutTruncated: Bool = false, stderrTruncated: Bool = false, timedOut: Bool = false
    ) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.timedOut = timedOut
    }
}

public protocol SubprocessRunning: Sendable {
    func run(
        executable: URL, arguments: [String], timeout: TimeInterval, outputLimit: Int
    ) async throws -> SubprocessResult
}

public enum SubprocessError: Error, Equatable, Sendable {
    case invalidConfiguration
    case pipeIO(Int32)
}

/// Executes directly, without a shell. The output limit applies separately to each stream.
public struct SubprocessRunner: SubprocessRunning {
    public let terminationGracePeriod: TimeInterval

    public init(terminationGracePeriod: TimeInterval = 0.25) {
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func run(
        executable: URL, arguments: [String] = [], timeout: TimeInterval = 20,
        outputLimit: Int = 1_048_576
    ) async throws -> SubprocessResult {
        guard executable.isFileURL, executable.path.hasPrefix("/"),
              timeout.isFinite, timeout > 0, outputLimit >= 0,
              terminationGracePeriod.isFinite, terminationGracePeriod >= 0
        else { throw SubprocessError.invalidConfiguration }
        let cancellation = SubprocessCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Pipe draining and waiting run on a dispatch worker, never a cooperative executor.
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let result = try execute(
                            executable: executable, arguments: arguments, timeout: timeout,
                            outputLimit: outputLimit, cancellation: cancellation
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func execute(
        executable: URL, arguments: [String], timeout: TimeInterval, outputLimit: Int,
        cancellation: SubprocessCancellation
    ) throws -> SubprocessResult {
        if cancellation.isCancelled { throw CancellationError() }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let outputFD = output.fileHandleForReading.fileDescriptor
        let errorFD = errors.fileHandleForReading.fileDescriptor
        defer {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
        }
        try makeNonblocking(outputFD)
        try makeNonblocking(errorFD)
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer {
            // Only the Process created above is ever signalled, including on read failures.
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var killDeadline: ContinuousClock.Instant?
        var sentKill = false
        var timedOut = false
        var stdout = CapturedOutput(limit: outputLimit)
        var stderr = CapturedOutput(limit: outputLimit)

        while true {
            let outputIdle = try stdout.drain(outputFD)
            let errorIdle = try stderr.drain(errorFD)
            let running = process.isRunning
            if !running && outputIdle && errorIdle { break }
            let now = clock.now
            if running, killDeadline == nil, now >= deadline || cancellation.isCancelled {
                timedOut = now >= deadline
                process.terminate()
                killDeadline = now.advanced(by: .seconds(terminationGracePeriod))
            }
            if running, !sentKill, let killDeadline, now >= killDeadline {
                Darwin.kill(process.processIdentifier, SIGKILL)
                sentKill = true
            }
            // A bounded poll also checks deadlines when a child produces no output.
            var descriptors = [
                pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: errorFD, events: Int16(POLLIN), revents: 0),
            ]
            _ = poll(&descriptors, nfds_t(descriptors.count), 10)
        }
        process.waitUntilExit()
        if cancellation.isCancelled { throw CancellationError() }
        return SubprocessResult(
            exitStatus: process.terminationStatus, stdout: stdout.data, stderr: stderr.data,
            stdoutTruncated: stdout.truncated, stderrTruncated: stderr.truncated, timedOut: timedOut
        )
    }

    private func makeNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw SubprocessError.pipeIO(errno)
        }
    }
}

private struct CapturedOutput {
    let limit: Int
    var data = Data()
    var truncated = false

    /// Bound each drain so a continuously writing process cannot starve timeout enforcement.
    mutating func drain(_ descriptor: Int32) throws -> Bool {
        var buffer = [UInt8](repeating: 0, count: 8_192)
        for _ in 0..<16 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return true }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return true }
                throw SubprocessError.pipeIO(errno)
            }
            let kept = min(count, limit - data.count)
            data.append(contentsOf: buffer.prefix(kept))
            truncated = truncated || kept < count
        }
        return false
    }
}

/// Cancellation crosses the dispatch worker boundary; all access is protected by this lock.
private final class SubprocessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }
}
