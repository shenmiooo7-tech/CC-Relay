import Foundation
import Darwin

public struct NativeRecoveryBatch: Sendable {
    public var operation: NativeRecoveryOperation
    public var requests: [NativeRecoveryRequest]
    /// Conversations whose work cannot go on directly, with the commands below among them.
    public var captureFailures: Int
    /// Commands closing Claude would cut off: an automatic switch waits for them to end.
    public var commandHolds = 0
    /// Comment watches that stay with the source account, which published their pages, whether
    /// their conversations go on in the target account or stay closed.
    public var leftWatches: [NativeLeftWatch] = []
}

public enum NativeRecoveryCoordinationError: Error { case operationChanged }

/// Connects the existing switch to native sessions. Never launches a shell or replays a command.
public actor NativeRecoveryCoordinator {
    private let paths: AppPaths
    private let inspector: (any NativeRuntimeInspecting)?
    private let opener: (any NativeConversationOpening)?
    private let clock: any Clock
    private let continuity: ContinuityInspector
    private let capture: NativeWorkCapture
    // The native hooks host refuses a single fs.read over 4 MiB. Reserve space for binding metadata.
    private let requestByteLimit: Int
    private var polling = false
    /// What each conversation's read before closing reached, so the read after closing only
    /// continues it. Held between those two reads, never longer.
    private var checkpoints: [String: NativeCaptureCheckpoint] = [:]
    /// What the latest handoff wrote over, to put back if its switch stops before Claude closes: the
    /// handoff before it may still wait to be taken up. Held until then, never longer.
    private var replaced: (operationID: String, files: FileSnapshot)?
    public nonisolated let directory: URL

    public init(paths: AppPaths, inspector: (any NativeRuntimeInspecting)?,
                opener: (any NativeConversationOpening)? = nil, clock: any Clock = SystemClock(),
                requestByteLimit: Int = 4_000_000) {
        self.paths = paths; self.inspector = inspector; self.opener = opener; self.clock = clock
        continuity = ContinuityInspector(paths: paths); capture = NativeWorkCapture(paths: paths)
        directory = paths.companionDataDirectory.appending(path: "NativeRecovery")
        self.requestByteLimit = min(4_000_000, requestByteLimit)
    }

    /// Whether a fresh runtime report names an active limit, or an account the service stopped. Only
    /// the report files are read, so the automatic check can skip the scan and every other read while
    /// nothing has run out. Acting on either still needs `automaticSwitchReadiness`.
    func anyReportedQuotaBlock() -> Bool {
        folders(directory.appending(path: "runtimes")).contains { session in
            files(session).contains { file in
                guard let report: NativeRuntimeReport = read(file) else { return false }
                guard isFresh(report), let block = report.quotaBlock else { return false }
                return block.isActive(at: clock.now()) || block.stopsAccount(at: clock.now())
            }
        }
    }

    /// What holds an automatic switch back right before it closes Claude: a command that closing would
    /// cut off, or an account the service stopped.
    func automaticSwitchHold(source: ProfileSnapshot) async -> AutoSwitchPauseReason? {
        await automaticSwitchReadiness(source: source).pause
    }

    /// Only the open conversations' own reports are read: the limit one of them ran into, a command
    /// that closing Claude would cut off, and the service stopping the account, which outweighs both.
    /// Nothing else holds an automatic switch back; a conversation whose history or report says
    /// nothing still goes on in the next account.
    func automaticSwitchReadiness(source: ProfileSnapshot, sessionID: String? = nil) async
        -> (runtime: NativeRuntimeReport?, pause: AutoSwitchPauseReason?) {
        guard let inspector, let identity = source.identity, identity.activeOrganizationUUID != nil else { return (nil, nil) }
        let records = sourceRecords(source)
        var pause: AutoSwitchPauseReason?, stopped = false, verified: [NativeRuntimeReport] = []
        for process in await inspector.sessions(profile: source.url) {
            guard records.contains(where: { $0.cliSessionID == process.sessionID && !$0.isArchived }),
                  let report = reports(process.sessionID).filter({ $0.pid == process.pid && isFresh($0) })
                    .max(by: { $0.reportedAt < $1.reportedAt }),
                  report.capabilities.contains("native-recovery-v6"),
                  await inspector.validate(report, profile: source.url, account: identity) else { continue }
            // A once-approved native Bash has no surviving worker. Closing now would kill
            // its original body; wait for native completion instead of replaying it later.
            // Every source conversation closes, so check bystanders even when a particular
            // limited conversation was selected. The final pre-close check repeats this.
            if report.activeTasks?.contains(where: { $0.kind == .bash && $0.jobID == nil }) == true,
               pause == nil { pause = .commandRunning }
            // The host also lists commands this plugin never saw start. Check every source
            // conversation, including stopped bystanders, before selecting the limited one.
            if pause == nil { pause = hostWorkPause(report) }
            // Any conversation's word counts, also where the reply was stopped: the account is the same.
            if report.quotaBlock?.stopsAccount(at: clock.now()) == true { stopped = true }
            guard !report.userStopped, sessionID == nil || process.sessionID == sessionID else { continue }
            verified.append(report)
        }
        return (verified.first { $0.quotaBlock?.isActive(at: clock.now()) == true } ?? verified.first,
                stopped ? .accountRestricted : pause)
    }

    /// Only a command on this Mac goes on while the account is spent, and closing Claude ends it: a
    /// shell the host lists that the plugin does not protect holds the switch. Work that needs the
    /// model cannot go on in this account anyway, so nothing else in the list holds it.
    private func hostWorkPause(_ report: NativeRuntimeReport) -> AutoSwitchPauseReason? {
        report.hostWorkInventory?.backgroundTasks.contains {
            $0.type == "shell" && Self.tracked($0, in: report)?.jobID == nil
        } == true ? .commandRunning : nil
    }

    private static let hostTaskKinds: [String: NativeWorkKind] = ["shell": .bash, "subagent": .agent, "monitor": .monitor]

    /// The plugin's own record of a task the host reports: of the same kind, by its ID or an alias.
    private static func tracked(_ task: NativeHostWorkInventory.Task, in report: NativeRuntimeReport) -> NativeRuntimeTask? {
        guard let kind = hostTaskKinds[task.type] else { return nil }
        return report.activeTasks?.first { $0.kind == kind && ($0.id == task.id || $0.aliases?.contains(task.id) == true) }
    }

    private func waiting(_ request: NativeRecoveryRequest, operation: NativeRecoveryOperation?, profile: ProfileFolder) -> Bool {
        request.requiredCapability == "native-recovery-v6" && request.operationID == operation?.operationID &&
            request.targetProfile == profile.name && request.expiresAt > milliseconds &&
            ["prepared", "armed"].contains(request.phase) && !hasResultFile(request) && !request.sourceUserStopped
    }

    /// Called only after the user's task-guard choice, immediately before closing the source.
    public func prepare(source: ProfileSnapshot, target: ProfileSnapshot,
                        primary: ContinuityCapture?, claudeWasOpen: Bool) async throws -> NativeRecoveryBatch? {
        guard let inspector, let identity = target.identity else { return nil }
        let previous: NativeRecoveryOperation? = read(directory.appending(path: "active.json"))
        let saved = requests()
        let carried = saved.filter { waiting($0, operation: previous, profile: source.folder) }
        let durable = saved.filter { $0.requiredCapability == "native-recovery-v6" && $0.operationID == previous?.operationID && $0.targetProfile == source.folder.name &&
            $0.expiresAt > milliseconds && !$0.sourceUserStopped && ["prepared", "armed"].contains($0.phase) }
            .filter { old in sourceRecords(source).contains { $0.sessionID == old.desktopSessionID && $0.cliSessionID == old.sessionID && !$0.isArchived } }
            .compactMap { old -> (NativeRecoveryRequest, [NativeRuntimeTask])? in
                let finished = finishedCommandToolUses(old)
                let jobs = (old.sourceActiveTasks ?? []).filter {
                    if let use = $0.toolUseID, finished[use] != nil { return false }
                    guard let job = $0.jobID, let record = commandRecord(job), record.sessionID == old.sessionID else { return false }
                    return record.executionProtocol == 3 && ["starting", "running", "completed", "failed"].contains(record.status) &&
                        !FileManager.default.fileExists(atPath: commandDirectory(job).appending(path: "stop.json").path)
                }
                return jobs.isEmpty ? nil : (old, jobs)
            }
        let processes = claudeWasOpen ? await inspector.sessions(profile: source.url) : []
        // An old conversation file alone must never wake work on a cold app launch.
        guard !processes.isEmpty || !carried.isEmpty || !durable.isEmpty else {
            try withOperationLease {
                guard currentOperationID == previous?.operationID else { throw NativeRecoveryCoordinationError.operationChanged }
                try removeActiveOperation()
            }
            return nil
        }
        var operation = NativeRecoveryOperation(operationID: UUID().uuidString, targetProfile: target.folder.name,
                                                targetAccountID: identity.accountUUID, createdAt: milliseconds)
        operation.ready = false
        operation.sourceProfile = source.folder.name
        operation.sourceProcesses = processes.map { NativeRecoverySourceProcess(pid: $0.pid, startedAt: $0.startedAt.timeIntervalSince1970 * 1000) }
        operation.primaryDesktopSessionID = primary?.record.sessionID
        var made: [String: NativeRecoveryRequest] = [:], failures = 0, holds = 0
        var capturedWork: [String: NativeWorkSnapshot] = [:], left: [NativeLeftWatch] = []
        let records = sourceRecords(source), kept = keptWatches()
        checkpoints.removeAll()
        let readings = await captureAll(processes.compactMap { process in
            records.first(where: { $0.cliSessionID == process.sessionID && !$0.isArchived }).map { (process.sessionID, $0) }
        }, source: source)
        var readAhead: [String: NativeCaptureCheckpoint] = [:]
        for process in processes {
            guard let record = records.first(where: { $0.cliSessionID == process.sessionID && !$0.isArchived }),
                  let sourceIdentity = source.identity else {
                if process.busy { failures += 1 }; continue
            }
            do {
                let old = saved.first { $0.operationID == previous?.operationID && $0.sessionID == process.sessionID && $0.targetProfile == source.folder.name }
                let finished = old.map(finishedCommandToolUses) ?? [:]
                // A history that cannot be read carries nothing over directly; the conversation still goes on.
                let snapshot: NativeWorkSnapshot
                if let reading = try? readings[process.sessionID]?.get() {
                    snapshot = reading.0.markingFinishedCommands(finished)
                    readAhead[process.sessionID] = reading.1
                } else {
                    snapshot = .unread(record, profile: source, accountID: sourceIdentity.accountUUID, now: clock.now())
                }
                capturedWork[process.sessionID] = snapshot
                let reported = reports(process.sessionID).sorted(by: { $0.reportedAt > $1.reportedAt })
                    .first(where: { $0.pid == process.pid && isFresh($0) })
                var runtime: NativeRuntimeReport?
                if let reported, await inspector.validate(reported, profile: source.url, account: sourceIdentity) { runtime = reported }
                if let runtime, hostWorkPause(runtime) != nil { failures += 1; holds += 1 }
                var inventory = runtime?.capabilities.contains("native-recovery-v3") == true ? runtime?.activeTasks : nil
                inventory?.removeAll { finished[$0.toolUseID ?? ""] != nil }
                if let runtime, let active = inventory,
                   let old = saved.first(where: { $0.operationID == previous?.operationID && $0.sessionID == process.sessionID && $0.targetProfile == source.folder.name }) {
                    inventory = bridgeRegisteredMonitors(old, runtime: runtime, active: active, work: snapshot)
                }
                // A comment watch stays with the account that published its page, which the target
                // account cannot open, whether its conversation goes on there or stays closed. That
                // account starts the conversation again for it later, when the plugin can keep that
                // start from a model turn. A page already kept for another account stays with it,
                // also once that account has opened.
                if snapshot.hasArmedArtifactWatches, runtime?.capabilities.contains(Self.watchReopenCapability) == true,
                   let record = records.first(where: { $0.cliSessionID == process.sessionID && !$0.isArchived }) {
                    let pages = snapshot.armedPages.filter { page in
                        !kept.contains { folder, watches in
                            folder != source.folder && watches.contains { $0.sessionID == process.sessionID && $0.pages?.contains(page) ?? true }
                        }
                    }
                    if !pages.isEmpty {
                        left.append(NativeLeftWatch(desktopSessionID: record.sessionID, sessionID: process.sessionID,
                                                    title: record.title, leftAt: milliseconds, pages: pages))
                    }
                }
                // A comment watch alone carries nothing: the conversation stays closed.
                let limitedTurn = runtime?.quotaBlock?.reason == "rateLimit" && runtime?.quotaBlock?.isActive(at: clock.now()) == true
                guard process.busy || runtime?.busy == true || inventory?.isEmpty == false || snapshot.needsContinuation ||
                        limitedTurn else { continue }
                var request = NativeRecoveryRequest(operation: operation, target: identity, work: snapshot, source: process, now: clock.now())
                if let runtime {
                    request.sourceWasBusy = process.busy || runtime.busy || limitedTurn
                    request.sourceUserStopped = runtime.userStopped
                }
                request.sourceActiveTasks = inventory
                request.sourceWasBusy = request.sourceWasBusy || inventory?.isEmpty == false
                // Too large to hand over: nothing is replayed from it, and the conversation still goes on.
                if try JSONEncoder().encode(request).count > requestByteLimit - 2_048 {
                    request.sourceWasBusy = request.sourceWasBusy || snapshot.needsContinuation
                    request.work = snapshot.sizeRefusal()
                }
                made[process.sessionID] = request
            } catch { failures += 1 }
        }
        // A second switch carries unconsumed work forward; the old operation cannot execute it.
        for old in carried where made[old.sessionID] == nil {
            var request = NativeRecoveryRequest(operation: operation, target: identity, work: old.work, source: nil, now: clock.now())
            request.sourceWasBusy = old.sourceWasBusy; request.sourceUserStopped = old.sourceUserStopped
            request.sourceActiveTasks = old.sourceActiveTasks
            request.previousAgentResumeIDs = old.previousAgentResumeIDs
            made[old.sessionID] = request
        }
        // Reattaching a known surviving process is safe even after a claim. Carry only that
        // execution body; the claim still prevents replaying old agent/subscription actions.
        for (old, jobs) in durable {
            let receipt = result(for: old)
            let jobs = jobs.filter { job in
                guard let id = job.jobID, let record = commandRecord(id), ["completed", "failed"].contains(record.status),
                      let snapshot = capturedWork[old.sessionID], snapshot.branchComplete else { return true }
                let ids = Set([job.id] + (job.aliases ?? []) + (receipt?.tasks ?? []).filter { $0.jobID == id }.compactMap(\.newTaskID))
                return !snapshot.tasks.contains { ids.contains($0.id) && $0.kind == job.kind && [.completed, .failed, .stopped].contains($0.state) }
            }
            guard !jobs.isEmpty else { continue }
            var request = made[old.sessionID] ?? NativeRecoveryRequest(operation: operation, target: identity,
                work: old.work.carryingCommands(Set(jobs.map(\.id)), agentIDs: Set(jobs.compactMap(\.agentID))), source: nil, now: clock.now())
            guard !request.sourceUserStopped else { continue }
            var active = request.sourceActiveTasks ?? []
            for var job in jobs {
                let otherIDs = (receipt?.tasks ?? []).filter { $0.jobID == job.jobID }.compactMap(\.newTaskID)
                if let index = active.firstIndex(where: { $0.jobID == job.jobID }) {
                    active[index].aliases = Array(Set((active[index].aliases ?? []) + (job.aliases ?? []) + [job.id] + otherIDs)
                        .subtracting([active[index].id])).sorted()
                    continue
                }
                job.aliases = Array(Set((job.aliases ?? []) + otherIDs)).sorted()
                active.append(job)
            }
            request.sourceActiveTasks = active; request.sourceWasBusy = true
            request.previousAgentResumeIDs = Array(Set((old.previousAgentResumeIDs ?? []) +
                (receipt?.evidence ?? []).filter { $0.tool == "SendMessage" }.compactMap(\.agentID))).sorted()
            made[old.sessionID] = request
        }
        operation.sessionIDs = made.keys.sorted()
        checkpoints = readAhead.filter { made[$0.key] != nil }
        var batch = NativeRecoveryBatch(operation: operation, requests: made.values.sorted { $0.sessionID < $1.sessionID },
                                        captureFailures: failures, commandHolds: holds, leftWatches: left)
        // Capture and validate without mutating shared state. Commit the whole generation
        // against the operation observed before awaits; an older capture cannot win late.
        try withOperationLease {
            guard currentOperationID == previous?.operationID else { throw NativeRecoveryCoordinationError.operationChanged }
            // Nobody gets a batch that cannot all be written, to cancel it: what it wrote over goes
            // back as it was, the generation before included, which may still wait to be taken up.
            let overwritten = try FileSnapshot([directory.appending(path: "active.json")] + batch.requests.flatMap { request in
                [directory.appending(path: "requests/" + request.sessionID + ".json")] +
                    Set((request.sourceActiveTasks ?? []).compactMap(\.jobID)).filter(Self.validID)
                        .map { commandDirectory($0).appending(path: "handoff.json") }
            })
            try write(operation, to: directory.appending(path: "active.json"))
            do {
                for request in batch.requests { try save(request, operationLeaseHeld: true, authorizingCommands: true) }
            } catch {
                overwritten.restore(under: paths.companionDataDirectory)
                checkpoints.removeAll()
                throw error
            }
            replaced = (operation.operationID, overwritten)
        }
        batch.captureFailures += batch.requests.reduce(0) { $0 + commandsWithoutPermit($1) }
        return batch
    }

    static let watchReopenCapability = "watch-reopen-v1"

    /// Kept for the account that closed, for the notice and for its next opening; the latest entry
    /// for a conversation wins. This account's note for a start that did not come goes: the next
    /// opening writes its own, and no start somewhere else may take this one for its own.
    public func recordLeftWatches(_ watches: [NativeLeftWatch], account: ProfileFolder) {
        guard !watches.isEmpty else { return }
        let file = leftWatchesFile(account)
        let kept = (read(file) as [NativeLeftWatch]? ?? []).filter { old in !watches.contains { $0.sessionID == old.sessionID } }
        try? write(Array((kept + watches).suffix(32)), to: file)
        for watch in watches where Self.validID(watch.sessionID) {
            let note = directory.appending(path: "watch-reopen/\(watch.sessionID).json")
            if (read(note) as NativeWatchReopen?)?.account == account.name { try? FileManager.default.removeItem(at: note) }
        }
    }

    /// Every account with conversations waiting for it to open again, a week at most.
    public func leftWatches() -> [ProfileFolder: [NativeLeftWatch]] {
        keptWatches().compactMapValues { watches in
            let waiting = watches.filter { $0.opened != true }
            return waiting.isEmpty ? nil : waiting
        }
    }

    /// Whose pages the kept watches are, a week at most, also once their account has opened.
    private func keptWatches() -> [ProfileFolder: [NativeLeftWatch]] {
        var found: [ProfileFolder: [NativeLeftWatch]] = [:]
        for file in files(directory.appending(path: "left-watches")) where file.pathExtension == "json" {
            guard let folder = try? ProfileFolder(file.deletingPathExtension().lastPathComponent),
                  let watches: [NativeLeftWatch] = read(file) else { continue }
            let recent = watches.filter { milliseconds - $0.leftAt < 7 * 86_400_000 }
            if !recent.isEmpty { found[folder] = recent }
        }
        return found
    }

    /// Before `profile` opens: Desktop is told to start its left conversations, and the plugin that
    /// the start is for the watch alone, in that account. Conversations this opening carries on are
    /// left to it. A conversation that cannot be started is dropped; either way, nothing waits any
    /// more, and the record stays only to tell the other accounts whose pages they are.
    /// Returns those it prepared, to be recorded again if the account does not open after all.
    @discardableResult
    public func prepareLeftWatchReopen(profile: ProfileSnapshot, excluding carried: Set<String>) -> [NativeLeftWatch] {
        let file = leftWatchesFile(profile.folder)
        guard let watches: [NativeLeftWatch] = read(file) else { return [] }
        try? write(watches.map(\.markedOpened), to: file)
        var started: [NativeLeftWatch] = []
        for watch in watches where watch.opened != true && !carried.contains(watch.sessionID) && Self.validID(watch.sessionID) &&
            milliseconds - watch.leftAt < 7 * 86_400_000 {
            // The note goes first: the start it explains may follow at once. Without the start
            // (archived, or waiting for the person), it must not hold back a later continue.
            let note = directory.appending(path: "watch-reopen/\(watch.sessionID).json")
            do {
                try write(NativeWatchReopen(sessionID: watch.sessionID, until: milliseconds + 86_400_000,
                                            account: profile.folder.name), to: note)
                try continuity.prepareNativeRecoveryLaunch(sessionID: watch.desktopSessionID, cliSessionID: watch.sessionID,
                                                           profile: profile, at: clock.now())
                started.append(watch)
            } catch { try? FileManager.default.removeItem(at: note) }
        }
        return started
    }

    /// The account is open already, and not by CC-Relay: Desktop can no longer be told to start the
    /// conversations kept for it, so each picks its watch up when it is opened there. Their record
    /// stays only to tell the other accounts whose pages they are. Returns whether any waited.
    public func markLeftWatchesOpened(account: ProfileFolder) -> Bool {
        let file = leftWatchesFile(account)
        guard let watches: [NativeLeftWatch] = read(file), watches.contains(where: { $0.opened != true }) else { return false }
        try? write(watches.map(\.markedOpened), to: file)
        return true
    }

    /// Which account each open Claude is on, for its conversations to tell the watches kept for
    /// their own account from those kept for another. Written only when that changes.
    public func recordOpenAccounts(_ open: [NativeOpenAccount]) {
        let file = directory.appending(path: "open-accounts.json")
        guard read(file) as [NativeOpenAccount]? != open else { return }
        try? write(open, to: file)
    }

    private func leftWatchesFile(_ account: ProfileFolder) -> URL {
        directory.appending(path: "left-watches/\(account.name).json")
    }

    /// Refresh completion/explicit-stop facts after the source has flushed and exited.
    public func reconcileAfterClose(_ batch: NativeRecoveryBatch, source: ProfileSnapshot) -> NativeRecoveryBatch {
        replaced = nil
        var reconciled = batch
        let records = sourceRecords(source)
        for index in reconciled.requests.indices {
            let old = reconciled.requests[index]
            // Carried work can belong to an earlier account. Work captured from the profile
            // just closed must be verified again, including disappearance or archival.
            let directCapture = old.work.sourceProfile == source.folder.name
            guard directCapture || old.sourceActiveTasks?.contains(where: { $0.jobID != nil }) == true else { continue }
            do {
                guard let identity = source.identity,
                      let record = records.first(where: { $0.sessionID == old.desktopSessionID &&
                          $0.cliSessionID == old.sessionID && !$0.isArchived }) else {
                    throw NativeWorkCaptureFailure.invalidSession
                }
                var checkpoint = checkpoints[old.sessionID]
                let captured: NativeWorkSnapshot?
                do {
                    captured = try capture.capture(ContinuityCapture(record: record, sourceIdentity: identity), profile: source,
                                                   now: clock.now(), checkpoint: &checkpoint)
                } catch NativeWorkCaptureFailure.transcriptMissing {
                    // The conversation itself is gone, like its record above: nothing goes on.
                    throw NativeWorkCaptureFailure.transcriptMissing
                } catch { captured = nil }
                // What Desktop wrote while closing must still make a whole history: work that cannot
                // be followed to its end is not taken for finished, and nothing is replayed from it.
                // The conversation still goes on.
                guard let captured, captured.branchComplete else {
                    reconciled.requests[index].sourceWasBusy = old.sourceWasBusy || old.work.needsContinuation
                    reconciled.requests[index].work = old.work.unverified()
                    try save(reconciled.requests[index])
                    continue
                }
                let selected = directCapture ? captured : captured.carryingCommands(Set((old.sourceActiveTasks ?? []).map(\.id)),
                    agentIDs: Set((old.sourceActiveTasks ?? []).compactMap(\.agentID)))
                let explicitStops = (old.sourceActiveTasks ?? []).filter { live in
                    captured.tasks.contains { task in
                        task.explicitlyStopped == true && ([live.id, live.agentID].compactMap { $0 } + (live.aliases ?? [])).contains(task.id)
                    }
                }
                let finished = old.work.tasks.reduce(into: [String: NativeWorkState]()) { states, task in
                    if [.bash, .monitor].contains(task.kind), [.completed, .failed].contains(task.state) {
                        states[task.toolUseID] = task.state
                    }
                }
                let work = selected.markingFinishedCommands(finished).markingExplicitStops(explicitStops)
                reconciled.requests[index].work = work
                if try JSONEncoder().encode(reconciled.requests[index]).count > requestByteLimit - 2_048 {
                    reconciled.requests[index].sourceWasBusy = old.sourceWasBusy || work.needsContinuation
                    reconciled.requests[index].work = work.sizeRefusal()
                    try save(reconciled.requests[index])
                    continue
                }
                reconciled.requests[index].sourceActiveTasks?.removeAll { live in
                    if explicitStops.contains(where: { $0.id == live.id }) { return true }
                    return work.tasks.contains { task in
                        guard task.id == live.id, task.kind == live.kind, [.completed, .stopped, .failed].contains(task.state) else { return false }
                        // Teardown kills a native output client, not its detached command.
                        if task.state != .completed, let job = live.jobID,
                           let record = commandRecord(job), record.sessionID == old.sessionID,
                           ["starting", "running", "completed", "failed"].contains(record.status),
                           !FileManager.default.fileExists(atPath: commandDirectory(job).appending(path: "stop.json").path) { return false }
                        return true
                    }
                }
                if old.sourceActiveTasks?.isEmpty == false, reconciled.requests[index].sourceActiveTasks?.isEmpty == true,
                   !work.needsContinuation { reconciled.requests[index].sourceWasBusy = false }
                if !work.needsContinuation, work.latestAssistant?.uuid != old.work.latestAssistant?.uuid,
                   work.latestAssistantStopReason == "end_turn" {
                    reconciled.requests[index].sourceWasBusy = false
                }
                if reconciled.requests[index].sourceActiveTasks?.isEmpty == false {
                    reconciled.requests[index].sourceWasBusy = true
                }
                if reconciled.requests[index].phase != "blocked", !reconciled.requests[index].sourceWasBusy, !work.needsContinuation,
                   reconciled.requests[index].sourceActiveTasks?.isEmpty != false {
                    reconciled.requests[index].phase = "resolved"
                }
                try withOperationLease {
                    guard currentOperationID == old.operationID else { return }
                    var stopped = old; stopped.sourceActiveTasks = explicitStops
                    revokeCommands(stopped)
                    // The exit permits were written before Desktop closed. Their window starts
                    // again now that it has, so closing and syncing do not use it up.
                    try save(reconciled.requests[index], operationLeaseHeld: true, authorizingCommands: true)
                }
            } catch {
                reconciled.captureFailures += 1
                reconciled.requests[index].phase = "blocked"
                reconciled.requests[index].activationError = "The original work could not be verified after Desktop closed."
                // Keep the whole operation unready if even the per-session refusal cannot be saved.
                do { try save(reconciled.requests[index]) } catch { try? invalidate(ifCurrent: old.operationID) }
            }
        }
        checkpoints.removeAll()
        return reconciled
    }

    /// Reads the conversations side by side: a long transcript alone takes seconds.
    private func captureAll(_ items: [(String, ContinuityRecord)], source: ProfileSnapshot) async
        -> [String: Result<(NativeWorkSnapshot, NativeCaptureCheckpoint?), any Error>] {
        guard let identity = source.identity else { return [:] }
        let capture = self.capture, now = clock.now()
        return await withTaskGroup(of: (String, Result<(NativeWorkSnapshot, NativeCaptureCheckpoint?), any Error>).self) { group in
            for (session, record) in items {
                group.addTask {
                    var checkpoint: NativeCaptureCheckpoint?
                    let result = Result<(NativeWorkSnapshot, NativeCaptureCheckpoint?), any Error> {
                        let snapshot = try capture.capture(ContinuityCapture(record: record, sourceIdentity: identity),
                                                           profile: source, now: now, checkpoint: &checkpoint)
                        return (snapshot, checkpoint)
                    }
                    return (session, result)
                }
            }
            var results: [String: Result<(NativeWorkSnapshot, NativeCaptureCheckpoint?), any Error>] = [:]
            for await (session, result) in group { results[session] = result }
            return results
        }
    }

    /// Sample a user stop immediately before asking Desktop to exit. An abort caused by that exit
    /// is not evidence that the user cancelled the original work.
    public func refreshSourceStops(_ batch: NativeRecoveryBatch, source: ProfileSnapshot) async -> NativeRecoveryBatch {
        guard let inspector, let identity = source.identity else { return batch }
        var refreshed = batch
        let processes = await inspector.sessions(profile: source.url)
        // An idle source conversation has no request, but it still closes with Desktop.
        // Include work it disclosed after preparation in the manual switch's warning too.
        // Existing requests are checked below, so each process contributes only once here.
        for process in processes where !refreshed.requests.contains(where: {
            $0.sessionID == process.sessionID && $0.sourcePID == process.pid
        }) {
            guard let report = reports(process.sessionID).filter({ $0.pid == process.pid && isFresh($0) })
                    .max(by: { $0.reportedAt < $1.reportedAt }),
                  await inspector.validate(report, profile: source.url, account: identity) else { continue }
            if hostWorkPause(report) != nil { refreshed.captureFailures += 1; refreshed.commandHolds += 1; continue }
            // A durable command can already be carried by a request with no source PID.
            // Count that exact worker only when this batch still has its exit permit;
            // neither a matching session nor a matching host task ID protects new work.
            let carried = refreshed.requests.filter {
                $0.sessionID == process.sessionID && $0.sourcePID == nil && !$0.sourceUserStopped && commandsWithoutPermit($0) == 0
            }.flatMap { $0.sourceActiveTasks ?? [] }
            let uncaptured = report.hostWorkInventory?.backgroundTasks.contains { task in
                // A command the close would end: a shell, or a task attached to a protected one.
                let tracked = Self.tracked(task, in: report)
                guard task.type == "shell" || tracked?.jobID != nil else { return false }
                guard let tracked, let job = tracked.jobID else { return true }
                return !carried.contains { $0.kind == tracked.kind && $0.jobID == job }
            } == true
            if uncaptured { refreshed.captureFailures += 1; refreshed.commandHolds += 1 }
        }
        for index in refreshed.requests.indices {
            let request = refreshed.requests[index]
            guard let sourcePID = request.sourcePID,
                  let report = reports(request.sessionID).sorted(by: { $0.reportedAt > $1.reportedAt })
                    .first(where: { $0.pid == sourcePID && isFresh($0) }),
                  await inspector.validate(report, profile: source.url, account: identity) else { continue }
            refreshed.requests[index].sourceUserStopped = report.userStopped
            if hostWorkPause(report) != nil { refreshed.captureFailures += 1; refreshed.commandHolds += 1 }
            if report.capabilities.contains("native-recovery-v3"), var active = report.activeTasks {
                for job in request.sourceActiveTasks ?? [] {
                    if job.jobID == nil {
                        if !report.userStopped, job.kind == .monitor, (job.registeredAt ?? 0) > report.reportedAt,
                           (job.deadlineAt ?? 0) > milliseconds, !active.contains(where: { $0.id == job.id }) { active.append(job) }
                        continue
                    }
                    guard let jobID = job.jobID, let record = commandRecord(jobID), record.sessionID == request.sessionID,
                          ["starting", "running", "completed", "failed"].contains(record.status),
                          !FileManager.default.fileExists(atPath: commandDirectory(jobID).appending(path: "stop.json").path) else { continue }
                    if let index = active.firstIndex(where: { $0.jobID == jobID }) {
                        active[index].aliases = Array(Set((active[index].aliases ?? []) + (job.aliases ?? []) + [job.id])
                            .subtracting([active[index].id])).sorted()
                    } else { active.append(job) }
                }
                refreshed.requests[index].sourceActiveTasks = active
                // A rate-limited model turn has already left the busy state. The empty tool
                // inventory does not cancel the continuation that prepare captured for it.
                let limitedTurn = !report.userStopped && report.quotaBlock?.reason == "rateLimit" &&
                    report.quotaBlock?.isActive(at: clock.now()) == true
                refreshed.requests[index].sourceWasBusy = report.busy || !active.isEmpty ||
                    processes.contains(where: { $0.pid == sourcePID && $0.busy }) || limitedTurn
            }
            do {
                try save(refreshed.requests[index], authorizingCommands: true)
                refreshed.captureFailures += commandsWithoutPermit(refreshed.requests[index])
            } catch {
                refreshed.captureFailures += 1
                refreshed.requests[index].phase = "blocked"
                refreshed.requests[index].activationError = "The native command handoff could not be saved before Desktop closed."
                try? withOperationLease {
                    guard currentOperationID == request.operationID else { return }
                    revokeCommands(refreshed.requests[index])
                    try save(refreshed.requests[index], operationLeaseHeld: true)
                }
            }
        }
        return refreshed
    }

    /// Called after source close and session sync, before target launch. A continue link alone
    /// does not start an idle/limited conversation's CLI in Desktop. Only this batch's verified
    /// target records receive its native wakeup marker; this does not arm any request. With
    /// `allOrNothing`, the first conversation that cannot be prepared puts back those already
    /// marked, so that an unattended switch can go back leaving no marker on the target.
    public func prepareTargetLaunch(_ batch: NativeRecoveryBatch, profile: ProfileSnapshot, allOrNothing: Bool = false) throws -> Int {
        try withOperationLease {
            guard var operation: NativeRecoveryOperation = read(directory.appending(path: "active.json")),
                  operation.operationID == batch.operation.operationID,
                  operation.targetProfile == profile.folder.name,
                  operation.targetAccountID == profile.identity?.accountUUID else {
                throw NativeRecoveryCoordinationError.operationChanged
            }
            // The freshly started host can emit its native continue before launch returns.
            // Let the plugin hold that prompt now; binding still needs the later OS handshake.
            operation.launchPrepared = true
            try write(operation, to: directory.appending(path: "active.json"))
            var failures = 0, marked: [(sessionID: String, original: Data)] = []
            for var request in requests() where request.operationID == operation.operationID &&
                request.phase == "prepared" && !request.sourceUserStopped && request.expiresAt > milliseconds {
                do {
                    guard request.targetAccountID == operation.targetAccountID,
                          request.targetOrganizationID == profile.identity?.activeOrganizationUUID,
                          request.requiredCapability == "native-recovery-v6" else {
                        throw NativeRecoveryCoordinationError.operationChanged
                    }
                    marked.append((request.desktopSessionID, try continuity.prepareNativeRecoveryLaunch(sessionID: request.desktopSessionID,
                        cliSessionID: request.sessionID, profile: profile, at: clock.now())))
                } catch {
                    failures += 1
                    request.activationError = "The original conversation could not be prepared to start its recovery runtime."
                    _ = try? save(request, operationLeaseHeld: true)
                    if allOrNothing { break }
                }
            }
            if allOrNothing, failures > 0 {
                for record in marked {
                    try? continuity.restoreNativeRecoveryLaunch(sessionID: record.sessionID, profile: profile, original: record.original)
                }
            }
            return failures
        }
    }

    /// Arm no request here. The target OS process, registry, profile and plugin instance must first agree.
    public func activate(_ batch: NativeRecoveryBatch) throws {
        replaced = nil
        try withOperationLease {
            guard var operation: NativeRecoveryOperation = read(directory.appending(path: "active.json")),
                  operation.operationID == batch.operation.operationID else { return }
            operation.primaryDesktopSessionID = batch.operation.primaryDesktopSessionID
            operation.ready = true
            operation.readyAt = milliseconds
            operation.autoActivationUntil = milliseconds + min(300_000, max(90_000, Double(batch.requests.count) * 35_000))
            try write(operation, to: directory.appending(path: "active.json"))
        }
    }

    public func cancel(_ batch: NativeRecoveryBatch?) {
        checkpoints.removeAll()
        guard let batch else { return }
        try? withOperationLease {
            guard currentOperationID == batch.operation.operationID else { return }
            try removeActiveOperation()
            for request in batch.requests { revokeCommands(request) }
            if let replaced, replaced.operationID == batch.operation.operationID {
                replaced.files.restore(under: paths.companionDataDirectory)
            }
        }
    }

    /// The existing switch rollback reopened the source. Rebind its saved work to that account, not the failed target.
    public func redirect(_ batch: NativeRecoveryBatch, to profile: ProfileSnapshot) throws -> NativeRecoveryBatch? {
        try withOperationLease { try redirectHoldingLease(batch, to: profile) }
    }

    private func redirectHoldingLease(_ batch: NativeRecoveryBatch, to profile: ProfileSnapshot) throws -> NativeRecoveryBatch? {
        guard currentOperationID == batch.operation.operationID, let identity = profile.identity else { return nil }
        var operation = NativeRecoveryOperation(operationID: UUID().uuidString, targetProfile: profile.folder.name,
                                                targetAccountID: identity.accountUUID, createdAt: milliseconds)
        operation.ready = true
        operation.readyAt = milliseconds
        operation.primaryDesktopSessionID = batch.operation.primaryDesktopSessionID
        operation.sessionIDs = batch.requests.map(\.sessionID).sorted()
        operation.autoActivationUntil = milliseconds + min(300_000, max(90_000, Double(batch.requests.count) * 35_000))
        let requests = batch.requests.map { old in
            var request = NativeRecoveryRequest(operation: operation, target: identity, work: old.work, source: nil, now: clock.now())
            request.sourceWasBusy = old.sourceWasBusy; request.sourceUserStopped = old.sourceUserStopped
            request.sourceActiveTasks = old.sourceActiveTasks
            request.previousAgentResumeIDs = old.previousAgentResumeIDs
            // A new account/runtime does not undo a failed verification or completed work.
            if !["prepared", "armed"].contains(old.phase) {
                request.phase = old.phase
                request.activationError = old.activationError
            }
            // The rollback process was already launched by the existing lifecycle before this call.
            request.runtimeNotBefore = batch.operation.createdAt
            return request
        }
        try write(operation, to: directory.appending(path: "active.json"))
        for request in requests { try save(request, operationLeaseHeld: true, authorizingCommands: true) }
        return NativeRecoveryBatch(operation: operation, requests: requests, captureFailures: batch.captureFailures)
    }

    public func invalidate() throws {
        try withOperationLease { try removeActiveOperation() }
    }

    private func invalidate(ifCurrent operationID: String) throws {
        try withOperationLease {
            guard currentOperationID == operationID else { return }
            try removeActiveOperation()
        }
    }

    private func removeActiveOperation() throws {
        let path = directory.appending(path: "active.json")
        if let operationID = currentOperationID {
            for request in requests() where request.operationID == operationID { revokeCommands(request) }
        }
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    /// Reads only the operation record, so the engine can ask without taking its gate.
    public func pace() -> NativeRecoveryPace {
        guard let operation: NativeRecoveryOperation = read(directory.appending(path: "active.json")),
              operation.version == 1, operation.ready, operation.finishedAt == nil else { return .idle }
        return milliseconds - operation.createdAt < 15 * 60_000 ? .fast : .slow
    }

    public func poll() async -> NativeRecoverySummary? {
        guard !polling else { return nil }
        polling = true
        defer { polling = false }
        guard let inspector, let operation: NativeRecoveryOperation = read(directory.appending(path: "active.json")),
              operation.version == 1, operation.ready, Self.validID(operation.operationID),
              let folder = try? ProfileFolder(operation.targetProfile) else { return nil }
        let profile = paths.claudeProfilesRoot.appending(path: folder.name)
        guard let config = try? ProfileConfigReader().read(profile: profile),
              let accountID = config.accountUUID, accountID == operation.targetAccountID else { return summary(operation, runtimeUnavailable: true) }
        let identity = AccountIdentity(accountUUID: accountID, activeOrganizationUUID: config.activeOrganizationUUID,
                                       knownOrganizationUUIDs: config.knownOrganizationUUIDs)
        let processes = await inspector.sessions(profile: profile)
        var unavailableSessions = Set<String>()
        let renewalDeadline = (operation.autoActivationUntil ?? operation.createdAt + 300_000) + 300_000
        for var request in requests() where request.operationID == operation.operationID {
            guard currentOperationID == operation.operationID, request.expiresAt > milliseconds,
                  !request.sourceUserStopped,
                  ["prepared", "armed"].contains(request.phase) else { continue }
            renewPermits(request, until: renewalDeadline)
            if request.requiredCapability != "native-recovery-v6" {
                request.runtimeError = "This recovery request was created by an older coordinator and cannot be replayed by the current runtime."
                _ = try? save(request); continue
            }
            if request.targetAccountID != config.accountUUID || request.targetOrganizationID != config.activeOrganizationUUID {
                unavailableSessions.insert(request.sessionID)
                let error = "The recovery account or organization can no longer be verified."
                if request.runtimeError != error { request.runtimeError = error; _ = try? save(request) }
                continue
            }
            if request.phase == "armed" {
                // Binding is immutable for a request ID. A second, newer runtime must never
                // steal a ticket while the first instance is claiming it across this await.
                if Self.settled.contains(result(for: request)?.status ?? "") { continue }
                let runtime = reports(request.sessionID).first {
                    $0.instanceID == request.instanceID && $0.pid == request.pid && $0.procStart == request.procStart
                }
                // A bound runtime is judged by its live process, not by how recently it wrote:
                // a sleeping Mac or a busy host must not revoke a continuation that is running.
                var healthy = false
                if let runtime, targetContains(request, identity: identity, profile: profile), !runtime.userStopped,
                   processes.contains(where: { $0.pid == runtime.pid && $0.sessionID == request.sessionID &&
                       TaskGuardEvaluator.registryStartTime($0.startedAt).split(whereSeparator: \.isWhitespace) ==
                           runtime.procStart.split(whereSeparator: \.isWhitespace) }) {
                    healthy = await inspector.validate(runtime, profile: profile, account: identity)
                }
                guard currentOperationID == operation.operationID else { return nil }
                if !healthy { unavailableSessions.insert(request.sessionID) }
                let error = healthy ? nil : "The bound recovery runtime exited or stopped reporting. Inspect the existing claim before any retry."
                if request.runtimeError != error { request.runtimeError = error; _ = try? save(request) }
                continue
            }
            guard targetContains(request, identity: identity, profile: profile) else { continue }
            guard !hasResultFile(request) else { continue }
            for runtime in reports(request.sessionID).sorted(by: { $0.reportedAt > $1.reportedAt }) {
                guard isFresh(runtime), runtime.capabilities.contains("native-recovery-v6"),
                      !runtime.userStopped,
                      let process = processes.first(where: { $0.pid == runtime.pid && $0.sessionID == request.sessionID }),
                      process.startedAt.timeIntervalSince1970 * 1000 >= request.runtimeNotBefore,
                      runtime.reportedAt >= request.runtimeNotBefore,
                      await inspector.validate(runtime, profile: profile, account: identity),
                      currentOperationID == operation.operationID, !hasResultFile(request) else { continue }
                request.phase = "armed"; request.instanceID = runtime.instanceID; request.pid = runtime.pid
                request.procStart = runtime.procStart; request.armedAt = milliseconds
                request.runtimeStartedAt = process.startedAt.timeIntervalSince1970 * 1000
                request.activationError = nil
                request.runtimeError = nil
                _ = try? save(request)
                break
            }
        }
        guard currentOperationID == operation.operationID else { return nil }
        await activateWaitingConversation(operation, profile: profile, identity: identity, processes: processes)
        guard currentOperationID == operation.operationID else { return nil }
        let result = summary(operation, unavailableSessions: unavailableSessions)
        if result?.finished ?? true { finish(operation) }
        return result
    }

    private func finish(_ operation: NativeRecoveryOperation) {
        let finished = (try? withOperationLease { () -> Bool in
            guard var current: NativeRecoveryOperation = read(directory.appending(path: "active.json")),
                  current.operationID == operation.operationID, current.finishedAt == nil else { return false }
            current.finishedAt = milliseconds
            try write(current, to: directory.appending(path: "active.json"))
            return true
        }) ?? false
        if finished { prune() }
    }

    /// Removes what nothing reads any more: reports of runtimes silent for a day, requests and
    /// receipts of earlier operations after a week, and ended commands with their execution
    /// folder and output after three days. A command whose worker still lives is never touched.
    public func prune() {
        let now = milliseconds, current = currentOperationID, manager = FileManager.default
        for file in files(directory.appending(path: "watch-reopen")) {
            let note: NativeWatchReopen? = read(file)
            if note == nil || note?.used == true || (note?.until ?? 0) <= now { try? manager.removeItem(at: file) }
        }
        for file in files(directory.appending(path: "left-watches")) {
            let watches: [NativeLeftWatch]? = read(file)
            if !(watches ?? []).contains(where: { now - $0.leftAt < 7 * 86_400_000 }) { try? manager.removeItem(at: file) }
        }
        for session in folders(directory.appending(path: "runtimes")) {
            for file in files(session) {
                let report: NativeRuntimeReport? = read(file)
                if now - (report?.reportedAt ?? modified(file)) > 86_400_000 { try? manager.removeItem(at: file) }
            }
            if (try? manager.contentsOfDirectory(atPath: session.path))?.isEmpty == true { try? manager.removeItem(at: session) }
        }
        for file in files(directory.appending(path: "requests")) {
            let request: NativeRecoveryRequest? = read(file, limit: 4_194_304)
            guard request == nil || request?.operationID != current,
                  now - (request?.createdAt ?? modified(file)) > 7 * 86_400_000 else { continue }
            try? manager.removeItem(at: file)
        }
        for file in files(directory.appending(path: "results")) {
            let result: NativeRecoveryResult? = read(file, limit: 4_194_304)
            guard result == nil || result?.operationID != current,
                  now - (result?.updatedAt ?? modified(file)) > 7 * 86_400_000 else { continue }
            try? manager.removeItem(at: file)
        }
        for control in folders(directory.appending(path: "commands")) where Self.validID(control.lastPathComponent) {
            let job = control.lastPathComponent, execution = commandDirectory(job)
            let record: NativeCommandRecord? = read(execution.appending(path: "state.json"))
            if let worker = record?.worker, Self.alive(pid: worker.pid, start: worker.start) { continue }
            guard now - (record?.updatedAt ?? modified(control)) > 3 * 86_400_000 else { continue }
            if execution != control {
                try? manager.removeItem(at: execution)
                let parent = execution.deletingLastPathComponent()
                if (try? manager.contentsOfDirectory(atPath: parent.path))?.isEmpty == true { try? manager.removeItem(at: parent) }
            }
            try? manager.removeItem(at: control)
        }
    }

    /// Final receipts that leave nothing to report: checked, the continuation's turn over, or the
    /// continuation given up to the person, who stopped it or wrote something newer.
    private static let settled: Set<String> = ["inspected", "turnFinished", "yielded"]

    /// Receipt evidence that original work ran in the target account, as the plugin records it.
    private static let executionOutcomes: Set<String> = ["toolResultReturned", "monitorRegistered", "backgroundRegistered",
                                                          "agentResultReturned", "monitorEventObserved", "originalCommandExecutionVerified"]

    /// A request that nothing can move any more: settled before or after the switch, stopped,
    /// expired, refused, or closed by its continuation's own final receipt.
    private func isFinal(_ request: NativeRecoveryRequest) -> Bool {
        if ["resolved", "blocked"].contains(request.phase) || request.sourceUserStopped || request.expiresAt <= milliseconds
            || request.requiredCapability != "native-recovery-v6" { return true }
        let status = result(for: request)?.status ?? ""
        return Self.settled.contains(status) || status == "needsAttention"
    }

    /// Open one saved conversation at a time. A runtime handshake, not delivery of the link,
    /// allows the next one. Persist before sending so an app restart cannot create an open loop.
    private func activateWaitingConversation(_ operation: NativeRecoveryOperation, profile: URL,
                                             identity: AccountIdentity, processes: [NativeProcessSession]) async {
        guard let opener, let deadline = operation.autoActivationUntil,
              currentOperationID == operation.operationID else { return }
        let current = requests().filter { $0.operationID == operation.operationID }
        let pending = current.filter { $0.phase == "prepared" &&
            !$0.sourceUserStopped && !hasResultFile($0) && $0.expiresAt > milliseconds }
        for var request in pending where request.activationError == nil {
            if let attempted = request.activationAttemptedAt {
                if milliseconds - attempted < 30_000 { return }
                request.activationError = "The original conversation did not report a matching recovery runtime."
                _ = try? save(request)
                return
            }
        }
        if var request = pending.first(where: { $0.activationError == nil && $0.activationAttemptedAt == nil }) {
            guard milliseconds <= deadline else { return }
            guard targetContains(request, identity: identity, profile: profile) else {
                request.activationError = "The original conversation is unavailable in the target account."
                _ = try? save(request); return
            }
            request.activationAttemptedAt = milliseconds
            // A live CLI may still be loading the plugin. Give it the same handshake window.
            let alreadyOpen = processes.contains { $0.sessionID == request.sessionID &&
                $0.startedAt.timeIntervalSince1970 * 1000 >= request.runtimeNotBefore }
            request.activationSent = !alreadyOpen
            do { guard try save(request, reservingActivation: true) else { return } } catch { return }
            if alreadyOpen { return }
            do {
                try await opener.open(profile: profile, account: identity, desktopSessionID: request.desktopSessionID)
            } catch {
                guard currentOperationID == operation.operationID else { return }
                request.activationError = "The original conversation could not be opened automatically."
                _ = try? save(request)
            }
            return
        }
        // Opening background conversations changes the selected chat. Return once to the chat
        // the user was using, without repeatedly stealing focus or starting another app instance.
        guard pending.allSatisfy({ $0.activationError != nil }),
              current.contains(where: { $0.activationSent == true && $0.desktopSessionID != operation.primaryDesktopSessionID }),
              operation.focusRestoreAttemptedAt == nil, milliseconds <= deadline,
              let primary = operation.primaryDesktopSessionID else { return }
        do {
            let reserved = try withOperationLease {
                guard var updated: NativeRecoveryOperation = read(directory.appending(path: "active.json")),
                      updated.operationID == operation.operationID, updated.focusRestoreAttemptedAt == nil else { return false }
                updated.focusRestoreAttemptedAt = milliseconds
                try write(updated, to: directory.appending(path: "active.json"))
                return true
            }
            guard reserved else { return }
        } catch { return }
        try? await opener.open(profile: profile, account: identity, desktopSessionID: primary)
    }

    private func summary(_ operation: NativeRecoveryOperation, runtimeUnavailable: Bool = false,
                         unavailableSessions: Set<String> = []) -> NativeRecoverySummary? {
        var summary = NativeRecoverySummary(operationID: operation.operationID)
        summary.from = operation.sourceProfile.flatMap { try? ProfileFolder($0) }
        summary.to = try? ProfileFolder(operation.targetProfile)
        summary.settling = milliseconds < (operation.readyAt ?? operation.createdAt) + NativeRecoverySummary.settlingTime * 1000
        func attention(_ sessionID: String, _ reason: NativeRecoveryIssue.Reason) {
            summary.attention += 1
            summary.issues = (summary.issues ?? []) + [NativeRecoveryIssue(sessionID: sessionID, reason: reason)]
        }
        let current = requests().filter { $0.operationID == operation.operationID }
        for session in Set(operation.sessionIDs ?? []).subtracting(current.map(\.sessionID)).sorted() {
            attention(session, .missingRecord)
        }
        for request in current {
            let session = request.desktopSessionID
            if request.requiredCapability != "native-recovery-v6" { attention(session, .incompatibleRuntime); continue }
            if request.phase == "resolved" { summary.inspected += 1; continue }
            if request.phase == "blocked" { attention(session, .blocked); continue }
            // What the person did themselves, stopping the reply before the switch or taking over
            // after it, is neither a problem nor news to them: it is not counted. The protected
            // background commands that reply left running ended with the switch, and that is told.
            if request.sourceUserStopped { summary.endedWithSwitch += endedWithSwitch(request); continue }
            let receipt = result(for: request)
            if request.runtimeError != nil || runtimeUnavailable || unavailableSessions.contains(request.sessionID),
               !Self.settled.contains(receipt?.status ?? "") {
                attention(session, .runtimeUnavailable); continue
            }
            // Expiry stops new recovery actions. It does not erase a verified final receipt.
            if request.expiresAt <= milliseconds, !Self.settled.contains(receipt?.status ?? "") {
                attention(session, .expired); continue
            }
            guard let report = receipt else {
                if hasResultFile(request) || request.activationError != nil ||
                    (opener != nil && request.phase != "armed" && (operation.autoActivationUntil ?? .infinity) < milliseconds) {
                    attention(session, hasResultFile(request) ? .missingRecord : .conversationUnavailable)
                } else { summary.waiting += 1 }
                continue
            }
            switch report.status {
            case "waiting": summary.waiting += 1
            case "claimed", "submitted", "queued":
                if report.evidence.contains(where: { Self.executionOutcomes.contains($0.outcome) }) {
                    summary.executing += 1
                } else { summary.submitted += 1 }
            case "executing": summary.executing += 1
            case "inspected": summary.inspected += 1
            case "turnFinished":
                // A turn whose every step failed needs the person; one that did something, or
                // finished in words alone, ran.
                let failedOnly = report.evidence.contains { $0.outcome == "blockedOrFailed" }
                    && !report.evidence.contains { Self.executionOutcomes.contains($0.outcome) }
                if failedOnly { attention(session, .executionFailed) } else { summary.ended += 1 }
            case "yielded": break
            default: attention(session, .recoveryIncomplete)
            }
        }
        summary.issues?.sort { $0.sessionID < $1.sessionID }
        // Still looked at until the settling ends, so that a problem held back meanwhile is shown.
        summary.finished = current.allSatisfy(isFinal) && !summary.settling
        return summary.total == 0 ? nil : summary
    }

    /// The protected background commands a reply stopped by hand left running, which the switch
    /// then ended: no permit carried them across. One that ended by itself, or was stopped before
    /// the switch began, is not counted.
    private func endedWithSwitch(_ request: NativeRecoveryRequest) -> Int {
        Set((request.sourceActiveTasks ?? []).compactMap(\.jobID)).filter { job in
            guard let record = commandRecord(job), record.sessionID == request.sessionID else { return false }
            switch record.status {
            case "starting", "running", "stopping": return true
            case "stopped", "attention": return (record.updatedAt ?? 0) >= request.createdAt
            default: return false
            }
        }.count
    }

    private func targetContains(_ request: NativeRecoveryRequest, identity: AccountIdentity, profile: URL) -> Bool {
        guard request.targetAccountID == identity.accountUUID, request.targetOrganizationID == identity.activeOrganizationUUID,
              let org = identity.activeOrganizationUUID,
              let bucket = try? SessionBucket(accountUUID: identity.accountUUID, organizationUUID: org),
              let record = try? continuity.readRecord(at: profile.appending(path: bucket.relativePath).appending(path: request.desktopSessionID + ".json")) else { return false }
        return record.sessionID == request.desktopSessionID && record.cliSessionID == request.sessionID && !record.isArchived
    }

    private func sourceRecords(_ profile: ProfileSnapshot) -> [ContinuityRecord] {
        guard let bucket = profile.readableBucket else { return [] }
        return files(profile.url.appending(path: bucket.relativePath)).compactMap { file in
            guard SessionFileIO.isSession(file.lastPathComponent) else { return nil }
            return try? continuity.readRecord(at: file)
        }
    }
    private var milliseconds: Double { clock.now().timeIntervalSince1970 * 1000 }
    private var currentOperationID: String? {
        let operation: NativeRecoveryOperation? = read(directory.appending(path: "active.json")); return operation?.operationID
    }
    private func isFresh(_ report: NativeRuntimeReport) -> Bool {
        report.version == 1 && Self.validID(report.sessionID) && Self.validID(report.instanceID) && report.pid > 1 &&
        report.reportedAt <= milliseconds + 1000 && milliseconds - report.reportedAt < 30_000
    }
    private func reports(_ sessionID: String) -> [NativeRuntimeReport] {
        guard Self.validID(sessionID) else { return [] }
        return files(directory.appending(path: "runtimes/" + sessionID)).compactMap { file in
            let report: NativeRuntimeReport? = read(file)
            return report?.sessionID == sessionID ? report : nil
        }
    }
    private func requests() -> [NativeRecoveryRequest] {
        files(directory.appending(path: "requests")).compactMap { file in
            let request: NativeRecoveryRequest? = read(file, limit: 4_194_304)
            guard let request, request.version == 1, Self.validID(request.requestID), Self.validID(request.sessionID),
                  request.desktopSessionID.hasPrefix("local_"), Self.validID(String(request.desktopSessionID.dropFirst(6))) else { return nil }
            return request
        }
    }
    private func result(for request: NativeRecoveryRequest) -> NativeRecoveryResult? {
        guard let result: NativeRecoveryResult = read(directory.appending(path: "results/" + request.requestID + ".json"), limit: 4_194_304),
              result.version == 1, result.requestID == request.requestID, result.operationID == request.operationID,
              result.sessionID == request.sessionID, result.instanceID == request.instanceID,
              result.pid == request.pid else { return nil }
        return result
    }

    private func finishedCommandToolUses(_ request: NativeRecoveryRequest) -> [String: NativeWorkState] {
        // A later handoff can contain only artifact work. Keep terminal command facts
        // already established in its snapshot even though its active inventory is empty.
        var finished = request.work.tasks.reduce(into: [String: NativeWorkState]()) { states, task in
            if [.bash, .monitor].contains(task.kind), [.completed, .failed].contains(task.state), !task.toolUseID.isEmpty {
                states[task.toolUseID] = task.state
            }
        }
        guard let receipt = result(for: request), receipt.status == "turnFinished" else { return finished }
        for task in request.sourceActiveTasks ?? [] {
            guard let job = task.jobID, let use = task.toolUseID, !use.isEmpty,
                  let record = commandRecord(job), record.executionProtocol == 3,
                  record.sessionID == request.sessionID,
                  ["completed", "failed"].contains(record.status),
                  receipt.tasks?.contains(where: { $0.jobID == job && $0.status == record.status }) == true else { continue }
            finished[use] = record.status == "completed" ? .completed : .failed
        }
        return finished
    }
    private func bridgeRegisteredMonitors(_ old: NativeRecoveryRequest, runtime: NativeRuntimeReport,
                                         active: [NativeRuntimeTask], work: NativeWorkSnapshot) -> [NativeRuntimeTask] {
        guard old.requiredCapability == "native-recovery-v6", old.expiresAt > milliseconds,
              !old.sourceUserStopped, !runtime.userStopped, work.branchComplete,
              old.pid == runtime.pid, old.instanceID == runtime.instanceID, old.procStart == runtime.procStart,
              let receipt = result(for: old) else { return active }
        var inventory = active
        for item in receipt.tasks ?? [] {
            guard item.jobID == nil, let id = item.newTaskID, Self.validID(id),
                  ["registered", "listening"].contains(item.status), let registered = item.registeredAt,
                  registered > runtime.reportedAt, registered <= milliseconds + 1_000,
                  let original = old.sourceActiveTasks?.first(where: { $0.id == item.sourceTaskID && $0.kind == .monitor && $0.jobID == nil }),
                  (original.deadlineAt ?? 0) > milliseconds,
                  !inventory.contains(where: { $0.id == id }),
                  !work.tasks.contains(where: { ($0.id == id || $0.id == original.id) &&
                      ($0.explicitlyStopped == true || [.completed, .failed].contains($0.state)) }) else { continue }
            var task = original; task.id = id; task.registeredAt = registered
            task.aliases = Array(Set((original.aliases ?? []) + [original.id]).subtracting([id])).sorted()
            inventory.append(task)
        }
        return inventory
    }
    private func hasResultFile(_ request: NativeRecoveryRequest) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: "results/" + request.requestID + ".json").path)
    }
    private func withOperationLease<T>(_ body: () throws -> T) throws -> T {
        let lease: CompanionFileLease
        do { lease = try CompanionFileLease(file: directory.appending(path: "locks/operation.lock"), waitMilliseconds: 100) }
        catch CompanionFileLeaseError.busy { throw NativeRecoveryCoordinationError.operationChanged }
        defer { lease.release() }
        return try body()
    }

    @discardableResult
    private func save(_ request: NativeRecoveryRequest, operationLeaseHeld: Bool = false,
                      authorizingCommands: Bool = false, reservingActivation: Bool = false) throws -> Bool {
        if !operationLeaseHeld {
            return try withOperationLease {
                try save(request, operationLeaseHeld: true, authorizingCommands: authorizingCommands, reservingActivation: reservingActivation)
            }
        }
        guard Self.validID(request.sessionID) else { return false }
        let data = try JSONEncoder().encode(request)
        guard data.count <= requestByteLimit else { throw NativeWorkCaptureFailure.transcriptTooLarge }
        let file = directory.appending(path: "requests/" + request.sessionID + ".json")
        let locks = directory.appending(path: "locks")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockFile = locks.appending(path: request.sessionID + ".lock")
        let fd = Darwin.open(lockFile.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw AtomicFileError.writeFailed(file, errno: errno) }
        defer { _ = Darwin.close(fd) }
        // This section has no await. Separate CC-Relay processes/coordinators cannot both
        // commit competing bindings; the OS releases the lock even after a process crash.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AtomicFileError.writeFailed(file, errno: errno) }
        defer { _ = flock(fd, LOCK_UN) }
        guard currentOperationID == request.operationID else { return false }
        let existing: NativeRecoveryRequest? = read(file, limit: 4_194_304)
        if let existing,
           existing.requestID == request.requestID, existing.operationID == request.operationID {
            if ["blocked", "resolved"].contains(existing.phase), request.phase != existing.phase { return false }
            if existing.sourceUserStopped, !request.sourceUserStopped { return false }
            if reservingActivation, existing.activationAttemptedAt != nil || existing.phase != "prepared" { return false }
            if existing.phase == "armed" {
                guard request.phase == "armed", request.pid == existing.pid,
                      request.instanceID == existing.instanceID, request.procStart == existing.procStart else { return false }
            } else if request.phase == "armed", hasResultFile(request) { return false }
        }
        if request.sourceUserStopped { revokeCommands(request) }
        if (request.phase == "armed" && existing?.phase != "armed") || (authorizingCommands && request.phase == "prepared") { try authorizeCommands(request) }
        try AtomicFile.write(data, to: file, protectedRoot: paths.companionDataDirectory)
        return true
    }

    private func commandDirectory(_ job: String) -> URL {
        let control = directory.appending(path: "commands/" + job)
        if let location: NativeCommandLocation = read(control.appending(path: "location.json")), location.version == 1,
           location.jobID == job {
            let physical = URL(fileURLWithPath: location.directory).standardizedFileURL
            let temporary = URL(fileURLWithPath: "/private/tmp/cc-relay-native-\(getuid())").standardizedFileURL
            if physical.lastPathComponent == job, physical.deletingLastPathComponent().deletingLastPathComponent().path == temporary.path,
               physical.resolvingSymlinksInPath().path == physical.path { return physical }
        }
        return control
    }
    private func commandRecord(_ job: String) -> NativeCommandRecord? {
        guard Self.validID(job), let record: NativeCommandRecord = read(commandDirectory(job).appending(path: "state.json")),
              record.version == 1, record.jobID == job else { return nil }
        return record
    }
    /// The protected commands of `request` that may still run without an exit permit from its
    /// operation: closing Desktop ends them. One being stopped, or already over, needs none.
    private func commandsWithoutPermit(_ request: NativeRecoveryRequest) -> Int {
        guard !request.sourceUserStopped else { return 0 }
        return Set((request.sourceActiveTasks ?? []).compactMap(\.jobID)).filter { job in
            guard let record = commandRecord(job) else { return true }
            guard ["starting", "running"].contains(record.status),
                  !FileManager.default.fileExists(atPath: commandDirectory(job).appending(path: "stop.json").path) else { return false }
            let permit: NativeCommandPermit? = read(commandDirectory(job).appending(path: "handoff.json"))
            return permit?.jobID != job || permit?.operationID != request.operationID || (permit?.expiresAt ?? 0) <= milliseconds
        }.count
    }
    private func authorizeCommands(_ request: NativeRecoveryRequest) throws {
        guard !request.sourceUserStopped else { return }
        for job in Set((request.sourceActiveTasks ?? []).compactMap(\.jobID)) {
            guard Self.validID(job) else { continue }
            let lease = try CompanionFileLease(file: commandDirectory(job).appending(path: "ownership.lock"), waitMilliseconds: 250)
            defer { lease.release() }
            guard let record = commandRecord(job), record.executionProtocol == 3, record.sessionID == request.sessionID,
                  ["starting", "running", "completed", "failed"].contains(record.status) else { continue }
            if let sourcePID = request.sourcePID, request.phase == "prepared" {
                let owns = record.owner.pid == sourcePID && request.sourceStartedAt.map { abs($0 - record.owner.start) < 0.01 } == true
                let prior: NativeCommandPermit? = read(commandDirectory(job).appending(path: "handoff.json"))
                let pending = prior?.jobID == job && prior?.sessionID == request.sessionID &&
                    prior?.targetPID == sourcePID && (prior?.expiresAt ?? 0) > milliseconds &&
                    prior?.sourcePID == record.owner.pid &&
                    prior?.sourceStartedAt == record.owner.start && prior?.targetStartedAt == request.sourceStartedAt
                guard owns || pending else { continue }
            }
            let permit = NativeCommandPermit(version: 1, jobID: job, sessionID: request.sessionID,
                operationID: request.operationID, sourcePID: record.owner.pid, sourceStartedAt: record.owner.start,
                expiresAt: milliseconds + 300_000, targetPID: request.phase == "armed" ? request.pid : nil,
                targetStartedAt: request.phase == "armed" ? request.runtimeStartedAt : nil,
                requestID: request.phase == "armed" ? request.requestID : nil,
                targetInstanceID: request.phase == "armed" ? request.instanceID : nil)
            try write(permit, to: commandDirectory(job).appending(path: "handoff.json"))
        }
    }
    /// Keeps a command alive while its conversation waits to be opened in the target account.
    /// Only a permit for the source owner is extended: once the target adopted the command, its
    /// own exit must end the command again, as in any conversation.
    private func renewPermits(_ request: NativeRecoveryRequest, until deadline: Double) {
        guard milliseconds < deadline else { return }
        for job in Set((request.sourceActiveTasks ?? []).compactMap(\.jobID)) where Self.validID(job) {
            let file = commandDirectory(job).appending(path: "handoff.json")
            guard let current: NativeCommandPermit = read(file), current.operationID == request.operationID,
                  current.expiresAt > milliseconds, current.expiresAt - milliseconds < 120_000,
                  let lease = try? CompanionFileLease(file: commandDirectory(job).appending(path: "ownership.lock"), waitMilliseconds: 50) else { continue }
            defer { lease.release() }
            guard var permit: NativeCommandPermit = read(file), permit == current,
                  let record = commandRecord(job), record.sessionID == request.sessionID,
                  ["starting", "running"].contains(record.status),
                  record.owner.pid == permit.sourcePID, abs(record.owner.start - permit.sourceStartedAt) < 0.01 else { continue }
            permit.expiresAt = milliseconds + 300_000
            try? write(permit, to: file)
        }
    }
    private func revokeCommands(_ request: NativeRecoveryRequest) {
        for job in Set((request.sourceActiveTasks ?? []).compactMap(\.jobID)) where Self.validID(job) {
            let file = commandDirectory(job).appending(path: "handoff.json")
            if let permit: NativeCommandPermit = read(file), permit.operationID == request.operationID {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
    private func read<T: Decodable>(_ path: URL, limit: Int = 2_097_152) -> T? {
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit,
              let data = try? AtomicFile.read(path) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private func write<T: Encodable>(_ value: T, to path: URL) throws {
        try AtomicFile.write(JSONEncoder().encode(value), to: path, protectedRoot: paths.companionDataDirectory)
    }
    private func folders(_ directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false }
    }
    private func modified(_ url: URL) -> Double {
        ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000
    }
    /// The same process the record names: its PID and microsecond birth time, so a reused PID never counts.
    private static func alive(pid: Int32, start: Double) -> Bool {
        var info = proc_bsdinfo()
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_status != SZOMB else { return false }
        return abs((Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000) * 1000 - start) < 0.01
    }
    private func files(_ directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? [])
            .filter { $0.pathExtension == "json" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
    private static func validID(_ id: String) -> Bool { AutoCompactLink.validSessionID(id) }
}

private struct NativeCommandRecord: Decodable {
    struct Owner: Decodable { var pid: Int32; var start: Double }
    var version: Int; var jobID: String; var sessionID: String; var status: String; var owner: Owner
    var executionProtocol: Int?
    var worker: Owner?
    var updatedAt: Double?
}
private struct NativeCommandLocation: Decodable { var version: Int; var jobID: String; var directory: String }
private struct NativeCommandPermit: Codable, Equatable {
    var version: Int; var jobID: String; var sessionID: String; var operationID: String
    var sourcePID: Int32; var sourceStartedAt: Double; var expiresAt: Double
    var targetPID: Int32?; var targetStartedAt: Double?; var requestID: String?
    var targetInstanceID: String?
}

/// Files as they were before a write that may have to be taken back: each one's bytes, or none
/// where it did not exist yet. One that is there but cannot be read could not be put back, so the
/// snapshot fails before anything is written over it.
private struct FileSnapshot {
    private let files: [(url: URL, data: Data?)]

    init(_ urls: [URL]) throws {
        files = try urls.map { url -> (url: URL, data: Data?) in
            do { return (url, try AtomicFile.read(url)) } catch let error as AtomicFileError {
                if case .notFound = error { return (url, nil) }
                throw error
            }
        }
    }

    /// Best effort: whatever differs now is written back, or removed where there was nothing.
    func restore(under root: URL) {
        for file in files where (try? AtomicFile.read(file.url)) != file.data {
            if let data = file.data { try? AtomicFile.write(data, to: file.url, protectedRoot: root) }
            else { try? FileManager.default.removeItem(at: file.url) }
        }
    }
}
