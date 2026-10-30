import Foundation

/// Where Claude is installed. People keep it outside /Applications or rename it, so a candidate
/// counts by the bundle identifier in its Info.plist, never by its name.
public enum ClaudeAppLocation {
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"

    /// The first candidate that is Claude, or nil when none is.
    public static func resolve(_ candidates: [URL?]) -> URL? {
        candidates.lazy.compactMap { $0 }.first(where: isClaude)
    }

    static func isClaude(_ bundle: URL) -> Bool {
        let plist = bundle.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist), data.count < 1_000_000,
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return info["CFBundleIdentifier"] as? String == bundleIdentifier
    }
}
