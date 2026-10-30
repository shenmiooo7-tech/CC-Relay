import CompanionCore
import CompanionPlatform
import Foundation

enum AppAssemblyError: Error { case liveDuringTests }

struct AppServices: Sendable {
    let paths: AppPaths
    let processes: any ClaudeProcessControlling
    let quota: QuotaService
    let engine: CompanionEngine

    static func current(onQuit: @escaping @Sendable () async -> Void) throws -> AppServices {
        let paths = AppEnvironment.current()
        if let raw = ProcessInfo.processInfo.environment[AppEnvironment.sandboxVariable],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try sandbox(root: paths.home.deletingLastPathComponent(), onQuit: onQuit)
        }
        return try live(paths: paths, onQuit: onQuit)
    }

    static func live(paths: AppPaths, onQuit: @escaping @Sendable () async -> Void = {}) throws -> AppServices {
        // This must remain a runtime refusal in release builds as well as debug builds.
        guard ProcessInfo.processInfo.environment[SafetyTripwire.testVariable] == nil else {
            throw AppAssemblyError.liveDuringTests
        }
        try SafetyTripwire.assertLiveActionsAllowed()
        // Claude may be outside /Applications or renamed: it is found by its identity.
        let claude = ClaudeAppLocation.resolve([paths.claudeAppPath, LiveClaudeApp.registered()])
        let paths = claude.map(paths.locatingClaude) ?? paths
        let versions = try ClaudeVersionReader(paths: paths).versions()
        return assemble(paths: paths, processes: LiveClaudeProcessController(paths: paths),
            tasks: LiveCodeTaskInspector(paths: paths),
            cookies: LiveSessionCookieReader(), key: LiveSafeStorageKeyProvider(), transport: URLSessionHTTPTransport(),
            login: AppServiceLoginItem(paths: paths), revealer: FinderRevealer(),
            monitor: LiveClaudeLaunchMonitor(paths: paths), versions: versions, clock: SystemClock(),
            automaticallyPoll: true,
            nativeRuntimeInspector: LiveNativeRuntimeInspector(paths: paths),
            nativeConversationOpener: LiveNativeConversationOpener(paths: paths),
            plugin: LiveClaudeCodePlugin(paths: paths, marketplace: (Bundle.main.resourceURL
                ?? Bundle.main.bundleURL.appending(path: "Contents/Resources")).appending(path: "Plugins")),
            claudeFound: claude != nil, onQuit: onQuit)
    }

    static func sandbox(root: URL, processEnvironment: [String: String] = [:],
                        clock: any CompanionCore.Clock = SystemClock(), automaticallyPoll: Bool = true,
                        verificationTimeout: Duration = .seconds(30),
                        onQuit: @escaping @Sendable () async -> Void = {}) throws -> AppServices {
        let executable = SandboxWorldGenerator.fakeClaudeExecutable(root: root)
        return assemble(paths: .sandbox(root: root),
            processes: SandboxClaudeProcessController(root: root, fakeClaudeExecutable: executable,
                environment: processEnvironment, clock: clock, verificationTimeout: verificationTimeout),
            tasks: SandboxTaskInspector(root: root),
            cookies: SandboxSessionCookieReader(root: root),
            key: FixedSafeStorageKeyProvider(password: ChromiumCookieEncryptor.fixturePassword),
            transport: SandboxHTTPTransport(root: root), login: SandboxLoginItem(root: root),
            revealer: SandboxFileRevealer(root: root), monitor: SandboxLaunchMonitor(root: root, fakeClaudeExecutable: executable, clock: clock),
            versions: try SandboxVersionReader(root: root).versions(), clock: clock,
            automaticallyPoll: automaticallyPoll, plugin: SandboxClaudeCodePlugin(root: root), onQuit: onQuit)
    }

    private static func assemble(paths: AppPaths, processes: any ClaudeProcessControlling,
                                 tasks: any CodeTaskInspecting,
                                 cookies: any SessionCookieReading, key: any SafeStorageKeyProviding,
                                 transport: any HTTPTransport, login: any LoginItemManaging,
                                 revealer: any FileRevealing, monitor: any ClaudeLaunchMonitoring,
                                 versions: ClaudeVersions, clock: any CompanionCore.Clock,
                                 automaticallyPoll: Bool,
                                 nativeRuntimeInspector: (any NativeRuntimeInspecting)? = nil,
                                 nativeConversationOpener: (any NativeConversationOpening)? = nil,
                                 plugin: any ClaudeCodePluginInstalling,
                                 claudeFound: Bool = true,
                                 onQuit: @escaping @Sendable () async -> Void) -> AppServices {
        let log = CompanionLog(paths: paths, clock: clock)
        let quota = QuotaService(cookies: cookies, safeStorage: key, transport: transport,
            cache: QuotaCacheStore(paths: paths, log: log, clock: clock), clock: clock,
            userAgent: ClaudeUserAgent.headerValue(claude: versions.claude, electron: versions.electron), log: log)
        let engine = CompanionEngine(paths: paths, processes: processes, tasks: tasks,
            cookies: cookies, quota: quota, accountDetails: quota, loginItems: login, fileRevealer: revealer,
            launchMonitor: monitor, executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
            clock: clock, appVersion: AppVersion.display(info: Bundle.main.infoDictionary),
            automaticallyPoll: automaticallyPoll, log: log,
            nativeRuntimeInspector: nativeRuntimeInspector,
            nativeConversationOpener: nativeConversationOpener, plugin: plugin, claudeFound: claudeFound,
            onQuit: onQuit)
        return AppServices(paths: paths, processes: processes, quota: quota, engine: engine)
    }
}
