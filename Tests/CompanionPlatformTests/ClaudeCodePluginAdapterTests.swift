import Foundation
import XCTest
@testable import CompanionCore
@testable import CompanionPlatform

final class ClaudeCodePluginAdapterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "cc-relay-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Claude Desktop keeps a Claude Code for each account; the newest version wins, compared as numbers.
    func testTheNewestClaudeCodeThatDesktopKeepsIsUsed() throws {
        _ = try program(profile: "Claude", version: "2.1.9", build: "first")
        let newest = try program(profile: "Claude_other", version: "2.1.10", build: "second")
        _ = try program(profile: "Claude", version: "next", build: "third")
        XCTAssertEqual(LiveClaudeCodePlugin.claudeCode(paths: .sandbox(root: root))?.resolvingSymlinksInPath().path,
                       newest.resolvingSymlinksInPath().path)
    }

    func testTheSandboxInstallWritesWhatClaudeCodeWouldInsideTheSandbox() async throws {
        let plugin = SandboxClaudeCodePlugin(root: root)
        let before = await plugin.isReady()
        XCTAssertFalse(before)
        try await plugin.install()
        let after = await plugin.isReady()
        XCTAssertTrue(after)
        let files = ClaudeCodePluginFiles(home: AppPaths.sandbox(root: root).claudeCLIHome)
        XCTAssertTrue(files.settingsFile.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path))
    }

    /// After an app update Claude Code still records the older copy: its own update brings the record
    /// up to the app's, after pointing the marketplace back at the app's folder when it reads another.
    func testAnInstalledPluginIsBroughtUpToTheAppsCopy() async throws {
        let id = ClaudeCodePluginFiles.pluginID
        for scenario in ["fresh", "older", "moved", "current"] {
            let paths = AppPaths.sandbox(root: root.appending(path: scenario))
            let app = root.appending(path: "\(scenario)/App/Plugins")
            try json(["name": "cc-relay", "version": "0.7.8"], to: app.appending(path: "cc-relay/.claude-plugin/plugin.json"))
            let files = ClaudeCodePluginFiles(home: paths.claudeCLIHome)
            if scenario != "fresh" {
                let source = scenario == "moved" ? root.appending(path: "Elsewhere/Plugins").path : app.path
                try json(["cc-relay-local": ["source": ["source": "directory", "path": source]]],
                         to: paths.claudeCLIHome.appending(path: "plugins/known_marketplaces.json"))
                try json(["plugins": [id: [["scope": "user", "version": scenario == "current" ? "0.7.8" : "0.7.7"]]]], to: files.installedFile)
                try json(["enabledPlugins": [id: true], "env": [ClaudeCodePluginFiles.hooksVariable: "1"]], to: files.settingsFile)
            }
            let claude = PluginCommandFake(home: paths.claudeCLIHome, app: app)
            let plugin = LiveClaudeCodePlugin(paths: paths, marketplace: app, runner: claude)
            let needed = await plugin.needsUpdate()
            XCTAssertEqual(needed, ["older", "moved"].contains(scenario), scenario)
            try await plugin.install(using: URL(fileURLWithPath: "/fake/claude"))
            let expected: [[String]] = switch scenario {
            case "fresh": [["plugin", "marketplace", "add", app.path], ["plugin", "install", id], ["plugin", "enable", id]]
            case "older": [["plugin", "update", id, "--scope", "user"]]
            case "moved": [["plugin", "marketplace", "add", app.path], ["plugin", "update", id, "--scope", "user"]]
            default: []
            }
            XCTAssertEqual(claude.commands, expected, scenario)
            let after = await plugin.needsUpdate()
            XCTAssertFalse(after, scenario)
            XCTAssertTrue(files.isReady, scenario)
            XCTAssertTrue(files.isCurrent(with: app), scenario)
        }
    }

    private func json(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func program(profile: String, version: String, build: String) throws -> URL {
        let url = AppPaths.sandbox(root: root).claudeProfilesRoot
            .appending(path: "\(profile)/claude-code/\(version)/\(build)/claude.app/Contents/MacOS/claude")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

/// Answers Claude Code's plugin commands the way the real program changes its files.
private final class PluginCommandFake: SubprocessRunning, @unchecked Sendable {
    private let home: URL, app: URL, lock = NSLock()
    private var recorded: [[String]] = []
    var commands: [[String]] { lock.withLock { recorded } }

    init(home: URL, app: URL) { self.home = home; self.app = app }

    func run(executable: URL, arguments: [String], timeout: TimeInterval, outputLimit: Int) async throws -> SubprocessResult {
        // `env HOOKS=1 <claude> plugin …`
        let command = Array(arguments.dropFirst(2))
        lock.withLock { recorded.append(command) }
        let id = ClaudeCodePluginFiles.pluginID
        let files = ClaudeCodePluginFiles(home: home)
        let version = ClaudeCodePluginFiles.object(app.appending(path: "cc-relay/.claude-plugin/plugin.json"))?["version"] as? String
        switch command.prefix(3) {
        case ["plugin", "marketplace", "add"]:
            try write(["cc-relay-local": ["source": ["source": "directory", "path": command[3]]]],
                      to: home.appending(path: "plugins/known_marketplaces.json"))
        case ["plugin", "install", id], ["plugin", "update", id]:
            try write(["plugins": [id: [["scope": "user", "version": version ?? ""]]]], to: files.installedFile)
        case ["plugin", "enable", id]:
            var settings = ClaudeCodePluginFiles.object(files.settingsFile) ?? [:]
            settings["enabledPlugins"] = [id: true]
            try write(settings, to: files.settingsFile)
        default: return SubprocessResult(exitStatus: 1)
        }
        return SubprocessResult(exitStatus: 0)
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}
