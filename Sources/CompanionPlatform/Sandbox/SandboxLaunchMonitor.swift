import CompanionCore
import Foundation
import os

public struct SandboxLaunchMonitor: ClaudeLaunchMonitoring {
    private let root: URL
    private let executable: URL
    private let polling: AdapterPolling

    public init(root: URL, fakeClaudeExecutable: URL, clock: any CompanionCore.Clock = SystemClock()) {
        self.root = root
        executable = fakeClaudeExecutable.standardizedFileURL.resolvingSymlinksInPath()
        polling = AdapterPolling(clock: clock)
    }

    public func launches() -> AsyncStream<LaunchEvent> {
        AsyncStream { continuation in
            let task = Task {
                let boundary = SandboxBoundary(root: root)
                do {
                    try boundary.check(executable)
                    guard executable.lastPathComponent == "FakeClaude" else { throw SandboxAdapterError.invalidExecutable }
                    var seen: Set<Identity> = []
                    while !Task.isCancelled {
                        let records = try ProcessTable().checkedProcesses { $0.standardizedFileURL == executable }
                        let current = Set(records.map { Identity(pid: $0.pid, startedAt: $0.startedAt) })
                        for record in records where !seen.contains(Identity(pid: record.pid, startedAt: record.startedAt)) {
                            do {
                                if let instance = try InstanceMapping.instance(record, mainExecutable: executable,
                                    defaultProfile: AppPaths.sandbox(root: root).claudeProfilesRoot.appendingPathComponent("Claude", isDirectory: true)) {
                                    try boundary.check(instance.profileDirectory)
                                    continuation.yield(InstanceMapping.event(instance))
                                }
                            } catch {
                                Logger(subsystem: "local.cc-relay", category: "platform")
                                    .warning("Skipped sandbox launch with unknown profile arguments")
                            }
                        }
                        seen = current
                        try await polling.clock.sleep(for: polling.interval)
                    }
                } catch { /* Cancellation or an unavailable sandbox ends observation. */ }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Identity: Hashable { let pid: Int32; let startedAt: Date }
}
