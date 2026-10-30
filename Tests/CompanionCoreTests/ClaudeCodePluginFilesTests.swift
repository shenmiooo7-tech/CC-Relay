import Foundation
import XCTest
@testable import CompanionCore

final class ClaudeCodePluginFilesTests: XCTestCase {
    private var home: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "claude-code-plugin-\(UUID().uuidString)/.claude")
        try FileManager.default.createDirectory(at: home.appending(path: "plugins"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func testReadyNeedsTheInstallTheSwitchAndTheHooksVariable() throws {
        let files = ClaudeCodePluginFiles(home: home)
        XCTAssertFalse(files.isReady)
        try write(["plugins": [ClaudeCodePluginFiles.pluginID: [["scope": "user"]]]], to: files.installedFile)
        try write(["enabledPlugins": [ClaudeCodePluginFiles.pluginID: true]], to: files.settingsFile)
        XCTAssertTrue(files.isInstalled)
        XCTAssertFalse(files.isReady, "without the hooks variable Claude Code does not load the plugin's hooks")
        try write(["enabledPlugins": [ClaudeCodePluginFiles.pluginID: false],
                   "env": [ClaudeCodePluginFiles.hooksVariable: "1"]], to: files.settingsFile)
        XCTAssertFalse(files.isReady, "a disabled plugin is not ready")
        try write(["enabledPlugins": [ClaudeCodePluginFiles.pluginID: true],
                   "env": [ClaudeCodePluginFiles.hooksVariable: "1"]], to: files.settingsFile)
        XCTAssertTrue(files.isReady)
    }

    func testTurningTheHooksOnKeepsTheRestAndCopiesTheOldFileFirst() throws {
        let files = ClaudeCodePluginFiles(home: home)
        let original: [String: Any] = ["model": "example", "env": ["OTHER": "x"], "permissions": ["allow": ["Bash(ls)"]]]
        try write(original, to: files.settingsFile)
        let before = try Data(contentsOf: files.settingsFile)
        try files.enableHooks(now: now)
        let settings = try XCTUnwrap(ClaudeCodePluginFiles.object(files.settingsFile))
        XCTAssertEqual(settings["model"] as? String, "example")
        XCTAssertEqual(settings["env"] as? [String: String], ["OTHER": "x", ClaudeCodePluginFiles.hooksVariable: "1"])
        XCTAssertEqual((settings["permissions"] as? [String: [String]])?["allow"], ["Bash(ls)"])
        let backups = try FileManager.default.contentsOfDirectory(atPath: home.path).filter { $0.hasPrefix("settings.json.cc-relay-backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: home.appending(path: backups[0])), before)

        try files.enableHooks(now: now)
        let again = try FileManager.default.contentsOfDirectory(atPath: home.path).filter { $0.hasPrefix("settings.json.cc-relay-backup-") }
        XCTAssertEqual(again.count, 1, "nothing to change, so no second copy")
    }

    func testNoSettingsFileIsStartedWithoutACopy() throws {
        let files = ClaudeCodePluginFiles(home: home)
        try files.enableHooks(now: now)
        XCTAssertEqual(ClaudeCodePluginFiles.object(files.settingsFile)?["env"] as? [String: String],
                       [ClaudeCodePluginFiles.hooksVariable: "1"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path).sorted(), ["plugins", "settings.json"])
    }

    func testALinkOrAnUnreadableFileIsLeftAlone() throws {
        let files = ClaudeCodePluginFiles(home: home)
        let elsewhere = home.deletingLastPathComponent().appending(path: "elsewhere.json")
        try Data("{}".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: files.settingsFile, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try files.enableHooks(now: now)) { XCTAssertEqual($0 as? PluginInstallFailure, .settingsUnusable) }
        XCTAssertEqual(try Data(contentsOf: elsewhere), Data("{}".utf8))

        try FileManager.default.removeItem(at: files.settingsFile)
        for text in ["not json", "[1]", "{\"env\": \"text\"}"] {
            try Data(text.utf8).write(to: files.settingsFile)
            XCTAssertThrowsError(try files.enableHooks(now: now), text) {
                XCTAssertEqual($0 as? PluginInstallFailure, .settingsUnusable)
            }
            XCTAssertEqual(try String(contentsOf: files.settingsFile, encoding: .utf8), text)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: home.path).contains { $0.contains("backup") })
    }

    func testCurrentMeansReadFromTheAppsFolderAtItsVersion() throws {
        let files = ClaudeCodePluginFiles(home: home)
        let app = home.deletingLastPathComponent().appending(path: "App/Plugins")
        try FileManager.default.createDirectory(at: app.appending(path: "cc-relay/.claude-plugin"), withIntermediateDirectories: true)
        try write(["name": "cc-relay", "version": "0.7.8"], to: app.appending(path: "cc-relay/.claude-plugin/plugin.json"))
        let marketplaces = home.appending(path: "plugins/known_marketplaces.json")
        XCTAssertFalse(files.isCurrent(with: app), "nothing is installed")
        try write(["cc-relay-local": ["source": ["source": "directory", "path": app.path]]], to: marketplaces)
        try write(["plugins": [ClaudeCodePluginFiles.pluginID: [["scope": "user", "version": "0.7.7"]]]], to: files.installedFile)
        XCTAssertTrue(files.readsFrom(app))
        XCTAssertEqual(files.installedVersion, "0.7.7")
        XCTAssertFalse(files.isCurrent(with: app), "an app update leaves Claude Code's record older")
        try write(["plugins": [ClaudeCodePluginFiles.pluginID: [["scope": "user", "version": "0.7.8"]]]], to: files.installedFile)
        XCTAssertTrue(files.isCurrent(with: app))
        let elsewhere = home.deletingLastPathComponent().appending(path: "Elsewhere/Plugins")
        try write(["cc-relay-local": ["source": ["source": "directory", "path": elsewhere.path]]], to: marketplaces)
        XCTAssertFalse(files.readsFrom(app))
        XCTAssertFalse(files.isCurrent(with: app), "read from another folder, it is not the app's copy")
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}
