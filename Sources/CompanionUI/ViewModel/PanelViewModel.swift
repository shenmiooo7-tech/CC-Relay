import Foundation
import Observation
import CompanionCore

enum AppearanceMap {
    static func choice(_ appearance: AppAppearance) -> AppearanceChoice {
        switch appearance {
        case .system: .system
        case .light: .light
        case .dark: .dark
        }
    }

    static func appAppearance(_ choice: AppearanceChoice) -> AppAppearance {
        switch choice {
        case .system: .system
        case .light: .light
        case .dark: .dark
        }
    }
}

enum LanguageMap {
    static func choice(_ language: AppLanguage) -> LanguageChoice {
        switch language {
        case .system: .system
        case .zhHans: .zhHans
        case .en: .en
        }
    }

    static func appLanguage(_ choice: LanguageChoice) -> AppLanguage {
        switch choice {
        case .system: .system
        case .zhHans: .zhHans
        case .en: .en
        }
    }

    static func resolve(_ choice: LanguageChoice, preferred: [String]) -> L10nLanguage {
        switch choice {
        case .system:
            L10nLanguage.resolve(preferredLanguages: preferred)
        case .zhHans:
            .zhHans
        case .en:
            .en
        }
    }
}

@MainActor
@Observable
public final class MenuBarLabelModel {
    public private(set) var title: String
    /// 5-hour remaining percent. Absent while switching, and when that window has no reading.
    public private(set) var quotaPercent: Int?
    public private(set) var isSwitching: Bool
    public private(set) var language: L10nLanguage

    init(title: String, quotaPercent: Int?, isSwitching: Bool, language: L10nLanguage) {
        self.title = title
        self.quotaPercent = quotaPercent
        self.isSwitching = isSwitching
        self.language = language
    }

    func update(title: String, quotaPercent: Int?, isSwitching: Bool, language: L10nLanguage) {
        self.title = title
        self.quotaPercent = quotaPercent
        self.isSwitching = isSwitching
        self.language = language
    }
}

@MainActor
@Observable
public final class SettingsViewModel {
    public private(set) var settings = SettingsViewState()
    public private(set) var language: L10nLanguage
    public private(set) var controlsEnabled = true

    weak var panel: PanelViewModel?

    init(language: L10nLanguage) {
        self.language = language
    }

    func update(settings: SettingsViewState, language: L10nLanguage) {
        self.settings = settings
        self.language = language
        self.controlsEnabled = settings.controlsEnabled
    }

    public func setLaunchAtLogin(_ isOn: Bool) async { await panel?.setLaunchAtLogin(isOn) }
    public func setConfirmSwitch(_ isOn: Bool) async { await panel?.setConfirmSwitch(isOn) }
    public func setAutoSync(_ isOn: Bool) async { await panel?.setAutoSync(isOn) }
    public func setAutoSwitch(_ isOn: Bool) async { await panel?.setAutoSwitch(isOn) }
    public func setAutoCompact(_ isOn: Bool) async { await panel?.setAutoCompact(isOn) }
    public func setLanguage(_ choice: LanguageChoice) async { await panel?.setLanguage(choice) }
    public func openBackups() async { await panel?.openBackups() }
    public func quit() async { await panel?.quit() }
}

@MainActor
@Observable
public final class PanelViewModel {
    public private(set) var state: PanelViewState
    /// How tall the screen lets the panel be, from the window that shows it; the page scrolls past it.
    public var heightLimit: CGFloat?
    /// Whether the panel is on screen, from the window that shows it. While it is not, nothing on it moves.
    public private(set) var panelOpen = false
    public let menuBarModel: MenuBarLabelModel
    public let settingsModel: SettingsViewModel

    private let facade: any CompanionFacade
    private let clock: any Clock
    private let timeZone: TimeZone
    private let preferredLanguages: [String]
    /// Puts text on the pasteboard. The app passes the real one; tests and previews leave it alone.
    private let copyText: @MainActor (String) -> Void

    private var settings = Settings()
    private var languageChoice: LanguageChoice = .system
    private var interfaceLanguage: L10nLanguage
    private var lastSnapshot: CompanionSnapshot?
    private var isSettingsOpen = false
    private var renamingFolder: String?
    private var removeConfirmFolder: String?
    private var pluginDialog: PluginDialogState?
    private var dismissedResultIDs: Set<UUID> = []
    private var knownNames: [String: String] = [:]
    private var activeResultID: UUID?
    private var scheduledDismissID: UUID?
    private var quotaRefresh: QuotaRefreshPhase = .idle
    private var hud: ShownHUD?
    private var hudCount = 0
    private var closedNotices: Set<String> = []
    private var pendingSwitch: PendingSwitch?
    private var switchTrace: SwitchTrace?
    /// The account taken off the list whose removal waits while it can be undone.
    private var pendingRemoval: ProfileFolder?
    /// Off the list from the confirmation until Core has removed it, or failed to.
    private var hiddenFolders: Set<String> = []
    private var quietRemovals: Set<String> = []
    /// Held outside observation so `deinit` can cancel the tasks. The loops
    /// retain this model only while applying a snapshot or a tick, so dropping
    /// the last external reference runs `deinit` and stops both tasks.
    @ObservationIgnored
    private let tasks = TaskLifetime()

    private(set) var hasApplied = false
    private(set) var revision = 0

    /// `timeZone` defaults to the system's, followed as it changes (a trip abroad) without a restart.
    public init(
        facade: any CompanionFacade,
        clock: any Clock = SystemClock(),
        timeZone: TimeZone = .autoupdatingCurrent,
        preferredLanguages: [String] = Locale.preferredLanguages,
        copyText: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        let language = LanguageMap.resolve(.system, preferred: preferredLanguages)
        self.facade = facade
        self.clock = clock
        self.timeZone = timeZone
        self.preferredLanguages = preferredLanguages
        self.copyText = copyText
        self.interfaceLanguage = language
        self.state = .placeholder(language: language)
        self.menuBarModel = MenuBarLabelModel(
            title: L10nKey.productName.string(in: language),
            quotaPercent: nil,
            isSwitching: false,
            language: language
        )
        self.settingsModel = SettingsViewModel(language: language)
        self.settingsModel.panel = self
        tasks.subscription = Task { [weak self] in
            guard let facade = self?.facade else { return }
            let stream = facade.snapshots()
            for await snapshot in stream {
                guard let model = self else { return }
                model.apply(snapshot)
            }
        }
        tasks.ticker = Task { [weak self] in
            guard let clock = self?.clock else { return }
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: PanelTiming.countdownTick)
                } catch {
                    return
                }
                guard let model = self, !Task.isCancelled else { return }
                model.render()
            }
        }
    }

    deinit {
        tasks.cancelAll()
    }

    public func makeActions() -> PanelActions {
        PanelActions(
            selectAccount: { [weak self] id in Task { await self?.select(id) } },
            beginRename: { [weak self] id in self?.beginRename(id) },
            rename: { [weak self] id, name in Task { await self?.rename(id: id, to: name) } },
            cancelRename: { [weak self] id in self?.cancelRename(id) },
            remove: { [weak self] id in self?.beginRemove(id) },
            confirmRemove: { [weak self] in Task { await self?.confirmRemove() } },
            addAccount: { [weak self] in Task { await self?.addAccount() } },
            cancelAdd: { [weak self] in Task { await self?.cancelAdd() } },
            keepBothAccounts: { [weak self] in Task { await self?.keepBoth() } },
            discardNewAccount: { [weak self] in Task { await self?.discardNew() } },
            waitForTasks: { [weak self] in Task { await self?.waitForTasks() } },
            switchNow: { [weak self] in Task { await self?.switchNow() } },
            cancelTaskGuard: { [weak self] in Task { await self?.cancelTaskGuard() } },
            bannerAction: { [weak self] id in Task { await self?.activateBanner(id) } },
            bannerSecondaryAction: { [weak self] id in Task { await self?.activateBannerSecondary(id) } },
            openSettings: { [weak self] in self?.openSettings() },
            closeSettings: { [weak self] in self?.closeSettings() },
            setLaunchAtLogin: { [weak self] value in Task { await self?.setLaunchAtLogin(value) } },
            setAutoSync: { [weak self] value in Task { await self?.setAutoSync(value) } },
            setAutoCompact: { [weak self] value in Task { await self?.setAutoCompact(value) } },
            setLanguage: { [weak self] choice in Task { await self?.setLanguage(choice) } },
            openBackups: { [weak self] in Task { await self?.openBackups() } },
            dismissSheet: { [weak self] in self?.dismissSheet() },
            quit: { [weak self] in Task { await self?.quit() } },
            refreshQuota: { [weak self] id in Task { await self?.refreshQuota(id) } },
            dismissResult: { [weak self] in Task { await self?.dismissDisplayedResult() } },
            addIgnoredAccount: { [weak self] id in Task { await self?.addIgnoredAccount(id) } },
            skipCompaction: { [weak self] in Task { await self?.skipCompaction() } },
            refreshAllQuotas: { [weak self] in Task { await self?.refreshAllQuotas() } },
            closeNotice: { [weak self] id in self?.closeNotice(id) },
            setAppearance: { [weak self] choice in Task { await self?.setAppearance(choice) } },
            copyVersion: { [weak self] in self?.copyVersion() },
            confirmSwitch: { [weak self] stopAsking in Task { await self?.confirmSwitch(stopAsking: stopAsking) } },
            cancelSwitchQuestion: { [weak self] in self?.cancelSwitchQuestion() },
            retrySwitch: { [weak self] in Task { await self?.retrySwitch() } },
            closeSwitchResult: { [weak self] in Task { await self?.dismissDisplayedResult() } },
            retryAdd: { [weak self] in Task { await self?.retryAdd() } },
            closeAddResult: { [weak self] in Task { await self?.dismissDisplayedResult() } },
            setConfirmSwitch: { [weak self] value in Task { await self?.setConfirmSwitch(value) } },
            hudAction: { [weak self] in self?.undoRemoval() },
            setAutoSwitch: { [weak self] isOn in Task { await self?.setAutoSwitch(isOn) } },
            installPlugin: { [weak self] in Task { await self?.installPlugin() } },
            closePluginDialog: { [weak self] in self?.closePluginDialog() },
            retryPluginUpdate: { [weak self] in Task { await self?.retryPluginUpdate() } }
        )
    }

    public func panelAppeared() {
        panelOpen = true
        Task { await self.facade.perform(.panelOpened) }
    }

    public func panelClosed() {
        panelOpen = false
    }

    /// A click on an account switches to it, asking first while "切换确认" is on. Signing the account in use
    /// in again does not ask.
    public func select(_ id: String) async {
        // An account whose name is being edited is not switched to, from its tile or the suggested
        // card: the click would drop the new name.
        guard canEditAccounts, renamingFolder != id, pendingSwitch == nil else { return }
        let isCurrent = lastSnapshot?.currentFolder?.name == id
        if isCurrent, lastSnapshot?.accounts.first(where: { $0.folder.name == id })?.status != .signedOut { return }
        guard let folder = knownFolder(id) else { return }
        if settings.confirmSwitch, !isCurrent {
            pendingSwitch = PendingSwitch(folder: id, confirmed: false)
            render()
            return
        }
        await startSwitch(folder)
    }

    /// The question's "switch": the dialog turns into the steps at once. Ticking "don't ask again" turns
    /// "切换确认" off.
    public func confirmSwitch(stopAsking: Bool) async {
        guard let pending = pendingSwitch, !pending.confirmed, let folder = knownFolder(pending.folder) else { return }
        if stopAsking {
            settings.confirmSwitch = false
            await facade.perform(.setConfirmSwitch(false))
        }
        await startSwitch(folder)
    }

    public func cancelSwitchQuestion() {
        guard pendingSwitch?.confirmed == false else { return }
        pendingSwitch = nil
        render()
    }

    /// After a failed switch: the same switch again, without asking.
    public func retrySwitch() async {
        guard let result = lastSnapshot?.lastResult, case .failed(.switchTo(let folder), _) = result.outcome,
              knownFolder(folder.name) != nil else { return }
        await dismiss(id: result.id)
        await startSwitch(folder)
    }

    /// After an account that could not be added: add one again.
    public func retryAdd() async {
        guard let result = lastSnapshot?.lastResult, case .failed(.addAccount, _) = result.outcome else { return }
        await dismiss(id: result.id)
        await addAccount()
    }

    /// The dialog shows the first step until Core reports the switch under way.
    private func startSwitch(_ folder: ProfileFolder) async {
        guard canEditAccounts else { return }
        pendingSwitch = PendingSwitch(folder: folder.name, confirmed: true)
        switchTrace = SwitchTrace(target: folder.name, source: lastSnapshot?.currentFolder?.name)
        render()
        await facade.perform(.switchTo(folder: folder))
        if pendingSwitch?.folder == folder.name, pendingSwitch?.confirmed == true {
            pendingSwitch = nil
            render()
        }
    }

    public func beginRename(_ id: String) {
        guard canEditAccounts, knownFolder(id) != nil else { return }
        renamingFolder = id
        render()
    }

    public func rename(id: String, to name: String) async {
        guard canEditAccounts else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...Metrics.maxNameCharacters).contains(trimmed.count) else { return }
        guard let folder = knownFolder(id) else { return }
        renamingFolder = nil
        render()
        await facade.perform(.rename(folder: folder, name: trimmed))
    }

    public func cancelRename(_ id: String) {
        guard renamingFolder == id else { return }
        renamingFolder = nil
        render()
    }

    public func beginRemove(_ id: String) {
        guard canEditAccounts, knownFolder(id) != nil else { return }
        removeConfirmFolder = id
        render()
    }

    /// The account leaves the list at once and a note says so with an undo button; the folder is archived
    /// only once the note has gone, after any operation under way has finished.
    public func confirmRemove() async {
        guard canEditAccounts, let id = removeConfirmFolder, let folder = knownFolder(id) else { return }
        removeConfirmFolder = nil
        // An earlier removal still waiting goes through now; its timer must not take this one early.
        tasks.removal?.cancel()
        await commitRemoval()
        pendingRemoval = folder
        hiddenFolders.insert(folder.name)
        showHUD(.removed(name: knownNames[id] ?? id), lifetime: PanelTiming.undoLifetime)
        tasks.removal = Task { [weak self] in
            guard let clock = self?.clock else { return }
            do {
                try await clock.sleep(for: PanelTiming.undoLifetime)
            } catch {
                return
            }
            guard let model = self, !Task.isCancelled else { return }
            await model.commitRemoval()
        }
    }

    /// The note's undo: the account comes back as it was; nothing was removed.
    public func undoRemoval() {
        guard let folder = pendingRemoval else { return }
        pendingRemoval = nil
        hiddenFolders.remove(folder.name)
        tasks.removal?.cancel()
        showHUD(.restored(name: knownNames[folder.name] ?? folder.name))
    }

    private func commitRemoval() async {
        guard let folder = pendingRemoval else { return }
        pendingRemoval = nil
        quietRemovals.insert(folder.name)
        // Core refuses a removal while another operation runs, so wait for it.
        for _ in 0..<1_200 where !controlsEnabled {
            do {
                try await clock.sleep(for: .milliseconds(500))
            } catch {
                break
            }
        }
        await facade.perform(.remove(folder: folder))
    }

    public func addAccount() async {
        guard canEditAccounts else { return }
        await facade.perform(.addAccount)
    }

    public func cancelAdd() async {
        await facade.perform(.cancelAddAccount)
    }

    public func keepBoth() async {
        await facade.perform(.resolveDuplicateAdd(.keepBoth))
    }

    public func discardNew() async {
        await facade.perform(.resolveDuplicateAdd(.discardNew))
    }

    public func waitForTasks() async {
        await facade.perform(.taskGuard(.waitThenSwitch))
    }

    public func switchNow() async {
        await facade.perform(.taskGuard(.switchNow))
    }

    public func cancelTaskGuard() async {
        await facade.perform(.taskGuard(.cancel))
    }

    public func skipCompaction() async {
        await facade.perform(.skipCompaction)
    }

    public func activateBanner(_ id: String) async {
        if id.hasPrefix("native-recovery:"), state.banners.contains(where: { $0.id == id && $0.actionTitle != nil }) {
            let receipt = await facade.performWithReceipt(.openRecoveryFolder)
            showHUD(receipt == .recoveryFolderOpened ? .recoveryOpened : .recoveryFailed)
            return
        }
        if id == "quota" {
            await facade.perform(.refreshQuota(folder: nil))
            return
        }
        if let folder = folder(id: id, prefix: "found:") {
            guard canEditAccounts else { return }
            await facade.perform(.addFoundAccount(folder: folder))
            return
        }
        if let folder = folder(id: id, prefix: "history:") {
            guard canEditAccounts else { return }
            await facade.perform(.retryHistoryImport(folder: folder))
            return
        }
        if id.hasPrefix("result:"), let uuid = UUID(uuidString: String(id.dropFirst("result:".count))) {
            await dismiss(id: uuid)
        }
    }

    /// Puts a notice's dialog away until the notice goes and comes again.
    public func closeNotice(_ id: String) {
        guard closedNotices.insert(id).inserted else { return }
        render()
    }

    /// Settings lists dismissed accounts; adding one back registers it like the found-account banner.
    public func addIgnoredAccount(_ id: String) async {
        guard canEditAccounts, let folder = lastSnapshot?.ignoredFolders.first(where: { $0.name == id }) else { return }
        await facade.perform(.addFoundAccount(folder: folder))
    }

    public func activateBannerSecondary(_ id: String) async {
        guard let folder = folder(id: id, prefix: "found:") else { return }
        guard canEditAccounts else { return }
        await facade.perform(.dismissFoundAccount(folder: folder))
    }

    public func openSettings() {
        isSettingsOpen = true
        render()
    }

    public func closeSettings() {
        isSettingsOpen = false
        render()
    }

    public func setLaunchAtLogin(_ isOn: Bool) async {
        guard controlsEnabled else { return }
        settings.launchAtLogin = isOn
        render()
        await facade.perform(.setLaunchAtLogin(isOn))
    }

    public func setAutoSync(_ isOn: Bool) async {
        guard controlsEnabled else { return }
        settings.autoSyncOnSwitch = isOn
        render()
        await facade.perform(.setAutoSync(isOn))
    }

    public func setAutoSwitch(_ isOn: Bool) async {
        guard controlsEnabled else { return }
        if isOn, needsPlugin { return askForPlugin(.autoSwitch) }
        settings.autoSwitchOnQuota = isOn
        render()
        await facade.perform(.setAutoSwitch(isOn))
    }

    public func setConfirmSwitch(_ isOn: Bool) async {
        guard controlsEnabled else { return }
        settings.confirmSwitch = isOn
        render()
        await facade.perform(.setConfirmSwitch(isOn))
    }


    public func setAutoCompact(_ isOn: Bool) async {
        guard controlsEnabled else { return }
        if isOn, needsPlugin { return askForPlugin(.autoCompact) }
        settings.autoCompactOnLowQuota = isOn
        render()
        await facade.perform(.setAutoCompact(isOn))
    }

    /// Both features work through the plugin: while it is missing, turning one on asks to install it first.
    private var needsPlugin: Bool { lastSnapshot?.pluginReady == false }

    private func askForPlugin(_ feature: PluginDialogState.Feature) {
        pluginDialog = PluginDialogState(feature: feature)
        render()
    }

    /// Installs the plugin, then turns on the feature that asked for it. A failure leaves it off, and
    /// so does an operation that refuses the feature meanwhile, which the dialog then says.
    public func installPlugin() async {
        guard let dialog = pluginDialog, dialog.phase != .installing, dialog.phase != .done,
              dialog.phase != .installedButOff else { return }
        pluginDialog?.phase = .installing
        render()
        switch await facade.performWithReceipt(.installPlugin) {
        case .pluginInstalled:
            let refused: Bool
            switch dialog.feature {
            case .autoSwitch:
                settings.autoSwitchOnQuota = true
                render()
                refused = await facade.performWithReceipt(.setAutoSwitch(true)) == .notPerformed
                if refused { settings.autoSwitchOnQuota = false }
            case .autoCompact:
                settings.autoCompactOnLowQuota = true
                render()
                refused = await facade.performWithReceipt(.setAutoCompact(true)) == .notPerformed
                if refused { settings.autoCompactOnLowQuota = false }
            }
            pluginDialog?.phase = refused ? .installedButOff : .done
        case .pluginNotInstalled(let failure):
            pluginDialog?.phase = .failed(failure)
        default:
            pluginDialog?.phase = .failed(.notFinished)
        }
        render()
    }

    /// Runs the plugin's install again after its own update failed; the row goes once one succeeds.
    public func retryPluginUpdate() async {
        guard controlsEnabled else { return }
        _ = await facade.performWithReceipt(.installPlugin)
    }

    /// Closes the plugin's dialog, except while the install runs.
    public func closePluginDialog() {
        guard pluginDialog?.phase != .installing else { return }
        pluginDialog = nil
        render()
    }

    public func setLanguage(_ choice: LanguageChoice) async {
        guard controlsEnabled else { return }
        languageChoice = choice
        interfaceLanguage = LanguageMap.resolve(choice, preferred: preferredLanguages)
        render()
        await facade.perform(.setLanguage(LanguageMap.appLanguage(choice)))
    }

    /// Light, dark, or the system's look. Not held back while something runs: it changes nothing else.
    public func setAppearance(_ choice: AppearanceChoice) async {
        settings.appearance = AppearanceMap.appAppearance(choice)
        render()
        await facade.perform(.setAppearance(settings.appearance))
    }

    public func openBackups() async {
        let receipt = await facade.performWithReceipt(.openBackupsFolder)
        showHUD(receipt == .backupsOpened ? .backupsOpened : .backupsFailed)
    }

    public func copyVersion() {
        guard let version = lastSnapshot?.appVersion, !version.isEmpty else { return }
        copyText(version)
        showHUD(.versionCopied)
    }

    public func dismissSheet() {
        guard removeConfirmFolder != nil else { return }
        removeConfirmFolder = nil
        render()
    }

    public func quit() async {
        await facade.perform(.quitApp)
    }

    public func refreshQuota(_ id: String) async {
        guard canEditAccounts else { return }
        guard let summary = lastSnapshot?.accounts.first(where: { $0.folder.name == id }) else { return }
        switch summary.status {
        case .signedOut, .awaitingSignIn:
            return
        case .signedIn, .unreadable:
            break
        }
        await facade.perform(.refreshQuota(folder: summary.folder))
    }

    /// Reads every signed-in account's quota. The arrow turns for at least `PanelTiming.refreshTurn`,
    /// so a read that comes back at once is still seen; then the figures pop and a confirmation shows.
    public func refreshAllQuotas() async {
        guard controlsEnabled, quotaRefresh == .idle else { return }
        quotaRefresh = .refreshing
        render()
        let started = clock.now()
        let receipt = await facade.performWithReceipt(.refreshQuota(folder: nil))
        let left = PanelTiming.refreshTurn - clock.now().timeIntervalSince(started)
        if left > 0 {
            try? await clock.sleep(for: .milliseconds(Int((left * 1_000).rounded())))
        }
        let updated: Bool
        let notice: HUDNotice
        switch receipt {
        case .quotaRefresh(let count, let requested) where requested > 0 && count == requested:
            updated = true
            notice = .quotaUpdated
        case .quotaRefresh(let count, let requested) where count > 0 && count < requested:
            updated = true
            notice = .quotaPartlyUpdated(updated: count, requested: requested)
        case .quotaRefresh(updated: 0, requested: 0):
            updated = false
            notice = .quotaNoAccounts
        default:
            updated = false
            notice = .quotaFailed
        }
        quotaRefresh = updated ? .updated : .idle
        showHUD(notice)
        if updated {
            try? await clock.sleep(for: PanelTiming.refreshSettle)
            quotaRefresh = .idle
            render()
        }
    }

    /// Shows `notice` in the middle of the panel; it fades by itself after `lifetime`.
    func showHUD(_ notice: HUDNotice, lifetime: Duration = PanelTiming.hudLifetime) {
        hudCount += 1
        let shown = ShownHUD(id: hudCount, notice: notice)
        hud = shown
        render()
        tasks.hud?.cancel()
        tasks.hud = Task { [weak self] in
            guard let clock = self?.clock else { return }
            do {
                try await clock.sleep(for: lifetime)
            } catch {
                return
            }
            guard let model = self, !Task.isCancelled, model.hud == shown else { return }
            model.hud = nil
            model.render()
        }
    }

    public func dismissDisplayedResult() async {
        guard let id = activeResultID else { return }
        await dismiss(id: id)
    }

    func waitUntilApplied() async -> Bool {
        if hasApplied { return true }
        for _ in 0..<500 {
            await Task.yield()
            if hasApplied { return true }
        }
        return false
    }

    private func apply(_ snapshot: CompanionSnapshot) {
        let previous = lastSnapshot
        lastSnapshot = snapshot
        for account in snapshot.accounts {
            knownNames[account.folder.name] = account.displayName
        }
        settings = snapshot.settings
        languageChoice = LanguageMap.choice(snapshot.settings.language)
        interfaceLanguage = LanguageMap.resolve(languageChoice, preferred: preferredLanguages)
        if snapshot.operation != nil {
            renamingFolder = nil
        }
        if snapshot.taskGuardPrompt != nil || snapshot.pendingAdd?.duplicateOf != nil {
            removeConfirmFolder = nil
        }
        follow(switchOf: snapshot, previous: previous)
        // A removal that went through, or failed, no longer hides its account; one that can still be
        // undone does.
        let failedRemoval = if case .failed(.remove(let folder), _)? = snapshot.lastResult?.outcome { folder.name } else { String?.none }
        hiddenFolders = hiddenFolders.filter { hidden in
            hidden == pendingRemoval?.name
                || (hidden != failedRemoval && snapshot.accounts.contains { $0.folder.name == hidden })
        }
        hasApplied = true
        render()
    }

    /// Notes where a switch came from and how far it got, for its dialog; and lets go of a question or a
    /// confirmed switch once Core has taken it up, or another operation started.
    private func follow(switchOf snapshot: CompanionSnapshot, previous: CompanionSnapshot?) {
        switch snapshot.operation {
        case .switching(let target, _, let completed):
            if switchTrace?.target != target.name {
                let source = [snapshot.currentFolder, previous?.currentFolder].compactMap { $0 }.first { $0 != target }
                switchTrace = SwitchTrace(target: target.name, source: source?.name)
            }
            switchTrace?.stepsDone = SwitchSteps.done(completed)
        case .waitingForTasks(let target):
            if switchTrace?.target != target.name {
                switchTrace = SwitchTrace(target: target.name, source: snapshot.currentFolder?.name)
            }
        default:
            break
        }
        guard let pending = pendingSwitch else { return }
        let takenUp = snapshot.operation != nil || snapshot.taskGuardPrompt != nil
            || (snapshot.lastResult != nil && snapshot.lastResult?.id != previous?.lastResult?.id)
        if takenUp, pending.confirmed || snapshot.operation != nil {
            pendingSwitch = nil
        }
    }

    private func render() {
        guard let snapshot = lastSnapshot else { return }
        let output = PanelMapper.map(
            PanelMapInput(
                snapshot: snapshot,
                now: clock.now(),
                timeZone: timeZone,
                language: interfaceLanguage,
                languageChoice: languageChoice,
                settings: settings,
                controlsEnabled: controlsEnabled,
                isSettingsOpen: isSettingsOpen,
                renamingFolder: renamingFolder,
                removeConfirmFolder: removeConfirmFolder,
                pluginDialog: pluginDialog,
                dismissedResultIDs: dismissedResultIDs,
                knownNames: knownNames,
                quotaRefresh: quotaRefresh,
                hud: hud,
                closedNotices: closedNotices,
                pendingSwitch: pendingSwitch,
                switchTrace: switchTrace,
                hiddenFolders: hiddenFolders,
                quietRemovals: quietRemovals
            )
        )
        // A notice that went is forgotten, so it shows again if it comes back.
        closedNotices.formIntersection(output.noticeIDs)
        state = output.panel
        menuBarModel.update(
            title: output.menuTitle,
            quotaPercent: output.menuQuotaPercent,
            isSwitching: output.menuSwitching,
            language: interfaceLanguage
        )
        settingsModel.update(settings: output.panel.settings, language: interfaceLanguage)
        revision += 1
        syncResult(output.result)
    }

    private func syncResult(_ result: MappedResult?) {
        activeResultID = result?.id
        switch result {
        case .visible(let id, let after?):
            armDismiss(id: id, after: after)
        case .visible:
            disarmDismiss()
        case .expired(let id):
            disarmDismiss()
            Task { await self.dismiss(id: id) }
        case nil:
            disarmDismiss()
        }
    }

    private func armDismiss(id: UUID, after: TimeInterval) {
        if scheduledDismissID == id { return }
        tasks.dismiss?.cancel()
        scheduledDismissID = id
        tasks.dismiss = Task { [weak self] in
            let milliseconds = max(0, Int((after * 1_000).rounded()))
            guard let clock = self?.clock else { return }
            do {
                try await clock.sleep(for: .milliseconds(milliseconds))
            } catch {
                return
            }
            guard let model = self, !Task.isCancelled else { return }
            await model.dismiss(id: id)
        }
    }

    private func disarmDismiss() {
        scheduledDismissID = nil
        tasks.dismiss?.cancel()
        tasks.dismiss = nil
    }

    private func dismiss(id: UUID) async {
        guard dismissedResultIDs.insert(id).inserted else { return }
        // Record the dismissal before re-rendering. Rendering clears the timer,
        // and that timer is the task currently inside this method.
        await facade.perform(.dismissResult(id: id))
        if scheduledDismissID == id {
            scheduledDismissID = nil
        }
        render()
    }

    private var controlsEnabled: Bool {
        guard let snapshot = lastSnapshot else { return true }
        return snapshot.operation == nil && !snapshot.isPreparingOperation
    }

    private var canEditAccounts: Bool {
        controlsEnabled
    }

    /// Cards only act on accounts the snapshot actually lists.
    private func knownFolder(_ name: String) -> ProfileFolder? {
        lastSnapshot?.accounts.first { $0.folder.name == name }?.folder
    }

    /// Banner ids can name a folder that is not registered yet.
    private func folder(id: String, prefix: String) -> ProfileFolder? {
        guard id.hasPrefix(prefix) else { return nil }
        let name = String(id.dropFirst(prefix.count))
        if let known = knownFolder(name) { return known }
        return try? ProfileFolder(name)
    }
}

/// Task storage that `deinit` can reach. `@Observable` otherwise isolates
/// stored properties to the main actor, and `deinit` is not on that actor.
private final class TaskLifetime: @unchecked Sendable {
    var subscription: Task<Void, Never>?
    var ticker: Task<Void, Never>?
    var dismiss: Task<Void, Never>?
    var hud: Task<Void, Never>?
    var removal: Task<Void, Never>?

    func cancelAll() {
        subscription?.cancel()
        ticker?.cancel()
        dismiss?.cancel()
        hud?.cancel()
        removal?.cancel()
    }
}

/// Clock whose `now` stays put. Sleep uses the real scheduler so a fixture
/// model can be released without spinning, and cancellation stops the wait.
struct FrozenClock: Clock, Sendable {
    var instant: Date

    func now() -> Date { instant }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
