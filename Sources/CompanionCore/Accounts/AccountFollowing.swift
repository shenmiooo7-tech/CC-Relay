import Foundation

/// Which managed account Claude has open when it is not the remembered current one: another tool
/// or the user switched Claude without this app.
enum AccountFollowing {
    /// Nil keeps the remembered account: it is open, or Claude has no managed account open.
    /// Only launches with a profile flag can move the current account. A flagless launch of the
    /// default account belongs to auto-correct, unless auto-correct is off (`flaglessCounts`).
    static func account(open running: [ClaudeInstance], accounts: [ManagedAccount], active: ProfileFolder?,
                        flaglessCounts: Bool, directory: (ProfileFolder) -> URL) -> ProfileFolder? {
        if let active, running.contains(where: { ProfilePaths.same($0.profileDirectory, directory(active)) }) { return nil }
        let candidates = running.filter { $0.hasExplicitProfileFlag || flaglessCounts }
            .sorted { $0.startedAt > $1.startedAt }
        for instance in candidates {
            if let account = accounts.first(where: { ProfilePaths.same(directory($0.folder), instance.profileDirectory) }) {
                return account.folder
            }
        }
        return nil
    }
}
