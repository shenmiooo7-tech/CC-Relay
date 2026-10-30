import AppKit
import CompanionCore
import Foundation

public struct FinderRevealer: FileRevealing {
    public init() {}
    public func reveal(_ url: URL) async throws {
        try SafetyTripwire.assertLiveActionsAllowed()
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { throw FileRevealError.revealFailed }
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

/// The Claude app macOS knows by its bundle identifier, wherever it is installed and whatever its name.
public enum LiveClaudeApp {
    public static func registered() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: ClaudeAppLocation.bundleIdentifier)
    }
}

public struct ClaudeVersions: Equatable, Sendable {
    public let claude: String?
    public let electron: String?
}

public struct ClaudeVersionReader: Sendable {
    private let paths: AppPaths
    public init(paths: AppPaths) { self.paths = paths }

    public func versions() throws -> ClaudeVersions {
        try SafetyTripwire.assertLiveActionsAllowed()
        return Self.readBundle(paths.claudeAppURL)
    }

    static func readBundle(_ bundle: URL) -> ClaudeVersions {
        let electron = bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return ClaudeVersions(claude: version(bundle.appendingPathComponent("Contents/Info.plist")),
            electron: version(electron.appendingPathComponent("Resources/Info.plist")) ??
                version(electron.appendingPathComponent("Versions/A/Resources/Info.plist")))
    }

    private static func version(_ plist: URL) -> String? {
        guard let data = try? Data(contentsOf: plist),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let value = dictionary["CFBundleShortVersionString"] as? String ?? dictionary["CFBundleVersion"] as? String
        guard let value, !value.isEmpty, value.utf8.allSatisfy({ (45...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
        else { return nil }
        return value
    }
}
