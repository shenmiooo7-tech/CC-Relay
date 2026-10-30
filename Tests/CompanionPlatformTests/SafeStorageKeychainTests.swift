import CompanionCore
import Foundation
import XCTest
@testable import CompanionPlatform

@MainActor
final class SafeStorageKeychainTests: XCTestCase {
    func testExactCommandTrimsOnlyLineEndingAndCachesInMemory() async throws {
        let runner = KeychainFakeRunner(results: [.success(SubprocessResult(
            exitStatus: 0, stdout: Data("  fixture-secret  \n".utf8)
        ))])
        let keychain = SafeStorageKeychain(runner: runner, liveActionCheck: {})
        let first = try await keychain.password()
        let second = try await keychain.password()
        XCTAssertEqual(first, Data("  fixture-secret  ".utf8))
        XCTAssertEqual(second, first)
        let calls = await runner.calls
        XCTAssertEqual(calls, [KeychainFakeRunner.Call(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-w", "-s", "Claude Safe Storage"],
            timeout: 20, outputLimit: 65_536
        )])
    }

    func testCRLFAndOutputWithoutNewline() async throws {
        for output in ["fixture-secret\r\n", "fixture-secret"] {
            let runner = KeychainFakeRunner(results: [.success(SubprocessResult(exitStatus: 0, stdout: Data(output.utf8)))])
            let result = try await SafeStorageKeychain(runner: runner, liveActionCheck: {}).password()
            XCTAssertEqual(result, Data("fixture-secret".utf8))
        }
    }

    func testExitCodeMappingDoesNotExposeOutput() async {
        let cases: [(Int32, SafeStorageKeychainError)] = [
            (44, .notFound), (51, .userDenied), (128, .userDenied), (9, .commandFailed(9)),
        ]
        for (status, expected) in cases {
            let runner = KeychainFakeRunner(results: [.success(SubprocessResult(
                exitStatus: status, stdout: Data("secret output".utf8), stderr: Data("secret diagnostic".utf8)
            ))])
            await assertFailure(SafeStorageKeychain(runner: runner, liveActionCheck: {}), expected: expected)
        }
    }

    func testEmptyTruncatedAndTimedOutResultsAreRejected() async {
        let cases: [(SubprocessResult, SafeStorageKeychainError)] = [
            (SubprocessResult(exitStatus: 0), .invalidOutput),
            (SubprocessResult(exitStatus: 0, stdout: Data("\n".utf8)), .invalidOutput),
            (SubprocessResult(exitStatus: 0, stdout: Data("partial".utf8), stdoutTruncated: true), .invalidOutput),
            (SubprocessResult(exitStatus: 9, timedOut: true), .timedOut),
        ]
        for (result, expected) in cases {
            let runner = KeychainFakeRunner(results: [.success(result)])
            await assertFailure(SafeStorageKeychain(runner: runner, liveActionCheck: {}), expected: expected)
        }
    }

    func testRunnerErrorsAreMappedAndFailuresAreNotCached() async throws {
        let runner = KeychainFakeRunner(results: [
            .failure(SubprocessError.pipeIO(5)),
            .success(SubprocessResult(exitStatus: 0, stdout: Data("retried\n".utf8))),
        ])
        let keychain = SafeStorageKeychain(runner: runner, liveActionCheck: {})
        await assertFailure(keychain, expected: .executionFailed)
        let result = try await keychain.password()
        XCTAssertEqual(result, Data("retried".utf8))
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testConcurrentLookupsShareOneRunnerCall() async throws {
        let runner = KeychainFakeRunner(
            results: [.success(SubprocessResult(exitStatus: 0, stdout: Data("shared\n".utf8)))],
            delay: .milliseconds(100)
        )
        let keychain = SafeStorageKeychain(runner: runner, liveActionCheck: {})
        async let first = keychain.password()
        async let second = keychain.password()
        let results = try await [first, second]
        XCTAssertEqual(results, [Data("shared".utf8), Data("shared".utf8)])
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testPublicInitializerRefusesInsideTestProcessBeforeRunner() async {
        let runner = KeychainFakeRunner(results: [])
        do {
            _ = try await SafeStorageKeychain(runner: runner).password()
            XCTFail("The ambient test tripwire must refuse the lookup")
        } catch {
            XCTAssertTrue(error is SafetyRefusal)
        }
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testSandboxTripwireRefusesBeforeFakeRunner() async {
        let runner = KeychainFakeRunner(results: [])
        let keychain = SafeStorageKeychain(runner: runner, liveActionCheck: {
            try SafetyTripwire.assertLiveActionsAllowed(environment: [SafetyTripwire.sandboxVariable: ""])
        })
        do {
            _ = try await keychain.password()
            XCTFail("The sandbox tripwire must refuse the lookup")
        } catch {
            XCTAssertEqual((error as? SafetyRefusal)?.variable, SafetyTripwire.sandboxVariable)
        }
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    private func assertFailure(_ keychain: SafeStorageKeychain, expected: SafeStorageKeychainError) async {
        do {
            _ = try await keychain.password()
            XCTFail("Expected keychain lookup failure")
        } catch {
            XCTAssertEqual(error as? SafeStorageKeychainError, expected)
        }
    }
}

private actor KeychainFakeRunner: SubprocessRunning {
    struct Call: Equatable, Sendable {
        let executable: URL
        let arguments: [String]
        let timeout: TimeInterval
        let outputLimit: Int
    }

    private(set) var calls: [Call] = []
    private var results: [Result<SubprocessResult, SubprocessError>]
    private let delay: Duration

    init(results: [Result<SubprocessResult, SubprocessError>], delay: Duration = .zero) {
        self.results = results
        self.delay = delay
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval, outputLimit: Int) async throws -> SubprocessResult {
        calls.append(Call(executable: executable, arguments: arguments, timeout: timeout, outputLimit: outputLimit))
        guard !results.isEmpty else { throw SubprocessError.invalidConfiguration }
        let result = results.removeFirst()
        if delay > .zero { try await Task.sleep(for: delay) }
        return try result.get()
    }
}
