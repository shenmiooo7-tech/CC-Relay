import Foundation

public actor CompanionEngine: CompanionFacade {
    private let paths: AppPaths
    private let store: StateStore
    private let cache: QuotaCacheStore
    private let processes: any ClaudeProcessControlling
    private let quota: any QuotaStatusProviding
    private let login: any LoginItemManaging
    private let revealer: any FileRevealing
    private let plugin: any ClaudeCodePluginInstalling
    private let monitor: (any ClaudeLaunchMonitoring)?
    private let executable: URL
    private let clock: any Clock
    private let log: CompanionLog
    private let gate: OperationGate
    private let debt: RelaunchDebt
    private let lifecycle: ClaudeLifecycle
    private let taskGuard: TaskGuard
    private let compactionWait = CompactionWait()
    private let switches: SwitchCoordinator
    private let accounts: AccountManager
    private let history: HistoryImporter
    private let corrector: LaunchCorrector
    private let scanner: ProfileScanner
    private let autoCompact: AutoCompactLink
    private let nativeRecovery: NativeRecoveryCoordinator
    private var nativeRecoveryTask: Task<Void, Never>?
    private var nativeRecoveryNotice: NativeRecoverySummary?
    /// A finished operation's notice, once shown in the panel, goes when the panel closes.
    private var nativeRecoveryNoticeSeen = false
    private let preferredLanguages: @Sendable () -> [String]
    /// The latest compaction the plugin reported, shown until the panel has shown it and closed.
    private var compactionNotice: AutoCompactResult?
    private var compactionNoticeSeen = false
    private nonisolated let hub: SnapshotHub
    private let automaticallyPoll: Bool
    private let onQuit: @Sendable () async -> Void
    /// Whether the app found Claude when it started.
    private let claudeFound: Bool
    private var startup: Task<Void, Never>?
    private var finishing: Task<Void, Never>?
    private var quotaTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    private var confirmationTasks: [UUID: Task<Void, Never>] = [:]
    /// The newest result made, still known after the panel has dismissed it.
    private var latestResultID: UUID?
    private var snapshot: CompanionSnapshot
    private var state = CompanionState()
    private var profiles: [ProfileSnapshot] = []
    private var readings: [ProfileFolder: QuotaReading] = [:]
    private var details: [ProfileFolder: AccountRecord] = [:]
    private var newlySignedIn: Set<ProfileFolder> = []
    private var panelIsOpen = false
    private var stopped = false
    private var signInMismatch: Set<ProfileFolder> = []
    private var lastQuotaFolder: ProfileFolder?
    private var quotaStarted = false
    private var automaticBanner: Banner?
    private var autoSwitchPause: AutoSwitchPauseReason?
    /// When the paused automatic switching tries again, where that is known.
    private var autoSwitchRetry: Date?
    private var checkingAutomaticSwitch = false
    private var nextAutomaticCheck = Date.distantPast
    /// A rejected account must not be selected again from an older, still-positive web reading.
    private var automaticExclusions: [String: Date] = [:]
    /// The login an automatic switch closed Claude for and could not leave; no automatic switch
    /// leaves it again until then. Turning automatic switching off and on ends it.
    private var automaticHold: (login: String, until: Date)?
    /// Logins set aside because they cannot carry a bypass-mode conversation on, and the best of
    /// them to name when nothing else is left.
    private var automaticBypassMisses: Set<String> = []
    private var bypassCandidate: ProfileFolder?
    /// After no account could take over, when one may first have become usable, for the source and
    /// the accounts it was worked out for. Turning automatic switching on again drops it.
    private var alternativesWait: (until: Date, basis: [String])?
    /// The last automatic switch a limit report alone caused: the login it went to, and when it began.
    private var limitSwitch: (login: String, at: Date)?
    /// The report a `limitRepeated` pause stands on, which the account was read for once.
    private var heldLimit: Double?
    /// Accounts holding conversations that wait for them to open again, for their comment watch.
    private var leftWatches: [ProfileFolder: [NativeLeftWatch]] = [:]
    /// Main instances from the last scan, so a dismissed account that Claude has open is offered again.
    private var openInstances: [ClaudeInstance] = []
    /// Accounts dismissed while Claude had them open. They are not offered again until Claude has
    /// closed them, or "dismiss" would do nothing while they stay open.
    private var dismissedWhileOpen: Set<ProfileFolder> = []

    public init(paths: AppPaths, processes: any ClaudeProcessControlling, tasks: any CodeTaskInspecting,
                cookies: any SessionCookieReading,
                quota: any QuotaStatusProviding, accountDetails: any AccountDetailsProviding,
                loginItems: any LoginItemManaging, fileRevealer: any FileRevealing,
                launchMonitor: (any ClaudeLaunchMonitoring)? = nil,
                executable: URL, clock: any Clock = SystemClock(), appVersion: String = "0.1.0",
                automaticallyPoll: Bool = true, log: CompanionLog? = nil,
                nativeRuntimeInspector: (any NativeRuntimeInspecting)? = nil,
                nativeConversationOpener: (any NativeConversationOpening)? = nil,
                plugin: any ClaudeCodePluginInstalling = ReadyClaudeCodePlugin(),
                preferredLanguages: @escaping @Sendable () -> [String] = { Locale.preferredLanguages },
                claudeFound: Bool = true,
                onQuit: @escaping @Sendable () async -> Void = {}) {
        self.paths = paths
        self.processes = processes
        self.quota = quota
        login = loginItems
        revealer = fileRevealer
        self.plugin = plugin
        monitor = launchMonitor
        self.executable = executable
        self.clock = clock
        self.automaticallyPoll = automaticallyPoll
        self.onQuit = onQuit
        self.preferredLanguages = preferredLanguages
        self.claudeFound = claudeFound
        let log = log ?? CompanionLog(paths: paths, clock: clock)
        self.log = log
        let store = StateStore(paths: paths, log: log, clock: clock)
        self.store = store
        let cache = QuotaCacheStore(paths: paths, log: log, clock: clock)
        self.cache = cache
        gate = OperationGate(log: log)
        let debt = RelaunchDebt(store: store)
        self.debt = debt
        let lifecycle = ClaudeLifecycle(processes: processes, tasks: tasks, debt: debt, paths: paths, log: log)
        self.lifecycle = lifecycle
        let taskGuard = TaskGuard(inspector: tasks, clock: clock)
        self.taskGuard = taskGuard
        let nativeRecovery = NativeRecoveryCoordinator(paths: paths, inspector: nativeRuntimeInspector,
                                                       opener: nativeConversationOpener, clock: clock)
        self.nativeRecovery = nativeRecovery
        switches = SwitchCoordinator(paths: paths, store: store, lifecycle: lifecycle,
                                     taskGuard: taskGuard, compactionWait: compactionWait, clock: clock, log: log, recovery: nativeRecovery)
        accounts = AccountManager(paths: paths, store: store, lifecycle: lifecycle, taskGuard: taskGuard,
            cookies: cookies, details: accountDetails, cache: cache, clock: clock, log: log)
        history = HistoryImporter(paths: paths, store: store, lifecycle: lifecycle,
                                  taskGuard: taskGuard, clock: clock, log: log)
        corrector = LaunchCorrector(clock: clock)
        scanner = ProfileScanner(paths: paths)
        autoCompact = AutoCompactLink(paths: paths)
        snapshot = .empty(appVersion: appVersion)
        hub = SnapshotHub(.empty(appVersion: appVersion))
    }

    public nonisolated func snapshots() -> AsyncStream<CompanionSnapshot> {
        let stream = hub.stream()
        Task { await self.start() }
        return stream
    }

    public func currentSnapshot() -> CompanionSnapshot { snapshot }

    public func start() async {
        if let startup { await startup.value; return }
        let work = Task { await self.initialize() }
        startup = work
        await work.value
    }

    private func initialize() async {
        // Which build ran from when, for reading the log after an update.
        log.info(.app, "Started version \(snapshot.appVersion).")
        do {
            let firstRun = !FileManager.default.fileExists(atPath: paths.companionDataDirectory.appending(path: "state.json").path)
            state = try await store.load()
            if firstRun || !FileManager.default.fileExists(atPath: paths.companionDataDirectory.appending(path: "state.json").path) {
                let found = try scanner.scan().profiles.filter { $0.identity != nil }
                let cached = try await cache.load()
                var initial: [ManagedAccount] = []
                for profile in found {
                    let cachedEmail = cached[profile.folder].flatMap { value in
                        profile.identity?.matches(account: value.accountUUID, organization: value.organizationUUID) == true ? value.email : nil
                    }
                    let proposed = AccountManager.emailName(cachedEmail) ?? (profile.folder.isDefault ?
                        AccountManager.placeholder(language: state.settings.language, firstRun: true) :
                        String(profile.folder.name.dropFirst("Claude_".count)))
                    initial.append(ManagedAccount(folder: profile.folder,
                        displayName: AccountManager.uniqueName(proposed, accounts: initial), addedAt: clock.now(),
                        nameIsAutomatic: AccountManager.emailName(cachedEmail) == nil))
                }
                let initialAccounts = initial
                let running = try await processes.runningInstances()
                let active = initial.first { account in
                    running.contains { ProfilePaths.same($0.profileDirectory, directory(account.folder)) }
                }?.folder ?? initial.first?.folder
                try await store.update { $0.accounts = initialAccounts; $0.activeFolder = active }
                state = try await store.load()
            }
            if state.settings.launchAtLogin {
                do {
                    if try await !login.isEnabled { try await login.enable(executable: executable) }
                } catch {
                    try await store.update { $0.settings.launchAtLogin = false }
                    state = try await store.load()
                    log.warning(.app, "The configured login item could not be enabled.")
                }
            }
            // Owed profiles open now even beside a Claude that is open (one already open is not
            // launched twice); otherwise a record would wait for some later switch or quit.
            if !state.relaunchDebt.isEmpty { try await lifecycle.relaunchOwed() }
        } catch { log.warning(.app, "Startup state or relaunch recovery could not be completed.") }
        writeAutoCompactSettings(enabled: state.settings.autoCompactOnLowQuota, language: state.settings.language)
        snapshot.pluginReady = await plugin.isReady()
        Task { [weak self] in await self?.updatePluginIfNeeded() }
        leftWatches = await nativeRecovery.leftWatches()
        await rescan()
        if let monitor {
            let events = monitor.launches()
            launchTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { return }
                    await self?.handleLaunch(event)
                }
            }
        }
        scheduleScan()
        scheduleSignIn()
        if automaticallyPoll {
            nativeRecoveryTask = Task { [weak self, clock] in
                await self?.nativeRecovery.prune()
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.checkAutomaticSwitch()
                    let seconds = await self.pollNativeRecovery()
                    let delay = await self.automaticPollDelay(seconds)
                    do { try await clock.sleep(for: .seconds(delay)) } catch { return }
                }
            }
        }
        Task { [weak self] in await self?.runReadyHistory() }
    }

    public func perform(_ action: CompanionAction) async {
        _ = await performWithReceipt(action)
    }

    public func performWithReceipt(_ action: CompanionAction) async -> CompanionActionReceipt {
        // Viewing local records must not start the engine or run the account/history scheduler.
        // It remains safe while another operation is in progress.
        switch action {
        case .openBackupsFolder, .openRecoveryFolder:
            guard !stopped, !Task.isCancelled else { return .notPerformed }
            return await execute(action)
        default: break
        }
        await start()
        guard !stopped else { return .notPerformed }
        switch action {
        case .taskGuard(let choice): await taskGuard.choose(choice); publish(); return .unreported
        case .skipCompaction: await compactionWait.skip(); publish(); return .unreported
        case .dismissResult(let id):
            if snapshot.lastResult?.id == id { snapshot.lastResult = nil }; publish(); return .unreported
        case .panelOpened:
            panelIsOpen = true
            await rescan()
            if compactionNotice != nil { compactionNoticeSeen = true }
            if nativeRecoveryNotice?.finished == true { nativeRecoveryNoticeSeen = true }
            await quota.refreshVisible(signedInFolders())
            // The plugin can be installed or removed outside the app; the panel looks again each time it opens.
            snapshot.pluginReady = await plugin.isReady()
            scheduleScan(); publish(); return .unreported
        case .installPlugin:
            guard !Task.isCancelled else { return .notPerformed }
            let receipt: CompanionActionReceipt
            do {
                try await plugin.install()
                receipt = .pluginInstalled
                snapshot.pluginUpdateFailed = false
                log.info(.app, "Installed the Claude Code plugin.")
            } catch {
                let failure = error as? PluginInstallFailure ?? .notFinished
                receipt = .pluginNotInstalled(failure)
                log.warning(.app, "The Claude Code plugin was not installed: \(failure).")
            }
            snapshot.pluginReady = await plugin.isReady()
            publish(); return receipt
        case .refreshQuota(let folder):
            guard !Task.isCancelled else { return .notPerformed }
            let requested = folder.map { [$0] } ?? signedInFolders()
            let refreshed = await quota.refreshWithResult(requested, force: true)
            readings = await quota.currentReadings()
            await receiveReadings(readings)
            return .quotaRefresh(updated: requested.filter { refreshed[$0] == true }.count,
                                 requested: requested.count)
        case .quitApp: await quit(); return .unreported
        default: break
        }
        guard finishing == nil, !snapshot.isPreparingOperation else { publish(); return .notPerformed }
        snapshot.isPreparingOperation = true
        publish()
        guard let token = await gate.acquireForUserAction() else {
            snapshot.isPreparingOperation = false; publish(); return .notPerformed
        }
        guard !stopped, finishing == nil, !Task.isCancelled else {
            snapshot.isPreparingOperation = false; await gate.release(token); publish(); return .notPerformed
        }
        // Sign-in owns the panel until it is completed or explicitly cancelled.
        if snapshot.pendingAdd != nil {
            switch action {
            case .cancelAddAccount, .resolveDuplicateAdd: break
            default: snapshot.isPreparingOperation = false; await gate.release(token); publish(); return .notPerformed
            }
        }
        let receipt = await execute(action)
        snapshot.isPreparingOperation = false
        await gate.release(token)
        if snapshot.pendingAdd == nil { snapshot.operation = nil }
        publish()
        await rescan()
        scheduleSignIn()
        publish()
        await runReadyHistory()
        if case .setAutoSwitch = action { await checkAutomaticSwitch() }
        return receipt
    }

    private func execute(_ action: CompanionAction) async -> CompanionActionReceipt {
        switch action {
        case .switchTo(let folder):
            _ = await switchAccount(folder)
        case .addAccount:
            do {
                let folder = try await accounts.begin(prompt: promptCallback(), progress: progressCallback())
                snapshot.pendingAdd = PendingAddState(folder: folder, phase: .waitingForSignIn)
            } catch { fail(.addAccount, error) }
        case .cancelAddAccount, .resolveDuplicateAdd(.discardNew):
            if let folder = snapshot.pendingAdd?.folder ?? state.pendingSignIns.first?.folder {
                do {
                    try await accounts.cancel(folder: folder, prompt: promptCallback())
                    snapshot.pendingAdd = nil
                    signInMismatch.remove(folder)
                } catch { fail(.addAccount, error) }
            }
        case .resolveDuplicateAdd(.keepBoth):
            if let folder = snapshot.pendingAdd?.folder,
               let pending = state.pendingSignIns.first(where: { $0.folder == folder }) {
                await finishSignIn(pending, keepDuplicate: true)
            }
        case .rename(let folder, let name):
            do { try await accounts.rename(folder: folder, name: name) }
            catch { log.info(.app, "Rejected an invalid account rename.") }
        case .remove(let folder):
            snapshot.operation = .removing(folder: folder); publish()
            do { result(.removed(folder: folder, partialCleanup: try await accounts.remove(folder: folder))) }
            catch { fail(.remove(folder), error) }
        case .addFoundAccount(let folder):
            if let profile = profiles.first(where: { $0.folder == folder }), profile.identity != nil {
                let proposed = AccountManager.emailName(readings[folder]?.snapshot?.email) ??
                    (folder.isDefault ? AccountManager.placeholder(language: state.settings.language, firstRun: true) : folder.name)
                let name = AccountManager.uniqueName(proposed, accounts: state.accounts)
                let account = ManagedAccount(folder: folder, displayName: name, addedAt: clock.now(),
                    nameIsAutomatic: AccountManager.emailName(readings[folder]?.snapshot?.email) == nil)
                do { try await store.update { state in
                    if !state.accounts.contains(where: { $0.folder == folder }) { state.accounts.append(account) }
                    state.knownUnmanagedFolders.removeAll { $0 == folder }
                } } catch { log.warning(.app, "Found account registration could not be saved.") }
            }
        case .dismissFoundAccount(let folder):
            if isOpen(folder) { dismissedWhileOpen.insert(folder) }
            do { try await store.update { if !$0.knownUnmanagedFolders.contains(folder) { $0.knownUnmanagedFolders.append(folder) } } }
            catch { log.warning(.app, "Account dismissal could not be saved.") }
        case .retryHistoryImport(let folder):
            await importHistory(folder, retry: true)
        case .setAutoSync(let enabled): await changeSettings { $0.autoSyncOnSwitch = enabled }
        case .setAutoSwitch(let enabled):
            await changeSettings { $0.autoSwitchOnQuota = enabled }
            nextAutomaticCheck = .distantPast
            automaticHold = nil
            alternativesWait = nil
            limitSwitch = nil
            heldLimit = nil
            if !enabled { await setAutoSwitchPause(nil) }
        case .setConfirmSwitch(let enabled): await changeSettings { $0.confirmSwitch = enabled }
        case .setAutoCompact(let enabled):
            await changeSettings { $0.autoCompactOnLowQuota = enabled }
            writeAutoCompactSettings(enabled: enabled, language: state.settings.language)
        case .setLanguage(let language):
            await changeSettings { $0.language = language }
            writeAutoCompactSettings(enabled: state.settings.autoCompactOnLowQuota, language: language)
        case .setAppearance(let appearance): await changeSettings { $0.appearance = appearance }
        case .setLaunchAtLogin(let enabled):
            do {
                if enabled { try await login.enable(executable: executable) } else { try await login.disable() }
                await changeSettings { $0.launchAtLogin = enabled }
            } catch { log.warning(.app, "Login item setting could not be changed.") }
        case .openBackupsFolder:
            do {
                let directory = paths.companionDataDirectory.appending(path: "Backups")
                try SessionFileIO().makeDirectory(directory)
                try await revealer.reveal(directory)
                return .backupsOpened
            } catch {
                log.warning(.app, "The backups directory could not be revealed.")
                return .failed
            }
        case .openRecoveryFolder:
            do {
                let directory = paths.companionDataDirectory.appending(path: "NativeRecovery")
                try SessionFileIO().makeDirectory(directory)
                try await revealer.reveal(directory)
                return .recoveryFolderOpened
            } catch {
                log.warning(.app, "The recovery records directory could not be revealed.")
                return .failed
            }
        default: break
        }
        return .unreported
    }

    private func changeSettings(_ body: @Sendable (inout Settings) -> Void) async {
        do { try await store.update { body(&$0.settings) } }
        catch { log.warning(.app, "Settings could not be saved.") }
    }

    @discardableResult
    private func switchAccount(_ folder: ProfileFolder, automaticSource: ProfileFolder? = nil) async -> SwitchExecution {
        let needsSignIn = snapshot.accounts.first(where: { $0.folder == folder })?.status == .signedOut
        let expected = profiles.first { $0.folder == folder }?.identity?.accountUUID ?? {
            if case .signedOut(let account) = profiles.first(where: { $0.folder == folder })?.status { return account }; return nil
        }()
        let execution = await switches.run(target: folder, automaticSource: automaticSource,
            progress: progressCallback(), prompt: promptCallback())
        leftWatches = await nativeRecovery.leftWatches()
        switch execution {
        case .noOp:
            if needsSignIn { try? await accounts.recordSignInAgain(folder: folder, expected: expected) }
        case .failed(let reason):
            // An automatic switch that could not prepare the continuation shows as its pause notice
            // instead, and a target that cannot carry the conversation on is simply passed over.
            if automaticSource == nil || ![.cancelled, .couldNotPrepareContinuation, .targetCannotContinue].contains(reason) {
                result(.failed(operation: .switchTo(folder), reason: reason))
            }
        case .completed(let warnings, let confirmation):
            state.activeFolder = folder
            snapshot.currentFolder = folder
            snapshot.operation = nil
            // The conversations Claude just opened report within about half a minute: until then
            // nothing tells whether one runs a command. The last account's pause is over, and so is its wait.
            nextAutomaticCheck = clock.now().addingTimeInterval(NativeRecoverySummary.settlingTime)
            result(.switched(to: folder, warnings: warnings))
            heldLimit = nil
            await setAutoSwitchPause(nil)
            if lastQuotaFolder == folder { await quota.refresh([folder], force: false) }
            try? await accounts.endSignInAgain(except: folder)
            if needsSignIn { try? await accounts.recordSignInAgain(folder: folder, expected: expected) }
            if let confirmation { beginConfirmation(confirmation) }
        }
        return execution
    }

    /// After an app update Claude Code still records the older plugin, or reads it from where the app
    /// was before: Claude Code's own update brings it to this copy. Nothing shows unless that fails.
    private func updatePluginIfNeeded() async {
        guard !stopped, await plugin.needsUpdate() else { return }
        do {
            try await plugin.install()
            snapshot.pluginUpdateFailed = false
            log.info(.app, "Updated the Claude Code plugin.")
        } catch {
            snapshot.pluginUpdateFailed = true
            log.warning(.app, "The Claude Code plugin was not updated: \(error as? PluginInstallFailure ?? .notFinished).")
        }
        snapshot.pluginReady = await plugin.isReady()
        publish()
    }

    private func automaticPollDelay(_ recoveryDelay: Int) -> Int {
        state.settings.autoSwitchOnQuota ? min(5, recoveryDelay) : recoveryDelay
    }

    /// Both quota notifications and the live-runtime timer enter here. All writes still go through
    /// the same operation gate and switch coordinator as a click; this never simulates a click.
    func checkAutomaticSwitch() async {
        guard !stopped, finishing == nil, !checkingAutomaticSwitch, state.settings.autoSwitchOnQuota,
              snapshot.pendingAdd == nil, snapshot.operation == nil, !snapshot.isPreparingOperation,
              clock.now() >= nextAutomaticCheck, !(await gate.isBusy), let active = state.activeFolder else { return }
        checkingAutomaticSwitch = true
        defer { checkingAutomaticSwitch = false }
        // This runs every few seconds. Unless a conversation reports a limit, only a fresh reading that
        // shows the account spent goes further. A fresh reading with quota left ends a pause; an older
        // one decides nothing and is not read again here, except below: the regular refresh brings a
        // new one within minutes, and a conversation that runs into the limit reports it at once.
        if let known = profiles.first(where: { $0.folder == active }), !(await nativeRecovery.anyReportedQuotaBlock()) {
            // The limit is over, or a reply got through: nothing holds the work back any more.
            if [.limitRepeated, .accountRestricted].contains(autoSwitchPause) { await setAutoSwitchPause(nil) }
            var meter = AutomaticSwitchPolicy.reading(readings[active], profile: known, now: clock.now())
            // Once another account may have become usable, this one is read again with them, once:
            // a failed read leaves it to the regular refresh.
            if meter == nil, let wait = alternativesWait, wait.until <= clock.now(),
               wait.basis.first == AutomaticSwitchPolicy.identity(known),
               [.noAvailableAccount, .needsBypassAccount].contains(autoSwitchPause) {
                alternativesWait = nil
                await quota.refresh([active], force: true)
                readings = await quota.currentReadings()
                meter = AutomaticSwitchPolicy.reading(readings[active], profile: known, now: clock.now())
            }
            guard let meter, AutomaticSwitchPolicy.exhausted(meter, now: clock.now()) else {
                if meter != nil { await setAutoSwitchPause(nil) }
                return
            }
        }
        let inventory: [ProfileSnapshot]
        do { inventory = try scanner.scan(managed: state.accounts.map(\.folder)).profiles }
        catch { return }
        guard let source = inventory.first(where: { $0.folder == active }), let sourceLogin = AutomaticSwitchPolicy.identity(source) else { return }
        if let hold = automaticHold {
            // Before any reading: an older or missing one must not end the hold early.
            if hold.login == sourceLogin, hold.until > clock.now() { await setAutoSwitchPause(.lastSwitchFailed); return }
            automaticHold = nil
            if autoSwitchPause == .lastSwitchFailed { await setAutoSwitchPause(nil) }
        }
        // The conversations' own reports: a limit one of them ran into, and a command closing Claude
        // would cut off. Nothing else holds the switch back.
        let readiness = await nativeRecovery.automaticSwitchReadiness(source: source)
        guard !stopped, finishing == nil, state.settings.autoSwitchOnQuota, state.activeFolder == active,
              snapshot.operation == nil, !snapshot.isPreparingOperation else { return }
        // The service itself stopped this account: the work stays, whatever else says it is spent.
        if readiness.pause == .accountRestricted {
            nextAutomaticCheck = clock.now().addingTimeInterval(60)
            await setAutoSwitchPause(.accountRestricted)
            return
        }
        let block = readiness.runtime?.quotaBlock.flatMap { $0.isActive(at: clock.now()) ? $0 : nil }
        let current = AutomaticSwitchPolicy.reading(readings[active], profile: source, now: clock.now())
        guard block != nil || AutomaticSwitchPolicy.exhausted(current, now: clock.now()) else {
            // A report that could not be verified, or a reading that aged meanwhile: look again later.
            nextAutomaticCheck = clock.now().addingTimeInterval(60)
            if current != nil { await setAutoSwitchPause(nil) }
            return
        }
        if let pause = readiness.pause { await setAutoSwitchPause(pause); return }
        guard let running = try? await processes.runningInstances(), !running.isEmpty else { return }
        guard running.allSatisfy({ ProfilePaths.same($0.profileDirectory, source.url) }) else {
            await setAutoSwitchPause(.otherAccountsOpen); return
        }
        // Alternatives normally refresh on demand. An exhausted account is that demand; do not
        // select a target from stale cache, or hammer unavailable accounts on every heartbeat.
        nextAutomaticCheck = clock.now().addingTimeInterval(60)
        // A limit again, right after a limit alone sent the work here: with quota left by this
        // account's own figures, the next account would most likely fare the same and Claude would
        // only close again. Decided here, before anything is prepared. A spent account is left as ever.
        if let block, !AutomaticSwitchPolicy.exhausted(current, now: clock.now()), let sent = limitSwitch,
           sent.login == sourceLogin, AutomaticSwitchPolicy.repeatsLimit(block, after: sent.at) {
            if heldLimit == block.observedAt, autoSwitchPause == .limitRepeated { return }
            await quota.refresh([active], force: true)
            readings = await quota.currentReadings()
            guard !stopped, finishing == nil, state.settings.autoSwitchOnQuota, state.activeFolder == active,
                  snapshot.operation == nil, !snapshot.isPreparingOperation else { return }
            if let left = AutomaticSwitchPolicy.reading(readings[active], profile: source, now: clock.now()),
               !AutomaticSwitchPolicy.exhausted(left, now: clock.now()) {
                heldLimit = block.observedAt
                await setAutoSwitchPause(.limitRepeated)
                return
            }
        }
        let registered = state.accounts.compactMap { account in inventory.first { $0.folder == account.folder } }
        automaticExclusions = automaticExclusions.filter { $0.value > clock.now() }
        automaticBypassMisses.formIntersection(automaticExclusions.keys)
        // While none could take over, they are not read again before one may have become usable,
        // unless a reading that came meanwhile already shows one.
        let basis = [sourceLogin] + registered.map { "\($0.folder.name)=\(AutomaticSwitchPolicy.identity($0) ?? "")" }
        if let wait = alternativesWait, wait.basis == basis, wait.until > clock.now(),
           [.noAvailableAccount, .needsBypassAccount].contains(autoSwitchPause),
           AutomaticSwitchPolicy.target(profiles: registered, source: source, readings: readings,
                                        excluded: Set(automaticExclusions.keys), now: clock.now()) == nil { return }
        alternativesWait = nil
        await quota.replaceProfiles(registered.compactMap(\.quotaProfile))
        // A login claude.ai turned away keeps its own pace: the same cookie is not forced through.
        let others = registered.compactMap { $0.identity == nil ? nil : $0.folder }
        let refused = others.filter { readings[$0]?.lastError == .signedOut }
        await quota.refresh(others.filter { !refused.contains($0) }, force: true)
        if !refused.isEmpty { await quota.refresh(refused, force: false) }
        readings = await quota.currentReadings()
        guard !stopped, finishing == nil, state.settings.autoSwitchOnQuota,
              state.activeFolder == active, snapshot.pendingAdd == nil, snapshot.operation == nil,
              !snapshot.isPreparingOperation else { return }
        let rechecked = await nativeRecovery.automaticSwitchReadiness(source: source, sessionID: readiness.runtime?.sessionID)
        if let pause = rechecked.pause { await setAutoSwitchPause(pause); return }
        let freshBlock = rechecked.runtime?.quotaBlock.flatMap { $0.isActive(at: clock.now()) ? $0 : nil }
        let freshQuota = AutomaticSwitchPolicy.reading(readings[active], profile: source, now: clock.now())
        guard freshBlock != nil || AutomaticSwitchPolicy.exhausted(freshQuota, now: clock.now()) else { await setAutoSwitchPause(nil); return }
        guard let target = AutomaticSwitchPolicy.target(profiles: registered, source: source, readings: readings,
                  excluded: Set(automaticExclusions.keys), now: clock.now()) else {
            // Only the permission mode stands in the way: say which account would do once it allows it.
            let otherwise = Set(automaticExclusions.keys).subtracting(automaticBypassMisses)
            bypassCandidate = AutomaticSwitchPolicy.target(profiles: registered, source: source, readings: readings,
                                                           excluded: otherwise, now: clock.now())?.folder
            let until = AutomaticSwitchPolicy.nextChance(profiles: registered, source: source, readings: readings,
                                                         exclusions: automaticExclusions, now: clock.now())
            alternativesWait = (until, basis)
            log.info(.switch, "No account can take over from \(active.name) yet; the others are read again " +
                     (until == .distantFuture ? "when the accounts change." : "in \(Int(until.timeIntervalSince(clock.now()) / 60)) min."))
            await setAutoSwitchPause(bypassCandidate == nil ? .noAvailableAccount : .needsBypassAccount, retryAt: until); return
        }
        guard let token = await gate.acquire() else { return }
        snapshot.isPreparingOperation = true
        // A continuation that could not be prepared last time stays explained while it is tried again.
        if autoSwitchPause != .continuationNotReady { await setAutoSwitchPause(nil) }
        publish()
        let resets = freshQuota.map { [$0.fiveHour, $0.sevenDay].filter { ($0.usedPercent ?? 0) >= 100 }.compactMap(\.resetsAt) } ?? []
        let limitEnds = freshBlock.map { Date(timeIntervalSince1970: $0.until / 1_000) }
            ?? resets.max() ?? clock.now().addingTimeInterval(600)
        automaticExclusions[sourceLogin] = limitEnds
        log.info(.switch, "Automatic switch \(active.name) -> \(target.folder.name): \(freshBlock?.reason ?? "quota") confirmed.")
        let began = clock.now()
        let execution = await switchAccount(target.folder, automaticSource: active)
        nextAutomaticCheck = clock.now().addingTimeInterval(30)
        if case .failed(let reason) = execution, reason != .cancelled {
            if AutomaticSwitchPolicy.excludesTarget(after: reason) {
                // Only the target is set aside; another one is tried soon. Nothing was closed when it
                // could not carry the conversation on, so that one is tried again at once.
                if let login = AutomaticSwitchPolicy.identity(target) {
                    automaticExclusions[login] = clock.now().addingTimeInterval(600)
                    if reason == .targetCannotContinue { automaticBypassMisses.insert(login) }
                }
                if reason == .targetCannotContinue { nextAutomaticCheck = clock.now() }
                await setAutoSwitchPause(nil)
            } else if AutomaticSwitchPolicy.holdsSource(after: reason) {
                // Claude was closed and the work stayed behind; the cause is most likely still there.
                // Ten minutes at least, so that a limit about to end cannot bring the next close at once.
                automaticHold = (sourceLogin, max(limitEnds, clock.now().addingTimeInterval(600)))
                log.info(.switch, "Automatic switching from \(active.name) waits for its limit to end after a failed switch.")
                await setAutoSwitchPause(.lastSwitchFailed)
            } else {
                // Anything else would fail the same way with every target, so it waits ten minutes.
                nextAutomaticCheck = clock.now().addingTimeInterval(600)
                await setAutoSwitchPause(reason == .couldNotPrepareContinuation ? .continuationNotReady : nil,
                                         retryAt: nextAutomaticCheck)
            }
        } else if case .completed = execution {
            await setAutoSwitchPause(nil)
            let reportAlone = freshBlock?.reason == "rateLimit" && !AutomaticSwitchPolicy.exhausted(freshQuota, now: began)
            limitSwitch = reportAlone ? AutomaticSwitchPolicy.identity(target).map { ($0, began) } : nil
        } else if case .failed(.cancelled) = execution, state.settings.autoSwitchOnQuota, state.activeFolder == active {
            // An unprotected command may have started after the quota refresh. The coordinator refuses
            // the final close too; retain the concrete pause instead of leaving an unexplained cancel.
            let rechecked = await nativeRecovery.automaticSwitchReadiness(source: source)
            if let pause = rechecked.pause { await setAutoSwitchPause(pause) }
        }
        snapshot.isPreparingOperation = false; snapshot.operation = nil
        await gate.release(token)
        await rescan()
        publish()
    }

    /// Shown like the other automatic notices: the snapshot is rebuilt from this, never patched.
    private func setAutoSwitchPause(_ reason: AutoSwitchPauseReason?, retryAt: Date? = nil) async {
        let retryAt = reason == nil ? nil : retryAt
        guard autoSwitchPause != reason || autoSwitchRetry != retryAt else { return }
        if let reason, reason != autoSwitchPause { log.info(.switch, "Automatic switching waits: \(reason.rawValue).") }
        autoSwitchPause = reason
        autoSwitchRetry = retryAt
        await rebuildSnapshot()
    }

    private func rescan() async {
        do {
            state = try await store.load()
            profiles = try scanner.scan(managed: state.accounts.map(\.folder), pending: state.pendingSignIns.map(\.folder)).profiles
            let running = try await processes.runningInstances()
            openInstances = running
            dismissedWhileOpen = dismissedWhileOpen.filter(isOpen)
            refreshAutoCompact()
            snapshot.claudeRunning = !running.isEmpty
            // For each open Claude's conversations to tell the watches kept for their own account
            // from those kept for another.
            await nativeRecovery.recordOpenAccounts(running.compactMap { instance in
                state.accounts.first { ProfilePaths.same(instance.profileDirectory, directory($0.folder)) }
                    .map { NativeOpenAccount(instance, account: $0.folder) }
            }.sorted { $0.pid < $1.pid })
            if state.pendingSignIns.isEmpty, !(await gate.isBusy) {
                await followRunningClaude(running)
                // Open already, an account's kept conversations cannot be started for their watch any
                // more: each picks it up when it is opened. As when the current account follows Claude,
                // a plain launch of the default account is auto-correct's to close and does not count.
                var opened = false
                for account in state.accounts where running.contains(where: {
                    ProfilePaths.same($0.profileDirectory, directory(account.folder)) &&
                        (account.folder == state.activeFolder || $0.hasExplicitProfileFlag || !state.settings.autoCorrectDefaultLaunch)
                }) {
                    if await nativeRecovery.markLeftWatchesOpened(account: account.folder) { opened = true }
                }
                if opened { leftWatches = await nativeRecovery.leftWatches() }
            }
            await rebuildSnapshot()
            let managed = Set(state.accounts.map(\.folder))
            await quota.replaceProfiles(profiles.filter { managed.contains($0.folder) }.compactMap(\.quotaProfile))
            let registered = newlySignedIn.intersection(managed)
            newlySignedIn.subtract(registered)
            // Read at once: the failure that asked for this sign-in is often seconds old, and the
            // throttle or a recent reading would keep "sign in again" on the card meanwhile.
            if !registered.isEmpty { await quota.refresh(registered.sorted { $0.name < $1.name }, force: true) }
            readings = await quota.currentReadings()
            startQuotaObservation()
            if !quotaStarted || lastQuotaFolder != state.activeFolder {
                lastQuotaFolder = state.activeFolder
                quotaStarted = true
                await quota.startPeriodicRefresh(current: state.activeFolder)
            }
            if snapshot.pendingAdd == nil, let pending = state.pendingSignIns.first(where: { pending in !state.accounts.contains { $0.folder == pending.folder } }) {
                snapshot.pendingAdd = PendingAddState(folder: pending.folder, phase: .waitingForSignIn)
            }
            if state.pendingSignIns.isEmpty { snapshot.pendingAdd = nil }
            if snapshot.pendingAdd != nil, !(await gate.isBusy) { snapshot.operation = .addingAccount(phase: .waitingForSignIn) }
            await renameAutomaticAccounts()
        } catch { log.warning(.app, "Profile rescan could not be completed.") }
        await rebuildSnapshot()
    }

    /// The current account follows what Claude has open when it was switched without this app.
    private func followRunningClaude(_ running: [ClaudeInstance]) async {
        guard let folder = AccountFollowing.account(open: running, accounts: state.accounts, active: state.activeFolder,
                                                    flaglessCounts: !state.settings.autoCorrectDefaultLaunch,
                                                    directory: directory) else { return }
        do {
            try await store.update { $0.activeFolder = folder }
            state.activeFolder = folder
            log.info(.app, "The current account follows Claude to \(folder.name).")
        } catch { log.warning(.app, "The account Claude has open could not be saved as current.") }
    }

    private func rebuildSnapshot() async {
        snapshot.currentFolder = state.activeFolder
        snapshot.settings = state.settings
        snapshot.accounts = state.accounts.map { account in
            let profile = profiles.first { $0.folder == account.folder }
            let identity = profile?.identity
            let reading = readings[account.folder]
            let knownDetails = details[account.folder].flatMap { value in
                identity?.matches(account: value.accountUUID, organization: value.organizationUUID) == true ? value : nil
            }
            let readingSnapshot = reading?.snapshot.flatMap { value in
                identity?.matches(account: value.accountUUID, organization: value.organizationUUID) == true ? value : nil
            }
            let status: AccountSummary.Status
            if reading?.lastError?.needsSignIn == true { status = .signedOut }
            else {
                switch profile?.status {
                case .signedIn: status = .signedIn
                case .signedOut: status = .signedOut
                case .awaitingSignIn: status = .awaitingSignIn
                default: status = .unreadable
                }
            }
            return AccountSummary(folder: account.folder, displayName: account.displayName, status: status,
                email: readingSnapshot != nil ? readingSnapshot?.email : knownDetails?.email ?? identity?.email,
                plan: readingSnapshot != nil ? readingSnapshot?.plan : knownDetails?.plan ?? identity?.plan,
                channel: readingSnapshot?.channel ?? .unknown, quota: readingSnapshot,
                quotaFreshness: reading?.freshness ?? .unavailable, quotaFailure: reading?.lastError,
                duplicateOf: profile?.duplicateOf)
        }
        var banners: [Banner] = []
        if !claudeFound { banners.append(.claudeNotFound) }
        // A command that holds the switch ends by itself, and the switch follows: nothing to tell.
        if state.settings.autoSwitchOnQuota, let autoSwitchPause, autoSwitchPause != .commandRunning {
            if autoSwitchPause == .needsBypassAccount, let bypassCandidate {
                banners.append(.autoSwitchNeedsBypass(account: bypassCandidate))
            } else {
                banners.append(.autoSwitchPaused(autoSwitchPause == .needsBypassAccount ? .noAvailableAccount : autoSwitchPause,
                                                 retryAt: autoSwitchRetry))
            }
        }
        let unmanaged = profiles.filter { profile in
            profile.identity != nil && !state.accounts.contains(where: { $0.folder == profile.folder }) &&
                !state.pendingSignIns.contains(where: { $0.folder == profile.folder })
        }
        // A dismissed account Claude has open is offered again.
        for profile in unmanaged where !state.knownUnmanagedFolders.contains(profile.folder) ||
            (isOpen(profile.folder) && !dismissedWhileOpen.contains(profile.folder)) {
            banners.append(.foundAccount(folder: profile.folder))
        }
        snapshot.ignoredFolders = unmanaged.filter { state.knownUnmanagedFolders.contains($0.folder) }.map(\.folder)
        for job in state.historyJobs where job.paused {
            banners.append(.historyImportPaused(folder: job.target, issue: job.issue ?? .interrupted))
        }
        if state.accounts.contains(where: { readings[$0.folder]?.lastError == .keyUnavailable }) { banners.append(.quotaUnavailable) }
        if await corrector.isPaused { banners.append(.autoCorrectPaused) }
        else if let automaticBanner { banners.append(automaticBanner) }
        if let compactionNotice, compactionNotice.outcome != .skipped || compactionNotice.leftTaskPaused {
            banners.append(.autoCompacted(compactionNotice))
        }
        if let nativeRecoveryNotice { banners.append(.nativeRecovery(nativeRecoveryNotice)) }
        for (folder, watches) in leftWatches.sorted(by: { $0.key.name < $1.key.name })
            where folder != state.activeFolder && state.accounts.contains(where: { $0.folder == folder }) {
            banners.append(.watchesStayed(account: folder, titles: watches.map { $0.title ?? "" }))
        }
        snapshot.banners = banners
        publish()
    }

    private func startQuotaObservation() {
        guard quotaTask == nil, !stopped else { return }
        quotaTask = Task { [weak self, quota] in
            for await values in await quota.readings() {
                guard !Task.isCancelled else { return }
                await self?.receiveReadings(values)
            }
        }
    }

    private func receiveReadings(_ incoming: [ProfileFolder: QuotaReading]) async {
        readings = incoming
        await renameAutomaticAccounts()
        await rebuildSnapshot()
        if automaticallyPoll { Task { [weak self] in await self?.checkAutomaticSwitch() } }
    }

    private func renameAutomaticAccounts() async {
        var names: [ProfileFolder: String] = [:]
        for account in state.accounts where account.nameIsAutomatic {
            let folder = account.folder
            guard let reading = readings[folder]?.snapshot,
                  let profile = profiles.first(where: { $0.folder == folder }),
                  profile.identity?.matches(account: reading.accountUUID, organization: reading.organizationUUID) == true,
                  let proposed = AccountManager.emailName(reading.email) else { continue }
            names[folder] = proposed
        }
        guard !names.isEmpty else { return }
        let captured = names
        do {
            try await store.update { state in
                for index in state.accounts.indices where state.accounts[index].nameIsAutomatic {
                    if let name = captured[state.accounts[index].folder] {
                        state.accounts[index].displayName = AccountManager.uniqueName(name, accounts: state.accounts,
                            excluding: state.accounts[index].folder)
                        state.accounts[index].nameIsAutomatic = false
                    }
                }
            }
            state = try await store.load()
        } catch { log.warning(.app, "Automatic account names could not be saved.") }
    }

    private func signedInFolders() -> [ProfileFolder] {
        state.accounts.compactMap { account in profiles.contains { $0.folder == account.folder && $0.identity != nil } ? account.folder : nil }
    }

    public func checkPendingSignIns() async {
        guard !stopped, let token = await gate.acquire() else { return }
        do { state = try await store.load() } catch { await gate.release(token); return }
        for pending in state.pendingSignIns {
            if snapshot.pendingAdd?.duplicateOf != nil { continue }
            await finishSignIn(pending)
        }
        await gate.release(token)
        await rescan()
        if snapshot.pendingAdd == nil { snapshot.operation = nil; publish() }
        await runReadyHistory()
    }

    private func finishSignIn(_ pending: PendingSignIn, keepDuplicate: Bool = false) async {
        // Signing in again to a registered account adds nothing: its card coming back says enough.
        let registered = state.accounts.contains { $0.folder == pending.folder }
        do {
            switch try await accounts.detectSignIn(pending, keepDuplicate: keepDuplicate) {
            case .waiting: break
            case .duplicate(let folder): snapshot.pendingAdd?.duplicateOf = folder
            case .completed(let folder, let fetchedDetails):
                details[folder] = fetchedDetails
                newlySignedIn.insert(folder)
                signInMismatch.remove(folder)
                snapshot.pendingAdd = nil
                snapshot.operation = nil
                if !registered { result(.added(folder: folder, warnings: [])) }
            }
        } catch {
            if case AccountManagementError.refused(.signedInAccountDiffers) = error,
               !signInMismatch.insert(pending.folder).inserted { return }
            fail(.addAccount, error)
        }
    }

    private func runReadyHistory() async {
        guard !stopped, snapshot.pendingAdd == nil,
              let job = state.historyJobs.first(where: { !$0.paused && $0.targetAccountUUID != nil }),
              state.settings.autoSyncOnSwitch, let token = await gate.acquire() else { return }
        await importHistory(job.target, retry: false)
        await gate.release(token)
        snapshot.operation = nil
        await rescan()
    }

    private func importHistory(_ folder: ProfileFolder, retry: Bool) async {
        let outcome = await history.run(folder: folder, retry: retry, prompt: promptCallback(), progress: progressCallback())
        if case .paused(_, let reason) = outcome, let reason { result(.failed(operation: .historyImport(folder), reason: reason)) }
    }

    public func handleLaunch(_ event: LaunchEvent) async {
        guard !stopped else { return }
        // A flagged launch comes from this app or another tool: only the current account may follow it.
        if event.hasExplicitProfileFlag {
            if !(await gate.isBusy) { await rescan() }
            return
        }
        await rescan()
        // A background look at a work handoff is not an operation: correction waits behind it.
        let decision = await corrector.consider(event, active: profiles.first { $0.folder == state.activeFolder },
            enabled: state.settings.autoCorrectDefaultLaunch, busy: await gate.isBusyInForeground || snapshot.pendingAdd != nil,
            defaultDirectory: paths.claudeProfilesRoot.appending(path: "Claude"))
        switch decision {
        case .ignore: return
        case .paused: await rebuildSnapshot(); return
        case .correct: break
        }
        guard let folder = state.activeFolder, let token = await gate.acquireForUserAction() else { return }
        snapshot.operation = .autoCorrecting; publish()
        let started = clock.now()
        var closeFailure: (any Error)?
        do {
            let running = try await processes.runningInstances()
            let defaultDirectory = paths.claudeProfilesRoot.appending(path: "Claude")
            guard let fresh = running.first(where: {
                $0.pid == event.pid && !$0.hasExplicitProfileFlag && ProfilePaths.same($0.profileDirectory, defaultDirectory)
            }) else {
                await gate.release(token)
                snapshot.operation = nil
                await rescan()
                return
            }
            do { try await lifecycle.close(owing: [folder], instance: fresh) }
            catch {
                closeFailure = error
                throw AccountManagementError.refused(.couldNotCloseClaude)
            }
            do { try await lifecycle.relaunchOwed(target: folder) }
            catch { throw AccountManagementError.refused(.couldNotOpenClaude) }
            automaticBanner = .autoCorrected(to: folder)
            log.info(.switch, "Auto-correct Claude -> \(folder.name): switched back in \(SwitchLog.seconds(clock.now().timeIntervalSince(started)))")
            await quota.startPeriodicRefresh(current: folder)
        } catch {
            // Only the closed set of reasons is named, so no error text with a path reaches the log.
            let reason: String
            if case .refused(let refusal)? = error as? AccountManagementError { reason = "\(refusal)" }
            else { reason = String(describing: type(of: error)) }
            log.warning(.switch, "Auto-correct Claude -> \(folder.name): failed after "
                + "\(SwitchLog.seconds(clock.now().timeIntervalSince(started))): \(reason)"
                + (closeFailure.map(SwitchLog.closeDetail) ?? ""))
            fail(.autoCorrect, error)
        }
        await gate.release(token)
        snapshot.operation = nil
        await rescan()
    }

    /// The host calls this from its panel lifecycle; the v1 action enum has no close event.
    public func panelClosed() {
        panelIsOpen = false
        if compactionNoticeSeen {
            compactionNotice = nil
            compactionNoticeSeen = false
        }
        if nativeRecoveryNoticeSeen {
            nativeRecoveryNotice = nil
            nativeRecoveryNoticeSeen = false
            snapshot.banners.removeAll { if case .nativeRecovery = $0 { return true }; return false }
            publish()
        }
        scheduleScan()
    }

    private func scheduleScan() {
        scanTask?.cancel()
        guard automaticallyPoll, !stopped else { return }
        let interval = panelIsOpen ? 30 : 300
        scanTask = Task { [weak self, clock] in
            do {
                while !Task.isCancelled {
                    try await clock.sleep(for: .seconds(interval))
                    guard let self, !Task.isCancelled else { return }
                    await self.rescan()
                    await self.runReadyHistory()
                }
            } catch { }
        }
    }

    private func scheduleSignIn() {
        signInTask?.cancel()
        guard automaticallyPoll, !state.pendingSignIns.isEmpty, !stopped else { return }
        signInTask = Task { [weak self, clock] in
            do {
                while !Task.isCancelled {
                    try await clock.sleep(for: .seconds(2))
                    guard let self, !Task.isCancelled else { return }
                    await self.checkPendingSignIns()
                    if await self.hasPendingSignIns() == false { return }
                }
            } catch { }
        }
    }

    private func hasPendingSignIns() -> Bool { !state.pendingSignIns.isEmpty }

    private func beginConfirmation(_ confirmation: ConversationConfirmation) {
        guard let switched = snapshot.lastResult, case .switched(let folder, _) = switched.outcome else { return }
        let resultID = switched.id
        confirmationTasks[resultID] = Task { [weak self, switches] in
            let confirmed = await switches.confirm(confirmation)
            guard !Task.isCancelled else { return }
            await self?.completeConfirmation(resultID: resultID, folder: folder, confirmed: confirmed)
        }
    }

    /// Looks at the switch's work handoff and answers when to look again. An idle check reads
    /// one small file and takes no gate; only a live operation is polled, briefly holding it.
    @discardableResult func pollNativeRecovery() async -> Int {
        let pace = await nativeRecovery.pace()
        guard pace != .idle else { return 5 }
        guard !stopped, let token = await gate.acquireBackground() else { return 2 }
        let notice = await nativeRecovery.poll()
        await gate.release(token)
        guard !stopped else { return 2 }
        if notice != nativeRecoveryNotice {
            nativeRecoveryNotice = notice
            nativeRecoveryNoticeSeen = notice?.finished == true && panelIsOpen
            snapshot.banners.removeAll { if case .nativeRecovery = $0 { return true }; return false }
            if let notice { snapshot.banners.append(.nativeRecovery(notice)) }
            publish()
        }
        return pace == .fast ? 2 : 30
    }

    private func completeConfirmation(resultID: UUID, folder: ProfileFolder, confirmed: Bool) {
        confirmationTasks[resultID] = nil
        guard !confirmed else { return }
        if snapshot.lastResult?.id == resultID, case .switched(_, var warnings) = snapshot.lastResult?.outcome {
            if !warnings.contains(.conversationNotReopened) { warnings.append(.conversationNotReopened) }
            snapshot.lastResult?.outcome = .switched(to: folder, warnings: warnings)
            publish()
        } else if snapshot.lastResult == nil, latestResultID == resultID, snapshot.operation == nil {
            // The clean success notice closed before the check ended, and nothing happened since:
            // the reminder stands on its own. After a later operation it would only mislead.
            result(.switched(to: folder, warnings: [.conversationNotReopened]))
        }
    }

    private func progressCallback() -> @Sendable (OperationState) async -> Void {
        { [weak self] progress in await self?.setProgress(progress) }
    }

    private func promptCallback() -> @Sendable (TaskGuardPrompt?) async -> Void {
        { [weak self] prompt in await self?.setPrompt(prompt) }
    }

    private func setProgress(_ operation: OperationState) { snapshot.operation = operation; publish() }
    private func setPrompt(_ prompt: TaskGuardPrompt?) {
        snapshot.taskGuardPrompt = prompt
        if let prompt { snapshot.operation = .waitingForTasks(target: prompt.target) }
        publish()
    }
    private func result(_ outcome: OperationResult.Outcome) {
        let made = OperationResult(id: UUID(), finishedAt: clock.now(), outcome: outcome)
        snapshot.lastResult = made
        latestResultID = made.id
        publish()
    }
    private func fail(_ operation: FailedOperation, _ error: any Error) {
        let reason: FailureReason
        if case AccountManagementError.refused(let failure) = error { reason = failure }
        else { reason = .targetUnreadable }
        result(.failed(operation: operation, reason: reason))
    }
    private func publish() { hub.send(snapshot) }
    private func directory(_ folder: ProfileFolder) -> URL { paths.claudeProfilesRoot.appending(path: folder.name) }

    /// The plugin's switch and language follow the app's settings.
    private func writeAutoCompactSettings(enabled: Bool, language: AppLanguage) {
        do { try autoCompact.writeSettings(enabled: enabled, language: language, preferredLanguages: preferredLanguages()) }
        catch { log.warning(.quota, "The compaction plugin's settings could not be written.") }
    }

    /// What the plugin reported since the last scan: its status, and each compaction as one log line.
    private func refreshAutoCompact() {
        snapshot.autoCompact.status = autoCompact.status(now: clock.now())
        for result in autoCompact.takeResults() {
            log.info(.quota, Self.describe(result))
            snapshot.autoCompact.lastResult = result
            // The switch's own result says when the compaction before it did not happen.
            if result.trigger == .beforeSwitch, result.outcome != .compacted { continue }
            compactionNotice = result
            // One made before a switch arrives as Claude comes back to the front and closes the
            // panel, so it waits for the next opening.
            compactionNoticeSeen = panelIsOpen && result.trigger != .beforeSwitch
        }
    }

    static func describe(_ result: AutoCompactResult) -> String {
        let trigger = switch result.trigger {
        case .early: "early line"
        case .hard: "hard line, task paused" + (result.resumed ? " and resumed" : ", not resumed")
        case .beforeSwitch: "before a switch"
        }
        let size = result.tokensAfter.map { "\(result.tokensBefore) -> \($0) tokens" } ?? "\(result.tokensBefore) tokens"
        // The log masks emails and identifiers in every line, the host's reason included.
        let reason = result.error.map { " Reason: \($0)" } ?? ""
        return "Auto-compact (\(trigger)): \(result.outcome.rawValue), \(size).\(reason)"
    }

    private func isOpen(_ folder: ProfileFolder) -> Bool {
        openInstances.contains { ProfilePaths.same($0.profileDirectory, directory(folder)) }
    }

    private func quit() async {
        if let finishing { await finishing.value; return }
        let work = Task { await self.finishQuit() }
        finishing = work
        await work.value
    }

    private func finishQuit() async {
        await gate.cancelPendingUserAction()
        // A switch still at the task check, or waiting for a compaction first, has not closed
        // Claude yet: it is called off rather than waited for.
        await taskGuard.choose(.cancel)
        await compactionWait.cancelAll()
        // An operation still running may be copying sessions into a profile, or about to: opening
        // that profile beside it, or quitting under it, lets Claude and the copy write the same
        // files. So it is waited for to the end; the limit only keeps a hung one from holding the quit.
        let deadline = clock.now().addingTimeInterval(Self.quitWaitLimit)
        while await gate.isBusy, clock.now() < deadline {
            do { try await clock.sleep(for: .milliseconds(200)) } catch { break }
        }
        // One still running past the limit keeps the profile it writes into: that one stays owed,
        // and the next start opens it.
        if await gate.isBusy {
            log.warning(.app, "Quit while an operation was still running; a profile it writes into opens at the next start.")
        }
        try? await lifecycle.relaunchOwed()
        await stop()
        await onQuit()
    }

    /// Long enough for a switch or history import that has to close, sync and launch; only a hung
    /// operation reaches it.
    private static let quitWaitLimit: TimeInterval = 180

    public func stop() async {
        stopped = true
        await gate.cancelPendingUserAction()
        scanTask?.cancel(); signInTask?.cancel(); launchTask?.cancel(); quotaTask?.cancel(); nativeRecoveryTask?.cancel()
        for work in confirmationTasks.values { work.cancel() }
        confirmationTasks.removeAll()
        await taskGuard.choose(.cancel)
        await quota.stopPeriodicRefresh()
    }
}
