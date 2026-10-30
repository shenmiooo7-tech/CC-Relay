import CompanionCore
import Foundation

/// The app one open request started, as far as the adapter can act on it.
struct LaunchedApp: Sendable {
    let pid: Int32
    let isTerminated: @Sendable () async -> Bool
    let terminate: @Sendable () async -> Void
    let forceTerminate: @Sendable () async -> Void
}

/// Opens Claude and waits for the requested profile's main instance. When it never shows up, the
/// instance this open started is closed again before the error is thrown: callers then reopen the
/// previous account, and a target that appears late would leave two accounts open.
struct ClaudeLaunchEngine: Sendable {
    let open: @Sendable (_ deepLink: URL?) async throws -> LaunchedApp
    let instances: @Sendable () async throws -> [ClaudeInstance]
    let polling: AdapterPolling
    var verifyTimeout: TimeInterval = 30
    var closeGrace: TimeInterval = 10
    var forceGrace: TimeInterval = 3

    func launch(profile: URL, deepLink: URL?) async throws -> ClaudeInstance {
        let previous = Set(try await instances().map(\.pid))
        let launched: LaunchedApp
        do { launched = try await open(deepLink) }
        catch {
            try Task.checkCancellation()
            guard deepLink != nil else { throw ClaudeProcessError.launchFailed }
            do { launched = try await open(nil) }
            catch { throw ClaudeProcessError.launchFailed }
        }
        do {
            let deadline = polling.clock.now().addingTimeInterval(verifyTimeout)
            var observed: ClaudeInstance?
            _ = try await polling.until(deadline) {
                observed = try await instances().first {
                    !previous.contains($0.pid) && $0.hasExplicitProfileFlag &&
                        ProfilePaths.same($0.profileDirectory, profile)
                }
                return observed != nil
            }
            guard let observed else { throw ClaudeProcessError.launchFailed }
            return observed
        } catch {
            // Cleanup must finish even when the caller cancelled verification.
            let closed = await Task.detached { await self.withdraw(launched, previous: previous) }.value
            guard closed else { throw ClaudeProcessError.launchCleanupFailed }
            throw error
        }
    }

    /// Only an instance this open created is closed. One that was already running is never touched.
    private func withdraw(_ app: LaunchedApp, previous: Set<Int32>) async -> Bool {
        guard !previous.contains(app.pid), await !app.isTerminated() else { return true }
        await app.terminate()
        let deadline = polling.clock.now().addingTimeInterval(closeGrace)
        let exited = (try? await polling.until(deadline) { await app.isTerminated() }) ?? false
        if exited { return true }
        await app.forceTerminate()
        let forceDeadline = polling.clock.now().addingTimeInterval(forceGrace)
        return (try? await polling.until(forceDeadline) { await app.isTerminated() }) ?? false
    }
}
