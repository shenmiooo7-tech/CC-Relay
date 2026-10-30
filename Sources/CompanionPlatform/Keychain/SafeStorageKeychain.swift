import CompanionCore
import Foundation

public enum SafeStorageKeychainError: Error, Equatable, Sendable {
    case notFound
    case userDenied
    case commandFailed(Int32)
    case executionFailed
    case timedOut
    case invalidOutput
}

/// The secret and any in-flight lookup live only in this actor's memory.
public actor SafeStorageKeychain {
    private let runner: any SubprocessRunning
    private let liveActionCheck: @Sendable () throws -> Void
    private var cached: Data?
    private var pending: Task<Data, Error>?

    public init(runner: any SubprocessRunning = SubprocessRunner()) {
        self.runner = runner
        self.liveActionCheck = { try SafetyTripwire.assertLiveActionsAllowed() }
    }

    /// Test seam: fake runners can bypass live-action checks without changing process state.
    init(runner: any SubprocessRunning, liveActionCheck: @escaping @Sendable () throws -> Void) {
        self.runner = runner
        self.liveActionCheck = liveActionCheck
    }

    public func password() async throws -> Data {
        try liveActionCheck()
        if let cached { return cached }
        if let pending { return try await pending.value }
        let runner = self.runner
        let lookup = Task { try await Self.fetch(using: runner) }
        pending = lookup
        do {
            let password = try await lookup.value
            cached = password
            pending = nil
            return password
        } catch {
            pending = nil
            throw error
        }
    }

    private static func fetch(using runner: any SubprocessRunning) async throws -> Data {
        let result: SubprocessResult
        do {
            result = try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/security"),
                arguments: ["find-generic-password", "-w", "-s", "Claude Safe Storage"],
                timeout: 20, outputLimit: 65_536
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Do not propagate command diagnostics, which may contain sensitive output.
            throw SafeStorageKeychainError.executionFailed
        }
        if result.timedOut { throw SafeStorageKeychainError.timedOut }
        switch result.exitStatus {
        case 0: break
        case 44: throw SafeStorageKeychainError.notFound
        case 51, 128: throw SafeStorageKeychainError.userDenied
        default: throw SafeStorageKeychainError.commandFailed(result.exitStatus)
        }
        guard !result.stdoutTruncated else { throw SafeStorageKeychainError.invalidOutput }
        var password = result.stdout
        if password.last == 0x0a {
            password.removeLast()
            if password.last == 0x0d { password.removeLast() }
        }
        guard !password.isEmpty else { throw SafeStorageKeychainError.invalidOutput }
        return password
    }
}
