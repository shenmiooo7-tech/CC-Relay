import Foundation

public enum HistoryImportResult: Equatable, Sendable {
    case completed
    case deferred
    case paused(HistoryIssue, FailureReason?)
}

public actor HistoryImporter {
    private let store: StateStore
    private let scanner: ProfileScanner
    private let lifecycle: ClaudeLifecycle
    private let guardService: TaskGuard
    private let backup: BackupManager
    private let sync = SessionSync()
    private let preferences = CodePreferenceInheritance()

    public init(paths: AppPaths, store: StateStore, lifecycle: ClaudeLifecycle,
                taskGuard: TaskGuard, clock: any Clock, log: CompanionLog) {
        self.store = store
        scanner = ProfileScanner(paths: paths)
        self.lifecycle = lifecycle
        guardService = taskGuard
        backup = BackupManager(paths: paths, clock: clock, log: log)
    }

    public func run(folder: ProfileFolder, retry: Bool = false,
                    prompt: @escaping @Sendable (TaskGuardPrompt?) async -> Void,
                    progress: @escaping @Sendable (OperationState) async -> Void) async -> HistoryImportResult {
        var currentJob: HistoryJob?
        do {
            var state = try await store.load()
            guard state.settings.autoSyncOnSwitch,
                  var job = state.historyJobs.first(where: { $0.target == folder }),
                  !job.paused || retry else { return .deferred }
            currentJob = job
            guard let target = try inventory(state).first(where: { $0.folder == folder }),
                  let identity = target.identity, let org = identity.activeOrganizationUUID else { return .deferred }
            if let account = job.targetAccountUUID, account != identity.accountUUID {
                return try await pause(job, issue: .unavailable, reason: .signedInAccountDiffers)
            }
            if let pinnedOrg = job.targetOrganizationUUID, pinnedOrg != org {
                return try await pause(job, issue: .unavailable, reason: .targetUnreadable)
            }
            let previous = job
            job.targetAccountUUID = identity.accountUUID
            job.targetOrganizationUUID = org
            job.paused = true
            job.issue = .interrupted
            job.revision += 1
            guard try await replace(previous, with: job) else { return .deferred }
            currentJob = job
            if job.donors.isEmpty && job.codePreference == nil {
                _ = try await replace(job, with: nil)
                return .completed
            }
            let available = validDonors(job, profiles: try inventory(state), target: target)
            if available.isEmpty && !job.donors.isEmpty {
                return try await pause(job, issue: .unavailable)
            }
            let permission = await guardService.check(target: folder, publish: prompt)
            if case .cancelled = permission { return try await pause(job, issue: .interrupted, reason: .cancelled) }
            await progress(.addingAccount(phase: .importingHistory))
            let running = try await lifecycle.processes.runningInstances()
            let owed = running.compactMap { instance in
                try? ProfileFolder(instance.profileDirectory.lastPathComponent)
            }
            // Held until the import opens it again: the copy writes into it, so nothing else may open it meanwhile.
            lifecycle.debt.hold(folder)
            defer { lifecycle.debt.release(folder) }
            do {
                try await lifecycle.close(owing: [folder] + owed, allowForce: {
                    if case .override = permission { return true }; return false
                }())
            } catch { return try await pause(job, issue: .failed, reason: .couldNotCloseClaude) }
            var issue: HistoryIssue?
            do {
                state = try await store.load()
                guard state.settings.autoSyncOnSwitch,
                      state.historyJobs.contains(job),
                      // Main processes can exit before a late helper stops using the files.
                      try await !lifecycle.processes.hasAnyProcess() else {
                    throw SessionDataError.invalidPlan
                }
                let profiles = try inventory(state)
                guard let freshTarget = profiles.first(where: { $0.folder == folder }), freshTarget.identityMatches(target) else {
                    throw SessionDataError.invalidPlan
                }
                let donors = validDonors(job, profiles: profiles, target: freshTarget)
                if donors.count != job.donors.count { issue = .unavailable }
                _ = try backup.backup(profile: freshTarget, extraFiles: [CodePreferenceInheritance.fileName])
                let prepared = try preferences.prepare(intent: job.codePreference, target: freshTarget)
                var copyErrors = 0
                for donor in donors {
                    let report = sync.sync(try SyncPlan(source: donor, target: freshTarget))
                    copyErrors += report.errors.count + (report.aborted ? 1 : 0)
                }
                if copyErrors > 0 { issue = .failed }
                else { try preferences.apply(prepared) }
            } catch { issue = .failed }
            lifecycle.debt.release(folder)
            do { try await lifecycle.relaunchOwed(target: folder, required: owed) }
            catch { return try await pause(job, issue: .failed, reason: .couldNotOpenClaude) }
            if let issue { return try await pause(job, issue: issue) }
            guard try await replace(job, with: nil) else { return .deferred }
            return .completed
        } catch {
            if let currentJob { _ = try? await pause(currentJob, issue: .failed) }
            return .paused(.failed, .targetUnreadable)
        }
    }

    private func inventory(_ state: CompanionState) throws -> [ProfileSnapshot] {
        try scanner.scan(managed: state.accounts.map(\.folder), pending: state.pendingSignIns.map(\.folder)).profiles
    }

    private func validDonors(_ job: HistoryJob, profiles: [ProfileSnapshot], target: ProfileSnapshot) -> [ProfileSnapshot] {
        job.donors.compactMap { pin in
            guard let profile = profiles.first(where: { $0.folder == pin.folder }),
                  let identity = profile.identity,
                  identity.accountUUID == pin.accountUUID, identity.activeOrganizationUUID == pin.organizationUUID,
                  !ProfilePaths.same(profile.url, target.url),
                  let bucket = profile.readableBucket,
                  let info = try? SessionFileIO().info(profile.url.appending(path: bucket.relativePath)),
                  SessionFileIO().isDirectory(info) else { return nil }
            return profile
        }
    }

    private func pause(_ job: HistoryJob, issue: HistoryIssue, reason: FailureReason? = nil) async throws -> HistoryImportResult {
        var changed = job
        changed.paused = true
        changed.issue = issue
        changed.revision += 1
        _ = try await replace(job, with: changed)
        return .paused(issue, reason)
    }

    /// The generation check prevents stale completion from consuming a replacement job.
    @discardableResult
    func replace(_ expected: HistoryJob, with replacement: HistoryJob?) async throws -> Bool {
        var changed = false
        try await store.update { state in
            guard let index = state.historyJobs.firstIndex(where: {
                $0.target == expected.target && $0.createdAt == expected.createdAt && $0.revision == expected.revision
            }) else { return }
            if let replacement { state.historyJobs[index] = replacement }
            else { state.historyJobs.remove(at: index) }
            changed = true
        }
        return changed
    }
}
