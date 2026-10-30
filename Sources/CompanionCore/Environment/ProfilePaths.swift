import Foundation

public enum ProfilePaths {
    public static func canonical(_ url: URL) -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return URL(fileURLWithPath: resolved.path, isDirectory: true)
    }

    public static func same(_ a: URL, _ b: URL) -> Bool {
        canonical(a).path == canonical(b).path
    }
}

public enum AppIdentity {
    public static let bundleIdentifier = "local.cc-relay"
}
