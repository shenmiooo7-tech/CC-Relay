import AppKit
import CompanionCore
import Foundation
import os

public struct LiveClaudeLaunchMonitor: ClaudeLaunchMonitoring {
    private let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    public func launches() -> AsyncStream<LaunchEvent> {
        do { try SafetyTripwire.assertLiveActionsAllowed() }
        catch { return AsyncStream { $0.finish() } }
        return AsyncStream { continuation in
            let observer = WorkspaceLaunchObservation(paths: paths, continuation: continuation)
            Task { @MainActor in observer.start() }
            continuation.onTermination = { _ in Task { @MainActor in observer.stop() } }
        }
    }
}

private final class WorkspaceLaunchObservation: Sendable {
    private let paths: AppPaths
    private let continuation: AsyncStream<LaunchEvent>.Continuation
    @MainActor private var token: (any NSObjectProtocol)?
    @MainActor private var stopped = false

    init(paths: AppPaths, continuation: AsyncStream<LaunchEvent>.Continuation) {
        self.paths = paths
        self.continuation = continuation
    }

    @MainActor func start() {
        do { try SafetyTripwire.assertLiveActionsAllowed() }
        catch { continuation.finish(); return }
        guard !stopped else { return }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [paths, continuation] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.bundleIdentifier == ClaudeAppLocation.bundleIdentifier,
                  let record = ProcessTable().record(pid: application.processIdentifier) else { return }
            do {
                if let instance = try InstanceMapping.instance(record,
                    mainExecutable: paths.claudeAppURL.appendingPathComponent("Contents/MacOS/Claude"),
                    defaultProfile: paths.claudeProfilesRoot.appendingPathComponent("Claude", isDirectory: true)) {
                    continuation.yield(InstanceMapping.event(instance))
                }
            } catch {
                Logger(subsystem: "local.cc-relay", category: "platform")
                    .warning("Skipped launch with unknown profile arguments")
            }
        }
    }

    @MainActor func stop() {
        stopped = true
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
    }
}
