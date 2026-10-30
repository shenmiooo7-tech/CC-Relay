import CompanionCore
import Darwin
import Foundation

public actor SandboxClaudeProcessController: ClaudeProcessControlling {
    private let executable: URL
    private let boundary: SandboxBoundary
    private let defaultProfile: URL
    private let environment: [String: String]
    private let polling: AdapterPolling
    private let verificationTimeout: Duration
    private var children: [Int32: Process] = [:]

    public init(root: URL, fakeClaudeExecutable: URL, environment: [String: String] = [:],
                clock: any CompanionCore.Clock = SystemClock(), verificationTimeout: Duration = .seconds(30)) {
        boundary = SandboxBoundary(root: root)
        executable = fakeClaudeExecutable.standardizedFileURL.resolvingSymlinksInPath()
        defaultProfile = AppPaths.sandbox(root: root).claudeProfilesRoot.appendingPathComponent("Claude", isDirectory: true)
        self.environment = environment
        polling = AdapterPolling(clock: clock)
        self.verificationTimeout = verificationTimeout
    }

    public func runningInstances() async throws -> [ClaudeInstance] {
        try checkExecutable()
        children = children.filter { $0.value.isRunning }
        do {
            return try ProcessTable().checkedProcesses { $0.standardizedFileURL == executable }
                .compactMap { record in
                    guard let instance = try InstanceMapping.instance(record, mainExecutable: executable, defaultProfile: defaultProfile)
                    else { return nil }
                    try boundary.check(instance.profileDirectory)
                    return instance
                }
        } catch { throw ClaudeProcessError.processTableUnavailable }
    }

    public func launch(profile: URL, deepLink: URL?) async throws -> ClaudeInstance {
        let child = try spawn(profile: profile, deepLink: deepLink, explicitProfile: true)
        let deadline = polling.clock.now().addingTimeInterval(max(0, verificationTimeout.timeInterval))
        var observed: ClaudeInstance?
        do {
            let verified = try await polling.until(deadline) {
                guard child.isRunning else { throw ClaudeProcessError.launchFailed }
                observed = try await self.runningInstances().first {
                    $0.pid == child.processIdentifier && $0.hasExplicitProfileFlag &&
                    ProfilePaths.same($0.profileDirectory, profile)
                }
                // FakeClaude's readiness file is written after its signal handlers are installed.
                return observed != nil && self.isReady(profile: profile, pid: child.processIdentifier)
            }
            guard verified, let observed, child.isRunning
            else { throw ClaudeProcessError.launchFailed }
            return observed
        } catch {
            // A failed/cancelled launch must not leak a child the caller believes never started.
            if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
            children[child.processIdentifier] = nil
            throw error
        }
    }

    /// A Dock launch is only requested: the launch monitor may correct it immediately.
    public func launchDefault() throws -> Int32 {
        try spawn(profile: defaultProfile, deepLink: nil, explicitProfile: false).processIdentifier
    }

    private func spawn(profile: URL, deepLink: URL?, explicitProfile: Bool) throws -> Process {
        try checkExecutable()
        try boundary.check(profile)
        try DeepLinkValidation.validate(deepLink)
        try Task.checkCancellation()
        let child = Process()
        child.executableURL = executable
        child.arguments = (explicitProfile ? ["--user-data-dir=\(profile.standardizedFileURL.path)"] : [])
            + (deepLink.map { [$0.absoluteString] } ?? [])
        child.currentDirectoryURL = boundary.root
        child.environment = ProcessInfo.processInfo.environment.merging(environment, uniquingKeysWith: { _, value in value })
        child.environment?["FAKE_CLAUDE_SANDBOX_ROOT"] = boundary.root.standardizedFileURL.path
        if !explicitProfile { child.environment?["FAKE_CLAUDE_DEFAULT_PROFILE"] = defaultProfile.path }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { throw ClaudeProcessError.launchFailed }
        children[child.processIdentifier] = child
        return child
    }

    public func hasAnyProcess() async throws -> Bool {
        try checkExecutable()
        return try closingEngine().hasProcesses()
    }

    public func profilesInUse() async throws -> ProfilesInUse {
        try checkExecutable()
        return try closingEngine().profilesInUse()
    }

    public func quitAll(timeout: Duration, immediately: Bool,
                        beforeForce: @escaping @Sendable () async -> Bool) async throws -> QuitOutcome {
        try checkExecutable()
        return try await closingEngine().close(timeout: timeout, immediately: immediately, beforeForce: beforeForce)
    }

    public func quit(instance: ClaudeInstance, timeout: Duration,
                     beforeForce: @escaping @Sendable () async -> Bool) async throws -> QuitOutcome {
        try checkExecutable()
        return try await closingEngine().close(timeout: timeout, instance: instance, beforeForce: beforeForce)
    }

    private func closingEngine() -> ClaudeClosingEngine {
        let executable = self.executable
        let helper = executable.deletingLastPathComponent().appendingPathComponent("Helpers/FakeClaudeHelper").standardizedFileURL
        let boundary = self.boundary
        let send: @Sendable (ClosingIdentity, Int32) throws -> Void = { identity, signal in
            try boundary.check(executable)
            try boundary.check(identity.executable)
            guard ProcessTable().closingProcess(pid: identity.pid)?.identity == identity else { return }
            _ = Darwin.kill(identity.pid, signal)
        }
        return ClaudeClosingEngine(
            mainExecutable: executable, defaultProfile: defaultProfile,
            isBundleExecutable: { $0.standardizedFileURL == executable || $0.standardizedFileURL == helper },
            readTable: { try ProcessTable().closingProcesses() },
            readArguments: { try ProcessTable().closingArguments($0) },
            normalQuit: { try send($0, SIGTERM) },
            normalQuitOutcome: .quitAfterSignal,
            signal: { identity, signal, _ in try send(identity, signal == .force ? SIGKILL : SIGTERM) },
            clock: polling.clock)
    }

    private func checkExecutable() throws {
        try boundary.check(executable)
        guard executable.lastPathComponent == "FakeClaude" else { throw SandboxAdapterError.invalidExecutable }
    }

    private func isReady(profile: URL, pid: Int32) -> Bool {
        let file = profile.appendingPathComponent(".fake-claude/instance.json")
        guard let data = try? Data(contentsOf: file),
              let readiness = try? JSONDecoder().decode(Readiness.self, from: data) else { return false }
        return readiness.pid == pid
    }

    private struct Readiness: Decodable { let pid: Int32 }
}
