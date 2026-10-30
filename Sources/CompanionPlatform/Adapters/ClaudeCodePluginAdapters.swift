import CompanionCore
import Foundation

/// Installs the app's copy of the plugin with Claude Code's own commands: the copy of Claude Code that
/// Claude Desktop keeps in an account's folder, or else one installed on its own.
public struct LiveClaudeCodePlugin: ClaudeCodePluginInstalling {
    private let paths: AppPaths
    /// The app's `Contents/Resources/Plugins`, the marketplace Claude Code reads the plugin from.
    private let marketplace: URL
    private let runner: any SubprocessRunning

    public init(paths: AppPaths, marketplace: URL, runner: any SubprocessRunning = SubprocessRunner()) {
        self.paths = paths
        self.marketplace = marketplace
        self.runner = runner
    }

    public func isReady() async -> Bool {
        ClaudeCodePluginFiles(home: paths.claudeCLIHome).isReady
    }

    public func needsUpdate() async -> Bool {
        let files = ClaudeCodePluginFiles(home: paths.claudeCLIHome)
        return files.isInstalled && !files.isCurrent(with: marketplace)
    }

    public func install() async throws {
        try SafetyTripwire.assertLiveActionsAllowed()
        guard let program = Self.claudeCode(paths: paths) else { throw PluginInstallFailure.claudeCodeMissing }
        try await install(using: program)
    }

    func install(using program: URL) async throws {
        let files = ClaudeCodePluginFiles(home: paths.claudeCLIHome)
        try files.enableHooks(now: Date())
        // Adding the app's folder under the marketplace's name again points it there and keeps what
        // is installed from it.
        if !files.readsFrom(marketplace) { try await run(program, ["plugin", "marketplace", "add", marketplace.path]) }
        if !files.isInstalled { try await run(program, ["plugin", "install", ClaudeCodePluginFiles.pluginID]) }
        else if !files.isCurrent(with: marketplace) {
            try await run(program, ["plugin", "update", ClaudeCodePluginFiles.pluginID, "--scope", "user"])
        }
        if !files.isReady { try await run(program, ["plugin", "enable", ClaudeCodePluginFiles.pluginID]) }
        guard files.isReady, files.isCurrent(with: marketplace) else { throw PluginInstallFailure.notFinished }
    }

    /// Started through `env`, so that Claude Code sees the hooks variable from its first moment, as the
    /// project's install script gives it.
    private func run(_ program: URL, _ arguments: [String]) async throws {
        let result = try? await runner.run(executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["\(ClaudeCodePluginFiles.hooksVariable)=1", program.path] + arguments,
            timeout: 120, outputLimit: 65_536)
        guard let result, result.exitStatus == 0, !result.timedOut else { throw PluginInstallFailure.notFinished }
    }

    /// The newest Claude Code that Claude Desktop keeps under an account's folder
    /// (`claude-code/<version>/<build>/claude.app`), else one installed on its own.
    static func claudeCode(paths: AppPaths) -> URL? {
        let manager = FileManager.default
        func children(_ url: URL) -> [URL] {
            (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        }
        var found: [(version: [Int], program: URL)] = []
        for profile in children(paths.claudeProfilesRoot) where profile.lastPathComponent.hasPrefix("Claude") {
            for version in children(profile.appending(path: "claude-code")) {
                let parts = version.lastPathComponent.split(separator: ".").map { Int($0) }
                guard parts.count > 1, !parts.contains(nil) else { continue }
                for build in children(version) {
                    let program = build.appending(path: "claude.app/Contents/MacOS/claude")
                    if manager.isExecutableFile(atPath: program.path) { found.append((parts.compactMap { $0 }, program)) }
                }
            }
        }
        if let newest = found.max(by: { $0.version.lexicographicallyPrecedes($1.version) }) { return newest.program }
        return [paths.home.appending(path: ".local/bin/claude"), paths.home.appending(path: ".claude/local/claude"),
                URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")]
            .first { manager.isExecutableFile(atPath: $0.path) }
    }
}

/// Installs nothing real: it writes what Claude Code would record, inside the sandbox.
public struct SandboxClaudeCodePlugin: ClaudeCodePluginInstalling {
    private let boundary: SandboxBoundary
    private let files: ClaudeCodePluginFiles

    public init(root: URL) {
        boundary = SandboxBoundary(root: root)
        files = ClaudeCodePluginFiles(home: AppPaths.sandbox(root: root).claudeCLIHome)
    }

    public func isReady() async -> Bool {
        files.isReady
    }

    public func install() async throws {
        try boundary.check(files.settingsFile)
        try boundary.check(files.installedFile)
        try files.enableHooks(now: Date())
        var settings = ClaudeCodePluginFiles.object(files.settingsFile) ?? [:]
        var enabled = settings["enabledPlugins"] as? [String: Any] ?? [:]
        enabled[ClaudeCodePluginFiles.pluginID] = true
        settings["enabledPlugins"] = enabled
        let installed: [String: Any] = ["version": 2, "plugins": [ClaudeCodePluginFiles.pluginID: [["scope": "user"]]]]
        do {
            try AtomicFile.write(JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), to: files.settingsFile)
            try AtomicFile.write(JSONSerialization.data(withJSONObject: installed, options: [.sortedKeys]), to: files.installedFile)
        } catch { throw PluginInstallFailure.notFinished }
    }
}
