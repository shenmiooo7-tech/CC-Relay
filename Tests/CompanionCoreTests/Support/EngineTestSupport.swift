import Foundation
import XCTest
@testable import CompanionCore

actor FakeEngineQuota: QuotaStatusProviding, AccountDetailsProviding {
    var values: [ProfileFolder: QuotaReading] = [:]
    var replacements: [[QuotaProfile]] = []
    var refreshes: [([ProfileFolder], Bool)] = []
    private var refreshResults: [ProfileFolder: Bool] = [:]
    var visible: [[ProfileFolder]] = []
    var currents: [ProfileFolder?] = []
    var stops = 0
    var details: Result<AccountRecord, QuotaFailure> = .failure(.keyUnavailable)
    var detailCalls: [QuotaProfile] = []
    private var refreshHook: (@Sendable () async -> Void)?
    private var subscribers: [AsyncStream<[ProfileFolder: QuotaReading]>.Continuation] = []

    func readings() -> AsyncStream<[ProfileFolder: QuotaReading]> {
        let pair = AsyncStream<[ProfileFolder: QuotaReading]>.makeStream()
        subscribers.append(pair.continuation)
        pair.continuation.yield(values)
        return pair.stream
    }
    func currentReadings() -> [ProfileFolder: QuotaReading] { values }
    func replaceProfiles(_ profiles: [QuotaProfile]) { replacements.append(profiles) }
    func refresh(_ folders: [ProfileFolder], force: Bool) async {
        refreshes.append((folders, force))
        await refreshHook?()
    }
    func refreshWithResult(_ folders: [ProfileFolder], force: Bool) async -> [ProfileFolder: Bool] {
        await refresh(folders, force: force)
        return refreshResults
    }
    func setRefreshResults(_ values: [ProfileFolder: Bool]) { refreshResults = values }
    func setRefreshHook(_ hook: @escaping @Sendable () async -> Void) { refreshHook = hook }
    func refreshVisible(_ folders: [ProfileFolder]) { visible.append(folders) }
    func startPeriodicRefresh(current: ProfileFolder?) { currents.append(current) }
    func stopPeriodicRefresh() { stops += 1 }
    func accountDetails(for profile: QuotaProfile) throws -> AccountRecord {
        detailCalls.append(profile)
        return try details.get()
    }
    func setDetails(_ value: Result<AccountRecord, QuotaFailure>) { details = value }
    func push(_ values: [ProfileFolder: QuotaReading]) {
        self.values = values
        for subscriber in subscribers { subscriber.yield(values) }
    }
}

struct EngineHarness: Sendable {
    let scratch: ScratchDirectory
    let world: SandboxWorld
    let clock: TestClock
    let store: StateStore
    let process = FakeProcessController()
    let inspector = FakeTaskInspector()
    let cookies = FakeCookieReader()
    let quota = FakeEngineQuota()
    let login = FakeLoginItems()
    let revealer = FakeFileRevealer()
    let monitor = FakeLaunchMonitor()
    let engine: CompanionEngine
    let profiles: [ProfileSnapshot]

    /// `flagless` names running profiles opened without `--user-data-dir`, as from the Dock.
    /// Registered accounts come with compaction on, as an existing user who turned it on has it.
    init(autoSync: Bool = true, autoSwitch: Bool = false, autoCompact: Bool = true, register: Bool = true,
         active: String = "Claude", running: [String] = ["Claude"], flagless: Set<String> = [],
         clock: TestClock = TestClock(), nativeRuntimeInspector: (any NativeRuntimeInspecting)? = nil,
         plugin: any ClaudeCodePluginInstalling = ReadyClaudeCodePlugin(), claudeFound: Bool = true) async throws {
        scratch = try ScratchDirectory()
        world = try SandboxFixture.standard().materialize(at: scratch.root)
        self.clock = clock
        let log = CompanionLog(paths: world.paths, clock: clock)
        store = StateStore(paths: world.paths, log: log, clock: clock)
        profiles = try ProfileScanner(paths: world.paths).scan().profiles
        if register {
            let registered = profiles.map { ManagedAccount(folder: $0.folder, displayName: $0.folder.name, addedAt: clock.now()) }
            let folder = try ProfileFolder(active)
            try await store.update { @Sendable state in
                state.accounts = registered; state.activeFolder = folder
                state.settings.autoSyncOnSwitch = autoSync; state.settings.autoSwitchOnQuota = autoSwitch
                state.settings.autoCompactOnLowQuota = autoCompact
            }
        }
        process.simulateTransitions()
        let builtWorld = world
        process.setInstances(running.enumerated().map { index, name in
            ClaudeInstance(pid: Int32(index + 10), profileDirectory: builtWorld.profileDirectory(name),
                hasExplicitProfileFlag: !flagless.contains(name), startedAt: clock.now(), executableURL: builtWorld.paths.claudeAppPath)
        })
        engine = CompanionEngine(paths: world.paths, processes: process, tasks: inspector,
            cookies: cookies, quota: quota, accountDetails: quota, loginItems: login, fileRevealer: revealer,
            launchMonitor: monitor, executable: scratch.root.appending(path: "CCRelay"), clock: clock,
            automaticallyPoll: false, nativeRuntimeInspector: nativeRuntimeInspector, plugin: plugin,
            claudeFound: claudeFound)
    }

    func profile(_ name: String) throws -> ProfileSnapshot {
        try XCTUnwrap(profiles.first { $0.folder.name == name })
    }
    func folder(_ name: String) throws -> ProfileFolder { try ProfileFolder(name) }
    /// The app log's lines so far that contain `text`.
    func logLines(containing text: String) throws -> [String] {
        let url = world.paths.companionDataDirectory.appending(path: "Logs/cc-relay.log")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init).filter { $0.contains(text) }
    }
    func start() async { await engine.start() }
    func cleanup() async { await engine.stop(); scratch.cleanup() }
    func snapshot() async -> CompanionSnapshot { await engine.currentSnapshot() }
    func sessionFile(_ profile: ProfileSnapshot, id: String) throws -> URL {
        profile.url.appending(path: try XCTUnwrap(profile.readableBucket).relativePath).appending(path: id + ".json")
    }
    func writeSignIn(folder: ProfileFolder, account: String = "99999999-9999-4999-8999-999999999999",
                     org: String = "99999999-9999-4999-8999-999999999991") throws {
        let url = world.profileDirectory(folder.name)
        try AtomicFile.write(JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": account,
            "dxt:allowlistLastUpdated:" + org: SandboxFixture.ID.activeStamp]), to: url.appending(path: "config.json"))
        cookies.setCookie(EncryptedCookie(hostKey: ".claude.ai", encryptedValue: Data([1]), databaseVersion: 0), for: url)
    }
}

/// A close that stays under way until the test lets it end, however far the test clock runs.
actor HeldClose {
    private(set) var entered = false
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?

    func hold() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }
}

func eventually(_ body: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if await body() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}

func engineUnwrap<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }

extension Array where Element == Banner {
    /// Whether these banners pause automatic switching for `reason`, whatever time they name.
    func paused(_ reason: AutoSwitchPauseReason) -> Bool {
        contains { if case .autoSwitchPaused(let shown, _) = $0 { shown == reason } else { false } }
    }

    /// When the paused automatic switching tries again, as its banner says.
    var pauseRetry: Date? {
        lazy.compactMap { if case .autoSwitchPaused(_, let retryAt) = $0 { retryAt } else { nil } }.first
    }
}
