import Foundation

/// CC-Relay's plugin inside Claude Code, which carries work over after a switch and compacts long
/// conversations. The app carries a copy and installs it when a feature that needs it is turned on.
public protocol ClaudeCodePluginInstalling: Sendable {
    /// Installed, switched on, and Claude Code set to load its hooks.
    func isReady() async -> Bool
    /// Installed, but Claude Code still records an older copy than the app's, or reads it from elsewhere.
    func needsUpdate() async -> Bool
    /// Installs the app's copy, or brings an installed one up to it, and turns on what it needs.
    /// Throws a `PluginInstallFailure`.
    func install() async throws
}

public extension ClaudeCodePluginInstalling {
    func needsUpdate() async -> Bool { false }
}

public enum PluginInstallFailure: Error, Equatable, Sendable {
    /// No Claude Code program was found to install with.
    case claudeCodeMissing
    /// Claude Code's `settings.json` could not be read or changed safely.
    case settingsUnusable
    /// A step failed, or the plugin was still not ready afterwards.
    case notFinished
}

/// Ready, and installs nothing: for previews and tests that are not about the plugin.
public struct ReadyClaudeCodePlugin: ClaudeCodePluginInstalling {
    public init() {}
    public func isReady() async -> Bool { true }
    public func install() async throws {}
}

/// What Claude Code keeps about the plugin in its folder, `~/.claude`.
public struct ClaudeCodePluginFiles: Sendable {
    public static let pluginID = "cc-relay@cc-relay-local"
    public static let marketplace = "cc-relay-local"
    /// Claude Code loads a plugin's hooks module only with this set to "1" in its settings' `env`.
    public static let hooksVariable = "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS"

    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    public var settingsFile: URL { home.appending(path: "settings.json") }
    public var installedFile: URL { home.appending(path: "plugins/installed_plugins.json") }

    public var isReady: Bool {
        let settings = Self.object(settingsFile)
        return (settings?["enabledPlugins"] as? [String: Any])?[Self.pluginID] as? Bool == true
            && (settings?["env"] as? [String: Any])?[Self.hooksVariable] as? String == "1"
            && isInstalled
    }

    public var isInstalled: Bool {
        (Self.object(installedFile)?["plugins"] as? [String: Any])?[Self.pluginID] != nil
    }

    /// The version Claude Code records as installed for the user.
    public var installedVersion: String? {
        guard let entries = (Self.object(installedFile)?["plugins"] as? [String: Any])?[Self.pluginID] as? [[String: Any]]
        else { return nil }
        return (entries.first { $0["scope"] as? String == "user" } ?? entries.first)?["version"] as? String
    }

    /// Whether Claude Code reads the plugin from `marketplace`, the app's folder of plugins.
    public func readsFrom(_ marketplace: URL) -> Bool {
        guard let entry = Self.object(home.appending(path: "plugins/known_marketplaces.json"))?[Self.marketplace] as? [String: Any],
              let source = entry["source"] as? [String: Any], source["source"] as? String == "directory",
              let path = source["path"] as? String else { return false }
        return ProfilePaths.same(URL(fileURLWithPath: path), marketplace)
    }

    /// Installed, read from the app's folder, and recorded at the version of the copy there. After an
    /// app update the record stays older until Claude Code's own update runs.
    public func isCurrent(with marketplace: URL) -> Bool {
        let carried = Self.object(marketplace.appending(path: "cc-relay/.claude-plugin/plugin.json"))?["version"] as? String
        return isInstalled && readsFrom(marketplace) && carried != nil && installedVersion == carried
    }

    /// Sets the hooks variable in `settings.json` and keeps everything else in it. The file as it was is
    /// copied beside it first, as `settings.json.cc-relay-backup-<time>`.
    public func enableHooks(now: Date) throws {
        try change(now: now) { settings in
            var environment: [String: Any] = [:]
            if let value = settings["env"] {
                guard let existing = value as? [String: Any] else { throw PluginInstallFailure.settingsUnusable }
                environment = existing
            }
            guard environment[Self.hooksVariable] as? String != "1" else { return false }
            environment[Self.hooksVariable] = "1"
            settings["env"] = environment
            return true
        }
    }

    /// Reads `settings.json` (none counts as empty), lets `body` change it, and writes it back when it says it
    /// did, after copying the old file beside it. A link, a folder or anything but a JSON object is refused.
    func change(now: Date, _ body: (inout [String: Any]) throws -> Bool) throws {
        let manager = FileManager.default
        var settings: [String: Any] = [:]
        let existing = (try? manager.attributesOfItem(atPath: settingsFile.path))?[.type] as? FileAttributeType
        if let existing {
            guard existing == .typeRegular, let data = try? Data(contentsOf: settingsFile),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { throw PluginInstallFailure.settingsUnusable }
            settings = object
        }
        guard try body(&settings) else { return }
        do {
            if existing != nil { try manager.copyItem(at: settingsFile, to: backup(now: now)) }
            let data = try JSONSerialization.data(withJSONObject: settings,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try AtomicFile.write(data + Data("\n".utf8), to: settingsFile)
        } catch { throw PluginInstallFailure.settingsUnusable }
    }

    private func backup(now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "settings.json.cc-relay-backup-" + formatter.string(from: now)
        var candidate = home.appending(path: base), count = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = home.appending(path: base + "-\(count)")
            count += 1
        }
        return candidate
    }

    public static func object(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
