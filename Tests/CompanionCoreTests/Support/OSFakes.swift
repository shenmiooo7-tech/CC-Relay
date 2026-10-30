import Foundation
@testable import CompanionCore

enum FakeScriptError: Error, Equatable, Sendable {
    case empty
    case failed(String)
}

/// NSLock is unavailable directly inside async functions on this SDK, so every
/// fake takes the lock in this synchronous helper.
func withLock<T>(_ lock: NSLock, _ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
}

/// Replays scripted `ClaudeInstance` values, including `hasExplicitProfileFlag`.
final class FakeProcessController: ClaudeProcessControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var instances: Result<[ClaudeInstance], FakeScriptError> = .success([])
    private var quitResults: [Result<QuitOutcome, FakeScriptError>] = []
    private var launchResults: [Result<ClaudeInstance, FakeScriptError>] = []
    private var quitCalls: [Duration] = []
    private var immediateQuits: [Bool] = []
    private var scopedQuitCalls: [ClaudeInstance] = []
    private var launchCalls: [(profile: URL, deepLink: URL?)] = []
    private var runningCalls = 0
    private var leftovers = false
    private var leftoverUse = ProfilesInUse()
    private var refusalClosedProfiles: [URL]?
    private var beforeForceAnswers: [Bool] = []
    private var simulatesTransitions = false
    private var closeError: ClaudeProcessError?
    private var closeHook: (@Sendable () async -> Void)?
    private var closedHook: (@Sendable () async -> Void)?
    private var profilesInUseHook: (@Sendable () async -> Void)?
    private var launchHook: (@Sendable (URL, URL?) throws -> Void)?
    private var asyncLaunchHook: (@Sendable (URL, URL?) async throws -> Void)?

    func simulateTransitions(_ enabled: Bool = true) { withLock(lock) { simulatesTransitions = enabled } }
    func failClose(_ error: ClaudeProcessError) { withLock(lock) { closeError = error } }
    func onClose(_ hook: @escaping @Sendable () async -> Void) { withLock(lock) { closeHook = hook } }
    /// A process appearing after the closing set exited is not part of that set.
    func onCloseCompleted(_ hook: @escaping @Sendable () async -> Void) { withLock(lock) { closedHook = hook } }
    func onProfilesInUse(_ hook: @escaping @Sendable () async -> Void) { withLock(lock) { profilesInUseHook = hook } }
    func onLaunch(_ hook: @escaping @Sendable (URL, URL?) throws -> Void) { withLock(lock) { launchHook = hook } }
    func onLaunchAsync(_ hook: @escaping @Sendable (URL, URL?) async throws -> Void) { withLock(lock) { asyncLaunchHook = hook } }

    func setInstances(_ instances: [ClaudeInstance]) {
        withLock(lock) { self.instances = .success(instances) }
    }

    func failInstances(_ error: FakeScriptError) {
        withLock(lock) { instances = .failure(error) }
    }

    /// Helpers (or tasks under them) that outlived their main process. A successful quit clears them.
    func setLeftovers(_ alive: Bool) {
        withLock(lock) { leftovers = alive }
    }

    /// What such leftovers use: profiles they name, and whether one names none.
    func setLeftoverUse(profiles: [URL], unattributed: Bool = false) {
        withLock(lock) { leftoverUse = ProfilesInUse(profiles: profiles, unattributed: unattributed) }
    }

    func enqueueQuit(_ result: Result<QuitOutcome, FakeScriptError>) {
        withLock(lock) { quitResults.append(result) }
    }

    func enqueueLaunch(_ result: Result<ClaudeInstance, FakeScriptError>) {
        withLock(lock) { launchResults.append(result) }
    }

    func recordedQuitTimeouts() -> [Duration] {
        withLock(lock) { quitCalls }
    }

    /// For each `quitAll`, whether it was asked to force at once.
    func recordedImmediateQuits() -> [Bool] {
        withLock(lock) { immediateQuits }
    }

    func recordedLaunches() -> [(profile: URL, deepLink: URL?)] {
        withLock(lock) { launchCalls }
    }

    func runningQueryCount() -> Int {
        withLock(lock) { runningCalls }
    }

    func runningInstances() async throws -> [ClaudeInstance] {
        try withLock(lock) {
            runningCalls += 1
            return instances
        }.get()
    }

    func hasAnyProcess() async throws -> Bool {
        try withLock(lock) {
            switch instances {
            case .success(let current): return leftovers || !current.isEmpty
            case .failure(let error): throw error
            }
        }
    }

    func profilesInUse() async throws -> ProfilesInUse {
        let hook = withLock(lock) { profilesInUseHook }
        await hook?()
        return try withLock(lock) {
            switch instances {
            case .success(let current):
                return ProfilesInUse(profiles: current.map(\.profileDirectory) + leftoverUse.profiles,
                                     unattributed: leftoverUse.unattributed)
            case .failure(let error): throw error
            }
        }
    }

    /// When set, the next quits consult `beforeForce`; a `false` answer fails the quit
    /// with these profiles reported as closed.
    func consultBeforeForce(closedProfilesWhenRefused: [URL]) {
        withLock(lock) { refusalClosedProfiles = closedProfilesWhenRefused }
    }

    func recordedBeforeForceAnswers() -> [Bool] {
        withLock(lock) { beforeForceAnswers }
    }

    func quitAll(timeout: Duration, immediately: Bool,
                 beforeForce: @escaping @Sendable () async -> Bool) async throws -> QuitOutcome {
        let consult = withLock(lock) { () -> [URL]? in
            quitCalls.append(timeout)
            immediateQuits.append(immediately)
            return refusalClosedProfiles
        }
        if let closed = consult {
            let answer = await beforeForce()
            withLock(lock) { beforeForceAnswers.append(answer) }
            if !answer {
                withLock(lock) {
                    if simulatesTransitions, case .success(let current) = instances {
                        instances = .success(current.filter { instance in
                            !closed.contains { ProfilePaths.same($0, instance.profileDirectory) }
                        })
                    }
                }
                throw ClaudeProcessError.stillRunning(pids: [], closedProfiles: closed)
            }
        }
        let hook = withLock(lock) { closeHook }
        await hook?()
        let outcome = try withLock(lock) {
            if let closeError {
                if case .stillRunning(_, let closed, _, _) = closeError, simulatesTransitions,
                   case .success(let current) = instances {
                    instances = .success(current.filter { instance in
                        !closed.contains { ProfilePaths.same($0, instance.profileDirectory) }
                    })
                }
                throw closeError
            }
            let result = quitResults.isEmpty ? .success(QuitOutcome.alreadyStopped) : quitResults.removeFirst()
            if case .success = result { leftovers = false; leftoverUse = ProfilesInUse() }
            if simulatesTransitions, case .success = result { instances = .success([]) }
            return try result.get()
        }
        let completed = withLock(lock) { closedHook }
        await completed?()
        return outcome
    }

    func recordedScopedQuits() -> [ClaudeInstance] { withLock(lock) { scopedQuitCalls } }

    func quit(instance: ClaudeInstance, timeout: Duration,
              beforeForce: @escaping @Sendable () async -> Bool) async throws -> QuitOutcome {
        let consult = withLock(lock) { scopedQuitCalls.append(instance); return refusalClosedProfiles }
        if let closed = consult {
            let allowed = await beforeForce()
            withLock(lock) { beforeForceAnswers.append(allowed) }
            if !allowed { throw ClaudeProcessError.stillRunning(pids: [instance.pid], closedProfiles: closed) }
        }
        let hook = withLock(lock) { closeHook }
        await hook?()
        return try withLock(lock) {
            if let closeError { throw closeError }
            if simulatesTransitions, case .success(let current) = instances {
                instances = .success(current.filter { $0 != instance })
            }
            return .quit
        }
    }

    func launch(profile: URL, deepLink: URL?) async throws -> ClaudeInstance {
        let (hook, asyncHook, scripted, simulate, callIndex) = withLock(lock) {
            launchCalls.append((profile, deepLink))
            let scripted = launchResults.isEmpty ? nil : launchResults.removeFirst()
            return (launchHook, asyncLaunchHook, scripted, simulatesTransitions, launchCalls.count)
        }
        try await asyncHook?(profile, deepLink)
        try hook?(profile, deepLink)
        let instance: ClaudeInstance
        if let scripted { instance = try scripted.get() }
        else if simulate {
            instance = ClaudeInstance(pid: Int32(1000 + callIndex), profileDirectory: profile,
                hasExplicitProfileFlag: true, startedAt: Date(), executableURL: profile.appending(path: "FakeClaude"))
        } else { throw FakeScriptError.empty }
        if simulate {
            withLock(lock) {
                if case .success(var current) = instances { current.append(instance); instances = .success(current) }
            }
        }
        return instance
    }

}

/// Yields each `LaunchEvent` unchanged, including `hasExplicitProfileFlag`.
final class FakeLaunchMonitor: ClaudeLaunchMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<LaunchEvent>.Continuation] = []
    private var starts = 0

    func startCount() -> Int {
        withLock(lock) { starts }
    }

    func launches() -> AsyncStream<LaunchEvent> {
        let (stream, continuation) = AsyncStream<LaunchEvent>.makeStream()
        withLock(lock) {
            starts += 1
            continuations.append(continuation)
        }
        return stream
    }

    func emit(_ event: LaunchEvent) {
        for continuation in snapshot() {
            continuation.yield(event)
        }
    }

    func finish() {
        for continuation in snapshot(clear: true) {
            continuation.finish()
        }
    }

    private func snapshot(clear: Bool = false) -> [AsyncStream<LaunchEvent>.Continuation] {
        withLock(lock) {
            let current = continuations
            if clear {
                continuations.removeAll()
            }
            return current
        }
    }
}

final class FakeTaskInspector: CodeTaskInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [TaskActivity] = []
    private var calls = 0

    func enqueue(_ activity: TaskActivity) {
        withLock(lock) { script.append(activity) }
    }

    func callCount() -> Int {
        withLock(lock) { calls }
    }

    func activity() async -> TaskActivity {
        withLock(lock) {
            calls += 1
            return script.isEmpty ? .idle : script.removeFirst()
        }
    }
}

final class FakeSafeStorage: SafeStorageKeyProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Data, FakeScriptError>] = []
    private var calls = 0

    func enqueue(_ result: Result<Data, FakeScriptError>) {
        withLock(lock) { results.append(result) }
    }

    func callCount() -> Int {
        withLock(lock) { calls }
    }

    func password() async throws -> Data {
        try withLock(lock) {
            calls += 1
            return results.isEmpty ? .failure(.empty) : results.removeFirst()
        }.get()
    }
}

final class FakeCookieReader: SessionCookieReading, @unchecked Sendable {
    private let lock = NSLock()
    private var cookies: [URL: Result<EncryptedCookie?, FakeScriptError>] = [:]
    private var profiles: [URL] = []

    func setCookie(_ cookie: EncryptedCookie?, for profile: URL) {
        withLock(lock) { cookies[ProfilePaths.canonical(profile)] = .success(cookie) }
    }

    func fail(_ error: FakeScriptError, for profile: URL) {
        withLock(lock) { cookies[ProfilePaths.canonical(profile)] = .failure(error) }
    }

    func recordedProfiles() -> [URL] {
        withLock(lock) { profiles }
    }

    func sessionCookie(profile: URL) throws -> EncryptedCookie? {
        try withLock(lock) {
            profiles.append(profile)
            return cookies[ProfilePaths.canonical(profile)] ?? .success(nil)
        }.get()
    }
}

final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<HTTPResponse, FakeScriptError>] = []
    private var requests: [HTTPRequest] = []

    func enqueue(_ result: Result<HTTPResponse, FakeScriptError>) {
        withLock(lock) { responses.append(result) }
    }

    func recordedRequests() -> [HTTPRequest] {
        withLock(lock) { requests }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try withLock(lock) {
            requests.append(request)
            return responses.isEmpty ? .failure(.empty) : responses.removeFirst()
        }.get()
    }
}

final class FakeLoginItems: LoginItemManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var enabledError: FakeScriptError?
    private var enables: [URL] = []
    private var enableError: FakeScriptError?
    private var disables = 0

    func setEnabled(_ enabled: Bool) {
        withLock(lock) {
            self.enabled = enabled
            enabledError = nil
        }
    }

    func failEnabled(_ error: FakeScriptError) {
        withLock(lock) { enabledError = error }
    }

    func failEnable(_ error: FakeScriptError) { withLock(lock) { enableError = error } }

    func recordedEnables() -> [URL] {
        withLock(lock) { enables }
    }

    func disableCount() -> Int {
        withLock(lock) { disables }
    }

    var isEnabled: Bool {
        get async throws {
            let (error, value) = withLock(lock) { (enabledError, enabled) }
            if let error {
                throw error
            }
            return value
        }
    }

    func enable(executable: URL) async throws {
        try withLock(lock) {
            if let enableError { throw enableError }
            enables.append(executable)
            enabled = true
        }
    }

    func disable() async throws {
        withLock(lock) {
            disables += 1
            enabled = false
        }
    }
}

final class FakeFileRevealer: FileRevealing, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var error: FakeScriptError?

    func fail(_ error: FakeScriptError) {
        withLock(lock) { self.error = error }
    }

    func recordedURLs() -> [URL] {
        withLock(lock) { urls }
    }

    func reveal(_ url: URL) async throws {
        let error = withLock(lock) { () -> FakeScriptError? in
            urls.append(url)
            return error
        }
        if let error {
            throw error
        }
    }
}
