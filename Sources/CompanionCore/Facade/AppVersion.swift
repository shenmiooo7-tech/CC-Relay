import Foundation

/// The version Settings and the log show: the release number, plus the source revision the build was
/// made from when the build recorded one, as "0.1.0 (5d42a6f)". A "+" after the revision marks a build
/// with changes that were not committed.
public enum AppVersion {
    /// The Info.plist key `scripts/build-app.sh` writes the revision to.
    public static let revisionKey = "CompanionRevision"

    public static func display(info: [String: Any]?) -> String {
        let release = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let revision = (info?[revisionKey] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return revision.isEmpty ? release : "\(release) (\(revision))"
    }
}
