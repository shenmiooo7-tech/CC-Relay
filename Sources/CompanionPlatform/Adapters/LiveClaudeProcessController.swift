import AppKit
import CompanionCore
import Darwin
import Foundation

public struct LiveClaudeProcessController: ClaudeProcessControlling {
    private let paths: AppPaths
    private let polling: AdapterPolling
    private var executable: URL { paths.claudeAppURL.appendingPathComponent("Contents/MacOS/Claude") }

    public init(paths: AppPaths, clock: any CompanionCore.Clock = SystemClock()) {
        self.paths = paths
        polling = AdapterPolling(clock: clock)
    }

    public func runningInstances() async throws -> [ClaudeInstance] {
        try SafetyTripwire.assertLiveActionsAllowed()
        do {
            return try ProcessTable().checkedProcesses { $0.standardizedFileURL == executable.standardizedFileURL }
                .compactMap { try InstanceMapping.instance($0, mainExecutable: executable,
                    defaultProfile: paths.claudeProfilesRoot.appendingPathComponent("Claude", isDirectory: true)) }
        } catch { throw ClaudeProcessError.processTableUnavailable }
    }

    public func hasAnyProcess() async throws -> Bool {
        try SafetyTripwire.assertLiveActionsAllowed()
        return try closingEngine().hasProcesses()
    }

    public func profilesInUse() async throws -> ProfilesInUse {
        try SafetyTripwire.assertLiveActionsAllowed()
        return try closingEngine().profilesInUse()
    }

    public func quitAll(timeout: Duration, immediately: Bool,
                        beforeForce: @escaping @Sendable () async -> Bool) async throws -> QuitOutcome {
        try SafetyTripwire.assertLiveActionsAllowed()
        return try await closingEngine().close(timeout: timeout, immediately: immediately, beforeForce: beforeForce)
    }

    public func quit(instance: ClaudeInstance, timeout: Duration,
                     beforeForce: @escaping @Sendable () async -> Bool) async throws -> QuitOutcome {
        try SafetyTripwire.assertLiveActionsAllowed()
        return try await closingEngine().close(timeout: timeout, instance: instance, beforeForce: beforeForce)
    }

    private func closingEngine() -> ClaudeClosingEngine {
        let contents = paths.claudeAppURL.appendingPathComponent("Contents", isDirectory: true).standardizedFileURL.path + "/"
        return ClaudeClosingEngine(
            mainExecutable: executable,
            defaultProfile: paths.claudeProfilesRoot.appendingPathComponent("Claude", isDirectory: true),
            isBundleExecutable: { $0.standardizedFileURL.path.hasPrefix(contents) },
            readTable: { try ProcessTable().closingProcesses() },
            readArguments: { try ProcessTable().closingArguments($0) },
            normalQuit: { try await Self.requestTermination($0, force: false) },
            normalQuitOutcome: .quit,
            signal: { identity, signal, main in
                if main, signal == .force { try await Self.requestTermination(identity, force: true) }
                else {
                    try SafetyTripwire.assertLiveActionsAllowed()
                    guard ProcessTable().closingProcess(pid: identity.pid)?.identity == identity else { return }
                    _ = Darwin.kill(identity.pid, signal == .force ? SIGKILL : SIGTERM)
                }
            }, clock: polling.clock, reportReopened: { reopened, observed in
                let original = observed.map { "\($0.pid)@\($0.startedAt.timeIntervalSince1970)" }.sorted().joined(separator: ",")
                let added = reopened.map { "\($0.identity.pid)@\($0.identity.startedAt.timeIntervalSince1970) parent=\($0.parent)" }.sorted().joined(separator: ",")
                CompanionLog(paths: paths).warning(.platform, "Close observed new Claude main identities: original=[\(original)], new=[\(added)].")
            })
    }

    public func launch(profile: URL, deepLink: URL?) async throws -> ClaudeInstance {
        try SafetyTripwire.assertLiveActionsAllowed()
        try DeepLinkValidation.validate(deepLink)
        guard profile.isFileURL else { throw ClaudeProcessError.launchFailed }
        let executable = executable.standardizedFileURL
        let engine = ClaudeLaunchEngine(
            open: { link in Self.launched(pid: try await open(profile: profile, deepLink: link), executable: executable) },
            instances: { try await runningInstances() },
            polling: polling)
        return try await engine.launch(profile: profile, deepLink: deepLink)
    }

    @MainActor private func open(profile: URL, deepLink: URL?) async throws -> Int32 {
        try SafetyTripwire.assertLiveActionsAllowed()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--user-data-dir=\(profile.standardizedFileURL.path)"]
        // Code inspects inherited PWD during startup even when its session has another cwd.
        // A launcher started in Documents can otherwise strand its disclaimed native child.
        configuration.environment = ProcessInfo.processInfo.environment.merging(["PWD": "/"]) { _, value in value }
        let app: NSRunningApplication
        if let deepLink {
            app = try await NSWorkspace.shared.open([deepLink], withApplicationAt: paths.claudeAppURL, configuration: configuration)
        } else {
            app = try await NSWorkspace.shared.openApplication(at: paths.claudeAppURL, configuration: configuration)
        }
        return app.processIdentifier
    }

    /// Looks the process up again for every step, so a reused pid of another program is never signalled.
    private static func launched(pid: Int32, executable: URL) -> LaunchedApp {
        LaunchedApp(
            pid: pid,
            isTerminated: { await MainActor.run { claudeApp(pid: pid, executable: executable) == nil } },
            terminate: { await MainActor.run { _ = claudeApp(pid: pid, executable: executable)?.terminate() } },
            forceTerminate: { await MainActor.run { _ = claudeApp(pid: pid, executable: executable)?.forceTerminate() } })
    }

    @MainActor private static func claudeApp(pid: Int32, executable: URL) -> NSRunningApplication? {
        guard (try? SafetyTripwire.assertLiveActionsAllowed()) != nil,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.executableURL?.standardizedFileURL == executable else { return nil }
        return app
    }

    @MainActor private static func requestTermination(_ identity: ClosingIdentity, force: Bool) throws {
        try SafetyTripwire.assertLiveActionsAllowed()
        guard let app = NSRunningApplication(processIdentifier: identity.pid),
              app.executableURL?.standardizedFileURL == identity.executable,
              ProcessTable().closingProcess(pid: identity.pid)?.identity == identity else { return }
        if force { _ = app.forceTerminate() } else { _ = app.terminate() }
    }
}
