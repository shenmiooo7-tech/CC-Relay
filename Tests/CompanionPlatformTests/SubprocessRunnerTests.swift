import Darwin
import Foundation
import XCTest
import CompanionPlatform

@MainActor
final class SubprocessRunnerTests: XCTestCase {
    func testEchoPreservesLiteralArgumentsWithoutShellExpansion() async throws {
        let arguments = ["two words", "$(printf unsafe)", ";", "--user-data-dir=/some space"]
        let result = try await SubprocessRunner().run(
            executable: URL(fileURLWithPath: "/bin/echo"), arguments: arguments
        )
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), arguments.joined(separator: " ") + "\n")
        XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.stdoutTruncated)
    }

    func testStderrAndNonzeroExitStatus() async throws {
        let directory = try PlatformTestDirectory()
        defer { directory.remove() }
        let script = try directory.script("printf 'warning from stderr\\n' >&2\nexit 7\n")
        let result = try await SubprocessRunner().run(executable: script)
        XCTAssertEqual(result.exitStatus, 7)
        XCTAssertEqual(String(data: result.stderr, encoding: .utf8), "warning from stderr\n")
        XCTAssertTrue(result.stdout.isEmpty)
    }

    func testSleepTimesOutPromptly() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await SubprocessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.15
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.exitStatus, 0)
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(3))
    }

    func testTimeoutEscalatesToKillWhenChildIgnoresTerm() async throws {
        let directory = try PlatformTestDirectory()
        defer { directory.remove() }
        let script = try directory.script("trap '' TERM\nprintf 'ready\\n'\nwhile :; do :; done\n")
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await SubprocessRunner(terminationGracePeriod: 0.1).run(
            // Allow the script interpreter to install its trap before the timeout fires.
            executable: script, timeout: 2
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitStatus, SIGKILL)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "ready\n")
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(5))
    }

    func testBothPipesAreDrainedBeyondTheirCaptureLimits() async throws {
        let directory = try PlatformTestDirectory()
        defer { directory.remove() }
        let script = try directory.script("""
            i=0
            while [ "$i" -lt 10000 ]; do
                printf '0123456789'
                printf 'abcdefghij' >&2
                i=$((i+1))
            done
            """)
        let result = try await SubprocessRunner().run(executable: script, timeout: 10, outputLimit: 31)
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout, Data("0123456789012345678901234567890".utf8))
        XCTAssertEqual(result.stderr, Data("abcdefghijabcdefghijabcdefghija".utf8))
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertTrue(result.stderrTruncated)
    }

    func testZeroCaptureLimitStillDrainsOutput() async throws {
        let result = try await SubprocessRunner().run(
            executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["discard"], outputLimit: 0
        )
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertFalse(result.stderrTruncated)
    }

    func testCancellationStopsOwnedChild() async throws {
        let task = Task {
            try await SubprocessRunner().run(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 10
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }

    func testLaunchFailureIsReported() async throws {
        let directory = try PlatformTestDirectory()
        defer { directory.remove() }
        do {
            _ = try await SubprocessRunner().run(executable: directory.root.appendingPathComponent("missing"))
            XCTFail("Expected a launch failure")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testInvalidConfigurationIsRejectedBeforeLaunch() async {
        for (timeout, limit) in [(0.0, 10), (-1.0, 10), (Double.infinity, 10), (1.0, -1)] {
            do {
                _ = try await SubprocessRunner().run(
                    executable: URL(fileURLWithPath: "/missing"), timeout: timeout, outputLimit: limit
                )
                XCTFail("Expected invalid configuration")
            } catch {
                XCTAssertEqual(error as? SubprocessError, .invalidConfiguration)
            }
        }
    }
}
