import Foundation

public struct ConversationConfirmation: Sendable {
    public let profile: ProfileSnapshot
    public let target: ContinuityTarget
    public let launchThreshold: Int64
}

public enum SwitchExecution: Sendable {
    case noOp
    case completed(warnings: [OperationWarning], confirmation: ConversationConfirmation?)
    case failed(FailureReason)
}

public actor SwitchCoordinator {
    private let paths: AppPaths
    private let store: StateStore
    private let lifecycle: ClaudeLifecycle
    private let guardService: TaskGuard
    private let clock: any Clock
    private let scanner: ProfileScanner
    private let backups: BackupManager
    private let sync: SessionSync
    private let continuity: ContinuityInspector
    private let autoCompact: AutoCompactLink
    private let compactionWait: CompactionWait
    private let log: CompanionLog
    private let recovery: NativeRecoveryCoordinator?

    /// How long a switch waits for the plugin to begin compacting the conversation it is leaving, or to answer.
    static let compactionLimit: TimeInterval = 180
    /// Once that compaction has begun, how long the switch waits for it to end: closing Claude under a
    /// /compact would throw away what it has done.
    static let compactionRunLimit: TimeInterval = 600

    public init(paths: AppPaths, store: StateStore, lifecycle: ClaudeLifecycle,
                taskGuard: TaskGuard, compactionWait: CompactionWait = CompactionWait(), clock: any Clock, log: CompanionLog,
                recovery: NativeRecoveryCoordinator? = nil) {
        self.paths = paths
        self.store = store
        self.lifecycle = lifecycle
        guardService = taskGuard
        self.compactionWait = compactionWait
        self.clock = clock
        self.log = log
        self.recovery = recovery
        scanner = ProfileScanner(paths: paths)
        backups = BackupManager(paths: paths, clock: clock, log: log)
        sync = SessionSync()
        continuity = ContinuityInspector(paths: paths)
        autoCompact = AutoCompactLink(paths: paths)
    }

    public func run(target folder: ProfileFolder, automaticSource: ProfileFolder? = nil,
                    progress: @escaping @Sendable (OperationState) async -> Void,
                    prompt: @escaping @Sendable (TaskGuardPrompt?) async -> Void) async -> SwitchExecution {
        // The in-memory gate covers one app instance. Hold one OS lease across the actual
        // switch so another instance cannot close/sync/launch the same profiles concurrently.
        let lease: CompanionFileLease
        do { lease = try CompanionFileLease(file: paths.companionDataDirectory.appending(path: "locks/account-switch.lock")) }
        catch { return .failed(.operationInFlight) }
        defer { lease.release() }
        let started = clock.now()
        var record = SwitchRecord()
        let execution = await switchTo(folder, automaticSource: automaticSource,
                                       record: &record, progress: progress, prompt: prompt)
        logResult(execution, target: folder, record: record, total: clock.now().timeIntervalSince(started))
        return execution
    }

    /// The switch's line in the log. Time at the task check (the prompt, or waiting for tasks to
    /// end) and on the compaction before the switch is reported apart, so the duration is the
    /// switch's own.
    private func logResult(_ execution: SwitchExecution, target: ProfileFolder, record: SwitchRecord,
                           total: TimeInterval) {
        let route = "Switch \(record.source?.name ?? "none") -> \(target.name)"
        let own = SwitchLog.seconds(total - (record.taskCheck?.seconds ?? 0) - (record.compaction?.seconds ?? 0))
        var context = ""
        if let check = record.taskCheck {
            switch check.permission {
            case .override: context = "; tasks: switched now after \(SwitchLog.seconds(check.seconds))"
            case .idle: context = check.seconds >= 1 ? "; tasks: waited \(SwitchLog.seconds(check.seconds))" : "; tasks: none running"
            case .cancelled: break
            }
        } else if record.claudeWasOpen == false {
            context = "; Claude was closed"
        }
        if let compaction = record.compaction { context += SwitchLog.compaction(compaction) }
        switch execution {
        case .noOp:
            return
        case .completed(let warnings, _):
            log.info(.switch, "\(route): switched in \(own)\(context)\(SwitchLog.warnings(warnings))")
        case .failed(.cancelled):
            var stage = "at the task check"
            if case .cancelled? = record.compaction?.outcome { stage = "while compacting first" }
            log.info(.switch, "\(route): cancelled \(stage) after \(SwitchLog.seconds(total))")
        case .failed(.returnedToPreviousAccount):
            log.warning(.switch, "\(route): the target did not open, back on \(record.source?.name ?? "none") after \(own)\(context)")
        case .failed(let reason):
            let detail = record.closeFailure.map(SwitchLog.closeDetail) ?? ""
            log.warning(.switch, "\(route): failed after \(own): \(reason)\(detail)\(context)")
        }
    }

    private func switchTo(_ folder: ProfileFolder, automaticSource: ProfileFolder?, record: inout SwitchRecord,
                          progress: @escaping @Sendable (OperationState) async -> Void,
                          prompt: @escaping @Sendable (TaskGuardPrompt?) async -> Void) async -> SwitchExecution {
        let state: CompanionState
        let profiles: [ProfileSnapshot]
        var running: [ClaudeInstance]
        // Helpers or Code tasks left by a main process that already exited still need the task
        // check and a full close, so "open" is any Claude process, not only a main instance.
        var claudeOpen: Bool
        do {
            state = try await store.load()
            profiles = try scanner.scan(managed: state.accounts.map(\.folder),
                                        pending: state.pendingSignIns.map(\.folder)).profiles
            running = try await lifecycle.processes.runningInstances()
            claudeOpen = try await anyClaudeProcess(running)
        } catch { return .failed(.couldNotReadProcesses) }
        let url = paths.claudeProfilesRoot.appending(path: folder.name)
        guard let target = profiles.first(where: { $0.folder == folder }) else { return .failed(.targetMissing) }
        guard !ProfilePaths.same(url, paths.companionDataDirectory),
              (try? ProfileConfigReader().read(profile: target.url)) != nil else { return .failed(.targetUnreadable) }
        if folder == state.activeFolder, running.contains(where: { ProfilePaths.same($0.profileDirectory, target.url) }) {
            return .noOp
        }
        // Remembered activation is useful as the source only while that profile is running.
        let source = profiles.first { profile in
            profile.folder == state.activeFolder && profile.folder != folder &&
                running.contains { ProfilePaths.same($0.profileDirectory, profile.url) }
        } ?? running.compactMap { instance in
            profiles.first { $0.folder != folder && ProfilePaths.same($0.url, instance.profileDirectory) }
        }.first ?? profiles.first { $0.folder == state.activeFolder && ($0.folder != folder || running.isEmpty) }
        record.source = source?.folder
        record.claudeWasOpen = claudeOpen
        if let automaticSource {
            guard state.settings.autoSwitchOnQuota, state.activeFolder == automaticSource, source?.folder == automaticSource,
                  let source, !running.isEmpty, running.allSatisfy({ ProfilePaths.same($0.profileDirectory, source.url) }),
                  let recovery, await recovery.automaticSwitchHold(source: source) == nil
            else { return .failed(.cancelled) }
        }
        // An unattended switch exists to carry the work on, which needs its conversations in the next account.
        let syncs = state.settings.autoSyncOnSwitch || automaticSource != nil
        // Enabling automatic switching authorizes this quota-triggered handoff. A task waiting on
        // an exhausted account cannot finish to answer the usual wait-for-tasks question.
        var override = automaticSource != nil
        if claudeOpen, automaticSource == nil {
            switch await checkTasks(target: folder, record: &record, prompt: prompt) {
            case .cancelled: return .failed(.cancelled)
            case .override: override = true
            case .idle: break
            }
        }
        // Switching now cuts a running task short anyway, so nothing waits for a compaction then.
        if claudeOpen, !override, state.settings.autoCompactOnLowQuota, let source,
           let leaving = try? continuity.capture(profile: source) {
            record.compaction = await compactFirst(leaving, target: folder, progress: progress)
            if case .cancelled? = record.compaction?.outcome { return .failed(.cancelled) }
            // The task check was answered before the wait: a task begun meanwhile is asked about too.
            if record.compaction?.waited == true {
                switch await checkTasks(target: folder, record: &record, prompt: prompt) {
                case .cancelled: return .failed(.cancelled)
                case .override: override = true
                case .idle: break
                }
            }
        }
        do {
            guard (try? ProfileConfigReader().read(profile: target.url)) != nil else { return .failed(.targetUnreadable) }
            running = try await lifecycle.processes.runningInstances()
            claudeOpen = try await anyClaudeProcess(running)
        } catch { return .failed(.couldNotReadProcesses) }
        var warnings: [OperationWarning] = record.compaction?.missed == true ? [.notCompactedFirst] : []
        var capture: ContinuityCapture?
        if let source {
            do { capture = try continuity.capture(profile: source) }
            catch { warnings.append(.continuityCaptureFailed) }
        }
        var workHandoff: NativeRecoveryBatch?, prepareFailed = false
        if let recovery {
            do {
                if syncs, let source {
                    workHandoff = try await recovery.prepare(source: source, target: target, primary: capture,
                                                             claudeWasOpen: claudeOpen)
                    if (workHandoff?.captureFailures ?? 0) > 0 { warnings.append(.workContinuationUnavailable) }
                } else if source?.folder != folder {
                    // Reopening the same closed profile is not a new handoff. In particular,
                    // turning sync off must not revoke an earlier surviving worker's permit.
                    try await recovery.invalidate()
                }
            } catch is NativeRecoveryCoordinationError { return .failed(.operationInFlight) }
              catch { warnings.append(.workContinuationUnavailable); prepareFailed = true }
        }
        // An unattended switch goes on whatever the histories show. A preparation that failed holds
        // it, and so does a command closing Claude would cut off, until that command ends.
        if automaticSource != nil {
            if prepareFailed {
                await recovery?.cancel(workHandoff)
                return .failed(.couldNotPrepareContinuation)
            }
            if (workHandoff?.commandHolds ?? 0) > 0 {
                await recovery?.cancel(workHandoff)
                return .failed(.cancelled)
            }
        }
        var completed: [SwitchStep] = []
        // The hold taken below on the target ends with the switch, whichever way it returns.
        defer { lifecycle.debt.release(folder) }
        if claudeOpen {
            await progress(.switching(target: folder, step: .closingClaude, completedSteps: completed))
            let bystanders = running.compactMap { instance in
                profiles.first { ProfilePaths.same($0.url, instance.profileDirectory) && $0.folder != source?.folder }?.folder
            }
            // Unknown but explicit profile paths still owe a relaunch, even outside discovery.
            let otherFolders = running.filter { instance in
                source.map { !ProfilePaths.same($0.url, instance.profileDirectory) } ?? true
            }.compactMap { instance -> ProfileFolder? in
                guard ProfilePaths.same(instance.profileDirectory.deletingLastPathComponent(), paths.claudeProfilesRoot) else { return nil }
                return try? ProfileFolder(instance.profileDirectory.lastPathComponent)
            }
            // Held until the switch ends: the sync writes into it, so no other launcher may open it
            // meanwhile. The hold does not stop the switch's own launch below.
            lifecycle.debt.hold(folder)
            if let handoff = workHandoff, let source {
                workHandoff = await recovery?.refreshSourceStops(handoff, source: source)
                if (workHandoff?.captureFailures ?? 0) > handoff.captureFailures,
                   !warnings.contains(.workContinuationUnavailable) { warnings.append(.workContinuationUnavailable) }
            }
            if let automaticSource, let source {
                // The final sample also persists command handoff permissions. A successful
                // preparation cannot authorize closing after that last save has failed.
                if workHandoff?.requests.contains(where: { $0.phase == "blocked" }) == true {
                    await recovery?.cancel(workHandoff)
                    return .failed(.couldNotPrepareContinuation)
                }
                if (workHandoff?.commandHolds ?? 0) > 0 {
                    await recovery?.cancel(workHandoff)
                    return .failed(.cancelled)
                }
                // An unattended switch must land where the work can go on: a conversation in bypass
                // mode needs a target that allows it. The engine then tries another account.
                if let handoff = workHandoff, source.folder != target.folder, needsBypassForContinuation(handoff, source: source),
                   !CodePreferenceInheritance().allowsBypass(profile: target) {
                    await recovery?.cancel(workHandoff)
                    return .failed(.targetCannotContinue)
                }
                let latest = try? await store.load()
                guard latest?.settings.autoSwitchOnQuota == true, latest?.activeFolder == automaticSource,
                      let latestRunning = try? await lifecycle.processes.runningInstances(), !latestRunning.isEmpty,
                      latestRunning.allSatisfy({ ProfilePaths.same($0.profileDirectory, source.url) }),
                      await recovery?.automaticSwitchHold(source: source) == nil else {
                    await recovery?.cancel(workHandoff)
                    return .failed(.cancelled)
                }
            }
            do { try await lifecycle.close(owing: [folder] + bystanders + otherFolders, allowForce: override) }
            catch {
                record.closeFailure = error
                await recovery?.cancel(workHandoff)
                return .failed(.couldNotCloseClaude)
            }
            completed.append(.closingClaude)
            if let handoff = workHandoff, let source {
                workHandoff = await recovery?.reconcileAfterClose(handoff, source: source)
                if (workHandoff?.captureFailures ?? 0) > handoff.captureFailures,
                   !warnings.contains(.workContinuationUnavailable) { warnings.append(.workContinuationUnavailable) }
                // Conversations kept for their comment watch wait for this account to open again.
                await recovery?.recordLeftWatches(handoff.leftWatches, account: source.folder)
            }
        }
        // Sync also when Claude was already closed. With nothing running and the current account
        // clicked, the source is the target itself, which has nothing to sync with.
        if syncs, let source, source.folder != folder {
            await progress(.switching(target: folder, step: .syncingSessions, completedSteps: completed))
            warnings += await synchronize(source: source, target: target)
            completed.append(.syncingSessions)
        }
        let transferFailed = warnings.contains(where: {
            switch $0 { case .backupFailed, .sessionsNotSynced, .activeOrganizationUnknown: true; default: false }
        })
        if transferFailed {
            await recovery?.cancel(workHandoff)
            if workHandoff != nil { warnings.append(.workContinuationUnavailable) }
            workHandoff = nil
        }
        var checked: ContinuityTarget?
        if let capture {
            do {
                guard case .signedIn(let identity) = target.status else { throw ContinuityFailure.identityUnavailable }
                let fresh = try scanner.scan(managed: state.accounts.map(\.folder)).profiles
                    .first { $0.folder == folder }
                guard let fresh else { throw ContinuityFailure.identityChanged }
                checked = try continuity.validateTarget(capture, profile: fresh, expectedIdentity: identity)
            } catch { warnings.append(.conversationNotReopened) }
        }
        if automaticSource != nil, let source,
           transferFailed || workHandoff?.requests.contains(where: { $0.phase == "blocked" }) == true {
            // An unattended switch exists to transfer the original work. A known failed transfer
            // must not leave an empty target open. Reopen the source conversation without asking
            // the CC-Relay plugin to continue; Claude itself controls its normal reopen behavior.
            await recovery?.cancel(workHandoff)
            return .failed(await returnAfterFailedTransfer(target: target, source: source, capture: capture))
        }
        if let handoff = workHandoff {
            var unprepared = false
            do {
                unprepared = try await recovery?.prepareTargetLaunch(handoff, profile: target,
                                                                     allOrNothing: automaticSource != nil) ?? 0 > 0
            } catch {
                await recovery?.cancel(workHandoff)
                workHandoff = nil
                unprepared = true
            }
            // A conversation the target could not be told to start is a failed transfer too for an
            // unattended switch, which then left no marker there.
            if unprepared, automaticSource != nil, let source {
                await recovery?.cancel(workHandoff)
                return .failed(await returnAfterFailedTransfer(target: target, source: source, capture: capture))
            }
            if unprepared, !warnings.contains(.workContinuationUnavailable) { warnings.append(.workContinuationUnavailable) }
        }
        // Conversations this account kept for their comment watch start with it again.
        let carried = Set(workHandoff?.requests.map(\.sessionID) ?? [])
        let watches = await recovery?.prepareLeftWatchReopen(profile: target, excluding: carried) ?? []
        await progress(.switching(target: folder, step: .openingClaude, completedSteps: completed))
        let link = checked.flatMap { URL(string: "claude://code/continue?session=\($0.record.sessionID)") }
        let threshold = Int64(clock.now().timeIntervalSince1970 * 1000)
        do {
            if !claudeOpen { _ = try await lifecycle.processes.launch(profile: target.url, deepLink: link) }
            else if let failure = await launchAfterClose(target: target, previous: source, capture: capture, deepLink: link,
                                                         carried: carried) {
                await recovery?.recordLeftWatches(watches, account: folder)
                if failure == .returnedToPreviousAccount, let workHandoff, let source {
                    _ = try? await recovery?.redirect(workHandoff, to: source)
                } else { await recovery?.cancel(workHandoff) }
                return .failed(failure)
            }
        } catch {
            await recovery?.recordLeftWatches(watches, account: folder)
            await recovery?.cancel(workHandoff); return .failed(.couldNotOpenClaude)
        }
        do { try await store.update { $0.activeFolder = folder } }
        catch { log.warning(.switch, "The switched account could not be persisted.") }
        if let workHandoff {
            do { try await recovery?.activate(workHandoff) }
            catch { warnings.append(.workContinuationUnavailable) }
        }
        if let checked {
            if let tokens = TranscriptUsageReader(paths: paths).contextTokens(cliSessionID: checked.record.cliSessionID) {
                log.info(.switch, "Conversation context token total: \(tokens)")
            }
            completed.append(.openingClaude)
            await progress(.switching(target: folder, step: .reopeningConversation, completedSteps: completed))
        }
        let confirmation = checked.map { ConversationConfirmation(profile: target, target: $0, launchThreshold: threshold) }
        return .completed(warnings: warnings, confirmation: confirmation)
    }

    /// Asks whether Code tasks are running; the time it takes adds to the switch's task check.
    private func checkTasks(target folder: ProfileFolder, record: inout SwitchRecord,
                            prompt: @escaping @Sendable (TaskGuardPrompt?) async -> Void) async -> TaskGuardPermission {
        let asked = clock.now()
        let permission = await guardService.check(target: folder, publish: prompt)
        record.taskCheck = (permission, (record.taskCheck?.seconds ?? 0) + clock.now().timeIntervalSince(asked))
        return permission
    }

    /// A long conversation is compacted on the account it is leaving, so the next account need not
    /// read all of it again. The plugin in that conversation does it; the switch waits up to
    /// `compactionLimit` for it to begin or answer, then, once it has begun, up to
    /// `compactionRunLimit` for its end, or until the user skips, and goes on either way; quitting
    /// calls it off. Nil when the conversation is shorter than `AutoCompactLink.switchContextTokens`
    /// or its size is unknown.
    private func compactFirst(_ leaving: ContinuityCapture, target folder: ProfileFolder,
                              progress: @escaping @Sendable (OperationState) async -> Void) async -> CompactionRecord? {
        let session = leaving.record.cliSessionID
        guard let tokens = TranscriptUsageReader(paths: paths).contextTokens(cliSessionID: session),
              tokens >= AutoCompactLink.switchContextTokens else { return nil }
        let started = clock.now()
        var record = CompactionRecord(tokens: tokens, outcome: .notLive)
        switch autoCompact.switchReadiness(sessionID: session, now: started) {
        case .notReporting: return record
        case .outdated:
            record.outcome = .pluginOutdated
            return record
        case .ready: break
        }
        let id = Int(started.timeIntervalSince1970 * 1000)
        do {
            // The plugin begins nothing past this, a little before the wait for a start ends: a
            // compaction that begins in time is seen while the switch still waits.
            try autoCompact.requestCompaction(id: id, sessionID: session, until: started.addingTimeInterval(Self.compactionLimit - 10))
        } catch {
            record.outcome = .notAsked
            return record
        }
        await compactionWait.begin()
        await progress(.switching(target: folder, step: .compactingConversation, completedSteps: []))
        record.outcome = .timedOut
        var deadline = started.addingTimeInterval(Self.compactionLimit)
        while clock.now() < deadline {
            if let interruption = await compactionWait.interruption {
                record.outcome = interruption == .skipped ? .skippedByUser : .cancelled
                break
            }
            if let answer = autoCompact.compactionAnswer(id: id) {
                record.outcome = .answered(answer)
                break
            }
            if case .timedOut = record.outcome, autoCompact.compactionBegun(id: id) {
                record.outcome = .unfinished
                deadline = clock.now().addingTimeInterval(Self.compactionRunLimit)
            }
            do { try await clock.sleep(for: .seconds(1)) } catch { break }
        }
        await compactionWait.end()
        autoCompact.withdrawRequest()
        record.seconds = clock.now().timeIntervalSince(started)
        return record
    }

    private func anyClaudeProcess(_ running: [ClaudeInstance]) async throws -> Bool {
        if !running.isEmpty { return true }
        return try await lifecycle.processes.hasAnyProcess()
    }

    /// Whether a conversation that goes on after the switch runs in bypass mode, read from its
    /// saved Desktop session. A record whose mode cannot be read decides nothing, as before this
    /// check; the others still do.
    private func needsBypassForContinuation(_ batch: NativeRecoveryBatch, source: ProfileSnapshot) -> Bool {
        guard let bucket = source.readableBucket else { return false }
        let io = SessionFileIO()
        return batch.requests.contains { request in
            guard !request.sourceUserStopped,
                  request.sourceWasBusy || request.work.needsContinuation || request.work.hasArmedArtifactWatches,
                  request.desktopSessionID.hasPrefix("local_"),
                  AutoCompactLink.validSessionID(String(request.desktopSessionID.dropFirst(6))) else { return false }
            let file = source.url.appending(path: bucket.relativePath).appending(path: request.desktopSessionID + ".json")
            guard (try? io.checkPath(file, under: source.url)) != nil,
                  let object = try? SessionJSON.object(io.read(file), at: file),
                  object["cliSessionId"] as? String == request.sessionID else { return false }
            return object["permissionMode"] as? String == "bypassPermissions"
        }
    }

    /// The target has not been launched. Transfer its durable relaunch record to the original
    /// account before opening it, so quit/crash recovery cannot later open the failed target.
    /// Session files may have been partly synced; none are rolled back or overwritten here.
    private func returnAfterFailedTransfer(target: ProfileSnapshot, source: ProfileSnapshot,
                                          capture: ContinuityCapture?) async -> FailureReason {
        do {
            try await lifecycle.debt.finishSwitchTarget(target.folder, fallback: source.folder, restorePrevious: true)
            if try await lifecycle.debt.claim(source.folder) {
                let link = capture.flatMap { URL(string: "claude://code/continue?session=\($0.record.sessionID)") }
                let watches = await recovery?.prepareLeftWatchReopen(profile: source, excluding: []) ?? []
                let opened = await lifecycle.reopen(source.folder, deepLink: link)
                if !opened { await recovery?.recordLeftWatches(watches, account: source.folder) }
                await lifecycle.debt.settle(source.folder, opened: opened)
                guard opened else { return .transferFailedNotReopened }
            } else {
                let running = try await lifecycle.processes.runningInstances()
                guard running.contains(where: { ProfilePaths.same($0.profileDirectory, source.url) }) else { return .transferFailedNotReopened }
            }
            do { try await store.update { $0.activeFolder = source.folder } }
            catch { log.warning(.switch, "The original account reopened after a failed transfer could not be persisted.") }
            return .transferFailedReturnedToPreviousAccount
        } catch { return .transferFailedNotReopened }
    }

    private func launchAfterClose(target: ProfileSnapshot, previous: ProfileSnapshot?, capture: ContinuityCapture?,
                                  deepLink: URL?, carried: Set<String>) async -> FailureReason? {
        let fallback = previous.flatMap { $0.folder != target.folder ? $0 : nil }
        do {
            guard let bystanders = try await lifecycle.debt.claimSwitchTarget(target.folder, fallback: fallback?.folder) else {
                // Quit may already have claimed and launched the target.
                let running = try await lifecycle.processes.runningInstances()
                return running.contains { ProfilePaths.same($0.profileDirectory, target.url) } ? nil : .couldNotOpenClaude
            }
            let targetOpened: Bool
            var safeToRestore = true
            do {
                _ = try await lifecycle.processes.launch(profile: target.url, deepLink: deepLink)
                targetOpened = true
            } catch {
                targetOpened = false
                if error as? ClaudeProcessError == .launchCleanupFailed { safeToRestore = false }
            }
            try await lifecycle.debt.finishSwitchTarget(target.folder, fallback: fallback?.folder,
                restorePrevious: !targetOpened && safeToRestore, keepTarget: !safeToRestore)
            for folder in bystanders {
                // A bystander that fails to open stays owed, so the next pickup tries it again.
                let opened: Bool
                do {
                    guard try await lifecycle.debt.claim(folder) else { continue }
                    opened = await lifecycle.reopen(folder, deepLink: nil)
                    await lifecycle.debt.settle(folder, opened: opened)
                } catch { opened = false }
                if !opened { log.warning(.switch, "A bystander profile could not be reopened.") }
            }
            if targetOpened { return nil }
            guard safeToRestore, let fallback else { return .couldNotOpenClaude }
            if try await lifecycle.debt.claim(fallback.folder) {
                let link = capture.flatMap { URL(string: "claude://code/continue?session=\($0.record.sessionID)") }
                let watches = await recovery?.prepareLeftWatchReopen(profile: fallback, excluding: carried) ?? []
                let opened = await lifecycle.reopen(fallback.folder, deepLink: link)
                if !opened { await recovery?.recordLeftWatches(watches, account: fallback.folder) }
                await lifecycle.debt.settle(fallback.folder, opened: opened)
                guard opened else { return .couldNotOpenClaude }
            } else {
                let running = try await lifecycle.processes.runningInstances()
                guard running.contains(where: { ProfilePaths.same($0.profileDirectory, fallback.url) }) else { return .couldNotOpenClaude }
            }
            do { try await store.update { $0.activeFolder = fallback.folder } }
            catch { log.warning(.switch, "The restored account could not be persisted.") }
            return .returnedToPreviousAccount
        } catch { return .couldNotOpenClaude }
    }

    private func synchronize(source: ProfileSnapshot, target: ProfileSnapshot) async -> [OperationWarning] {
        guard case .signedIn(let a) = source.status, case .signedIn(let b) = target.status else { return [] }
        guard a.activeOrganizationUUID != nil, b.activeOrganizationUUID != nil else { return [.activeOrganizationUnknown] }
        do {
            guard try await !lifecycle.processes.hasAnyProcess() else { return [.sessionsNotSynced(count: 1)] }
            let fresh = try scanner.scan(managed: [source.folder, target.folder]).profiles
            guard let sourceNow = fresh.first(where: { $0.folder == source.folder }),
                  let targetNow = fresh.first(where: { $0.folder == target.folder }),
                  sourceNow.identityMatches(source), targetNow.identityMatches(target) else {
                return [.sessionsNotSynced(count: 1)]
            }
            do {
                _ = try backups.backup(profile: sourceNow)
                _ = try backups.backup(profile: targetNow)
            } catch { return [.backupFailed] }
            let report = try sync.syncTwoWay(SyncPlan(source: sourceNow, target: targetNow))
            let errors = report.forward.errors.count + report.reverse.errors.count + report.unresolved.count
            var warnings: [OperationWarning] = errors > 0 ? [.sessionsNotSynced(count: errors)] : []
            if !report.forward.warnings.isEmpty || !report.reverse.warnings.isEmpty { warnings.append(.activeOrganizationUnknown) }
            return warnings
        } catch { return [.sessionsNotSynced(count: 1)] }
    }

    public func confirm(_ confirmation: ConversationConfirmation) async -> Bool {
        let deadline = clock.now().addingTimeInterval(90)
        while !Task.isCancelled {
            do {
                let running = try await lifecycle.processes.runningInstances()
                let config = try ProfileConfigReader().read(profile: confirmation.profile.url)
                let identity = confirmation.target.identity
                let unchanged = config.accountUUID == identity.accountUUID &&
                    config.activeOrganizationUUID == identity.activeOrganizationUUID &&
                    running.contains { ProfilePaths.same($0.profileDirectory, confirmation.profile.url) }
                guard unchanged else { return false }
                guard let bucket = confirmation.profile.readableBucket else { return false }
                let record = try? continuity.readRecord(at: confirmation.profile.url.appending(path: bucket.relativePath)
                    .appending(path: confirmation.target.record.sessionID + ".json"))
                if ContinuityInspector.isConfirmed(current: record, captured: confirmation.target,
                    launchThreshold: confirmation.launchThreshold, targetRunningWithUnchangedIdentity: unchanged) { return true }
            } catch { return false }
            let remaining = deadline.timeIntervalSince(clock.now())
            if remaining <= 0 { return false }
            do { try await clock.sleep(for: .seconds(min(0.2, remaining))) }
            catch { return false }
        }
        return false
    }
}

extension ProfileSnapshot {
    var identity: AccountIdentity? {
        if case .signedIn(let identity) = status { return identity }
        return nil
    }

    func identityMatches(_ other: ProfileSnapshot) -> Bool {
        guard let a = identity, let b = other.identity else { return false }
        return a.accountUUID == b.accountUUID && a.activeOrganizationUUID == b.activeOrganizationUUID
    }

    var quotaProfile: QuotaProfile? {
        identity.map { QuotaProfile(folder: folder, directory: url, accountUUID: $0.accountUUID,
                                   organizationUUID: $0.activeOrganizationUUID) }
    }
}
