import Foundation

/// All close callers share partial-close recovery and the pre-force task check.
public struct ClaudeLifecycle: Sendable {
    let processes: any ClaudeProcessControlling
    let tasks: any CodeTaskInspecting
    let debt: RelaunchDebt
    let paths: AppPaths
    let log: CompanionLog

    public init(processes: any ClaudeProcessControlling, tasks: any CodeTaskInspecting,
                debt: RelaunchDebt, paths: AppPaths, log: CompanionLog) {
        self.processes = processes
        self.tasks = tasks
        self.debt = debt
        self.paths = paths
        self.log = log
    }

    public func close(owing folders: [ProfileFolder], allowForce: Bool = false,
                      instance: ClaudeInstance? = nil) async throws {
        let open = ((try? await processes.runningInstances()) ?? []).compactMap { folder(of: $0.profileDirectory) }
        let added = try await debt.record(folders, open: open)
        do {
            let permission: @Sendable () async -> Bool = { [tasks] in
                if allowForce { return true }
                return await tasks.activity() == .idle
            }
            if let instance {
                _ = try await processes.quit(instance: instance, timeout: .seconds(28), beforeForce: permission)
            } else {
                // Interrupting the tasks was confirmed already: Claude's own quit would ask again.
                _ = try await processes.quitAll(timeout: .seconds(28), immediately: allowForce, beforeForce: permission)
            }
        } catch {
            // A failed close must never leave normal completion or quit owing its launches. What
            // earlier operations still owe stays owed.
            try await debt.drop(added)
            if case ClaudeProcessError.stillRunning(_, let closed, _, _) = error, !closed.isEmpty {
                // The profiles proven closed open again now. One that does not, or whose state
                // cannot be read, stays owed, so the next pickup opens it.
                var unopened: [ProfileFolder] = []
                if let running = try? await processes.runningInstances() {
                    var reopened: [URL] = []
                    for profile in closed where !running.contains(where: { ProfilePaths.same($0.profileDirectory, profile) }) {
                        guard !reopened.contains(where: { ProfilePaths.same($0, profile) }) else { continue }
                        reopened.append(profile)
                        do { _ = try await processes.launch(profile: profile, deepLink: nil) }
                        catch {
                            log.warning(.app, "A profile closed during a failed quit could not be reopened.")
                            if let folder = folder(of: profile) { unopened.append(folder) }
                        }
                    }
                } else {
                    unopened = closed.compactMap { folder(of: $0) }
                }
                if !unopened.isEmpty { _ = try? await debt.record(unopened) }
            }
            throw error
        }
    }

    /// A profile directory's folder when it sits in the profiles root, the only ones a record names.
    private func folder(of profile: URL) -> ProfileFolder? {
        guard ProfilePaths.same(profile.deletingLastPathComponent(), paths.claudeProfilesRoot) else { return nil }
        return try? ProfileFolder(profile.lastPathComponent)
    }

    /// Reopens every owed profile. The target failing throws, and so does a bystander in `required`
    /// (the profiles the caller itself closed); one owed from an earlier operation only logs.
    public func relaunchOwed(target: ProfileFolder? = nil, deepLink: URL? = nil, required: [ProfileFolder] = []) async throws {
        let owed = try await debt.claim()
        var targetFailed = false
        for folder in owed {
            let opened = await reopen(folder, deepLink: folder == target ? deepLink : nil)
            await debt.settle(folder, opened: opened)
            guard !opened else { continue }
            if folder == target { targetFailed = true }
            else {
                log.warning(.app, "A bystander profile could not be reopened.")
                if required.contains(folder) { targetFailed = true }
            }
        }
        if targetFailed { throw ClaudeProcessError.launchFailed }
    }

    /// True when the profile has a main instance afterwards: launched now, or already open because
    /// the user or an earlier pickup opened it, which a second launch must not repeat.
    func reopen(_ folder: ProfileFolder, deepLink: URL?) async -> Bool {
        let profile = paths.claudeProfilesRoot.appending(path: folder.name)
        if let running = try? await processes.runningInstances(),
           running.contains(where: { ProfilePaths.same($0.profileDirectory, profile) }) { return true }
        // Claude would make a folder that is gone (archived, moved) a new, empty profile.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: profile.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        do {
            _ = try await processes.launch(profile: profile, deepLink: deepLink)
            return true
        } catch { return false }
    }
}
