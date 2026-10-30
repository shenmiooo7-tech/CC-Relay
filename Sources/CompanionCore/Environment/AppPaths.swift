import Foundation

/// Every filesystem root the app is allowed to touch.
///
/// Live roots follow a real home directory. Sandbox roots use the same relative
/// layout under `<root>/home`. The Claude bundle is in `/Applications` on most
/// Macs, so the sandbox mirrors that directory at `<root>/Applications` and
/// never points at the installed copy; the app moves it where it found Claude.
public struct AppPaths: Equatable, Sendable {
    public let home: URL
    public let claudeProfilesRoot: URL
    public let companionDataDirectory: URL
    public let launchAgentsDirectory: URL
    public let claudeCLIHome: URL
    public let claudeAppPath: URL
    /// Same bundle as `claudeAppPath`.
    public var claudeAppURL: URL { claudeAppPath }

    public static func live(home: URL) -> AppPaths {
        layout(
            home: home,
            applicationsDirectory: URL(fileURLWithPath: "/Applications", isDirectory: true)
        )
    }

    public static func sandbox(root: URL) -> AppPaths {
        let base = directory(root)
        return layout(
            home: base.appending(path: "home", directoryHint: .isDirectory),
            applicationsDirectory: base.appending(path: "Applications", directoryHint: .isDirectory)
        )
    }

    /// The same roots, with Claude at `app`.
    public func locatingClaude(at app: URL) -> AppPaths {
        AppPaths(home: home, claudeProfilesRoot: claudeProfilesRoot, companionDataDirectory: companionDataDirectory,
                 launchAgentsDirectory: launchAgentsDirectory, claudeCLIHome: claudeCLIHome,
                 claudeAppPath: Self.directory(app))
    }

    private init(
        home: URL,
        claudeProfilesRoot: URL,
        companionDataDirectory: URL,
        launchAgentsDirectory: URL,
        claudeCLIHome: URL,
        claudeAppPath: URL
    ) {
        self.home = home
        self.claudeProfilesRoot = claudeProfilesRoot
        self.companionDataDirectory = companionDataDirectory
        self.launchAgentsDirectory = launchAgentsDirectory
        self.claudeCLIHome = claudeCLIHome
        self.claudeAppPath = claudeAppPath
    }

    private static func layout(home: URL, applicationsDirectory: URL) -> AppPaths {
        let home = directory(home)
        let applicationSupport = home
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
        let applications = directory(applicationsDirectory)
        return AppPaths(
            home: home,
            claudeProfilesRoot: applicationSupport,
            companionDataDirectory: applicationSupport.appending(
                path: "CC-Relay",
                directoryHint: .isDirectory
            ),
            launchAgentsDirectory: home
                .appending(path: "Library", directoryHint: .isDirectory)
                .appending(path: "LaunchAgents", directoryHint: .isDirectory),
            claudeCLIHome: home.appending(path: ".claude", directoryHint: .isDirectory),
            claudeAppPath: applications.appending(path: "Claude.app", directoryHint: .isDirectory)
        )
    }

    private static func directory(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: true)
    }
}

public enum AppEnvironment {
    /// When this variable holds a non-empty path, the app stays inside that sandbox.
    public static let sandboxVariable = "CC_RELAY_SANDBOX"

    public static func current(processInfo: ProcessInfo = .processInfo) -> AppPaths {
        let environment = processInfo.environment
        if let raw = environment[sandboxVariable] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return .sandbox(root: URL(fileURLWithPath: trimmed, isDirectory: true))
            }
        }
        // HOME is the process home. Every other root is derived from it here.
        let homePath = environment["HOME"].flatMap(nonEmptyTrimmed)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return .live(home: URL(fileURLWithPath: homePath, isDirectory: true))
    }

    private static func nonEmptyTrimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
