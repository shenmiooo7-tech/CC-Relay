import Foundation
import CompanionCore

struct PanelMapInput {
    var snapshot: CompanionSnapshot
    var now: Date
    var timeZone: TimeZone
    var language: L10nLanguage
    var languageChoice: LanguageChoice
    var settings: Settings
    var controlsEnabled: Bool
    var isSettingsOpen: Bool
    var renamingFolder: String?
    var removeConfirmFolder: String?
    var pluginDialog: PluginDialogState?
    var dismissedResultIDs: Set<UUID>
    /// Display names seen on earlier snapshots, so a removed account keeps its name.
    var knownNames: [String: String]
    var quotaRefresh: QuotaRefreshPhase = .idle
    var hud: ShownHUD?
    /// Notices whose dialog was put away; they stay away while the notice lasts.
    var closedNotices: Set<String> = []
    /// A switch asked about after a click, or confirmed and not yet under way.
    var pendingSwitch: PendingSwitch?
    /// The last switch seen under way: where it came from and how far it got.
    var switchTrace: SwitchTrace?
    /// Accounts taken off the list before they are gone from disk: one whose removal can still be undone,
    /// and any whose removal was sent and has not come back yet.
    var hiddenFolders: Set<String> = []
    /// Accounts whose removal the panel already confirmed: the removal's own note does not show again.
    var quietRemovals: Set<String> = []
}

/// A switch the panel holds before Core runs it: asked about, or confirmed and on its way.
struct PendingSwitch: Equatable {
    var folder: String
    var confirmed: Bool
}

/// What the panel saw of the last switch while it ran.
struct SwitchTrace: Equatable {
    var target: String
    /// The account in use when it began.
    var source: String?
    /// Steps done when last seen under way; the step under way has this index. Nil until Core reports
    /// the switch running: a switch refused before its first step has none.
    var stepsDone: Int?
}

/// A confirmation the panel shows for a moment by itself.
enum HUDNotice: Equatable {
    case quotaUpdated
    case quotaPartlyUpdated(updated: Int, requested: Int)
    case quotaFailed
    case quotaNoAccounts
    case versionCopied
    case backupsOpened
    case backupsFailed
    case recoveryOpened
    case recoveryFailed
    /// The account left the list; its removal can still be undone.
    case removed(name: String)
    case restored(name: String)

    func text(_ language: L10nLanguage) -> String {
        switch self {
        case .quotaUpdated: L10nKey.hudQuotaUpdated.string(in: language)
        case .quotaPartlyUpdated(let updated, let requested):
            L10nKey.hudQuotaPartlyUpdated.string(in: language,
                parameters: ["updated": String(updated), "requested": String(requested)])
        case .quotaFailed: L10nKey.hudQuotaFailed.string(in: language)
        case .quotaNoAccounts: L10nKey.hudQuotaNoAccounts.string(in: language)
        case .versionCopied: L10nKey.hudVersionCopied.string(in: language)
        case .backupsOpened: L10nKey.hudBackupsOpened.string(in: language)
        case .backupsFailed: L10nKey.hudBackupsFailed.string(in: language)
        case .recoveryOpened: L10nKey.hudRecoveryOpened.string(in: language)
        case .recoveryFailed: L10nKey.hudRecoveryFailed.string(in: language)
        case .removed(let name): L10nKey.removedAccount.string(in: language, parameters: ["name": name])
        case .restored(let name): L10nKey.restoredAccount.string(in: language, parameters: ["name": name])
        }
    }

    var undoable: Bool {
        if case .removed = self { return true }
        return false
    }
}

struct ShownHUD: Equatable {
    var id: Int
    var notice: HUDNotice
}

enum MappedResult {
    case visible(id: UUID, dismissAfter: TimeInterval?)
    case expired(id: UUID)

    var id: UUID {
        switch self {
        case .visible(let id, _), .expired(let id):
            id
        }
    }
}

struct PanelMapOutput {
    var panel: PanelViewState
    var menuTitle: String
    var menuSwitching: Bool
    var menuQuotaPercent: Int?
    var result: MappedResult?
    /// Every notice that would have a dialog, put away or not.
    var noticeIDs: Set<String> = []
}

enum PanelMapper {
    static func map(_ input: PanelMapInput) -> PanelMapOutput {
        Mapper(input: input).build()
    }
}

/// "HH:mm" in 24-hour time, whatever the system's region prefers.
private func clockTime(_ date: Date, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    formatter.calendar = calendar
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private struct Mapper {
    var input: PanelMapInput

    private var snapshot: CompanionSnapshot { input.snapshot }
    private var language: L10nLanguage { input.language }
    private var accounts: [AccountSummary] { snapshot.accounts }

    func build() -> PanelMapOutput {
        let presented = presentedResult()
        let currentSummary = accounts.first { $0.folder == snapshot.currentFolder }
        let current = currentSummary.map { card(for: $0, result: presented) }
        let otherSummaries = accounts.filter { $0.folder != currentSummary?.folder && !input.hiddenFolders.contains($0.folder.name) }
        let others = otherSummaries.map { card(for: $0, result: presented) }
        let menu = menuContent(current: currentSummary)
        let notices = notices(result: presented)
        let compaction = autoCompactLine
        let panel = PanelViewState(
            language: language,
            header: PanelHeaderState(
                title: text(.productName),
                refresh: input.quotaRefresh,
                canRefresh: snapshot.operation == nil && !snapshot.isPreparingOperation
            ),
            current: current,
            recommendation: recommendation(current: currentSummary, others: otherSummaries),
            others: others,
            banners: notices.dialogs.filter { !input.closedNotices.contains($0.id) },
            addDialog: addDialog(presented),
            switchDialog: switchDialog(presented),
            renameDialog: renameDialog,
            removeDialog: removeDialog,
            pluginDialog: input.pluginDialog,
            isSettingsOpen: input.isSettingsOpen,
            settings: SettingsViewState(
                launchAtLogin: input.settings.launchAtLogin,
                confirmSwitch: input.settings.confirmSwitch,
                autoSyncOnSwitch: input.settings.autoSyncOnSwitch,
                autoSwitchOnQuota: input.settings.autoSwitchOnQuota,
                autoCompactOnLowQuota: input.settings.autoCompactOnLowQuota,
                autoCompactStatus: compaction.text,
                autoCompactTone: compaction.tone,
                appearance: AppearanceMap.choice(input.settings.appearance),
                language: input.languageChoice,
                version: snapshot.appVersion,
                controlsEnabled: input.controlsEnabled,
                pluginUpdateFailed: snapshot.pluginUpdateFailed,
                ignoredAccounts: snapshot.ignoredFolders.map { IgnoredAccountRow(id: $0.name, name: $0.name) }
            ),
            operationBusy: snapshot.operation != nil || snapshot.isPreparingOperation,
            hud: input.hud.map {
                HUDState(id: "local:\($0.id)", text: $0.notice.text(language), actionTitle: $0.notice.undoable ? text(.undo) : nil)
            } ?? notices.passing
        )
        return PanelMapOutput(
            panel: panel,
            menuTitle: menu.title,
            menuSwitching: menu.switching,
            menuQuotaPercent: menu.quotaPercent,
            result: presented?.schedule,
            noticeIDs: Set(notices.dialogs.map(\.id))
        )
    }

    private func card(
        for account: AccountSummary,
        result: ShownResult?
    ) -> AccountCardState {
        let blocks = quotaLines.blocks(for: account)
        let attached: CardResultLine?
        if let progress = progressLine(for: account) {
            attached = progress
        } else if result?.folder == account.folder {
            attached = result?.line
        } else {
            attached = nil
        }
        return AccountCardState(
            id: account.folder.name,
            name: account.displayName,
            buddy: buddy(standing(for: account, blocks: blocks)),
            planLabel: planLabel(account.plan),
            channelText: channelText(account.channel),
            fiveHour: blocks.fiveHour,
            weekly: blocks.weekly,
            status: status(for: account),
            quota: quotaDisplay(for: account),
            note: accountNote(for: account),
            result: attached
        )
    }

    /// Bars when there is a reading or one is expected to stay; grey placeholders while the first one is on
    /// its way; otherwise a line saying why there is none.
    private func quotaDisplay(for account: AccountSummary) -> CardQuotaDisplay {
        switch account.status {
        case .signedOut:
            return .notice(text(.signInAgain), .failure)
        case .awaitingSignIn:
            return .notice(text(.waitingForSignIn), .progress)
        case .unreadable:
            return .notice(text(.quotaUnavailable), .warning)
        case .signedIn:
            if account.quotaFreshness == .unavailable {
                return .notice(account.quotaFailure.map(quotaFailureText) ?? text(.quotaUnavailable), .warning)
            }
            if account.quota == nil, account.quotaFreshness == .refreshing { return .loading }
            return .figures
        }
    }

    private var quotaLines: QuotaLines {
        QuotaLines(timeZone: input.timeZone, language: language, now: input.now)
    }

    private var resetFormatter: ResetTimeFormatter {
        ResetTimeFormatter(timeZone: input.timeZone, language: language, now: input.now)
    }

    /// The figures the card shows, and none for an account whose card shows no quota.
    private func standing(for account: AccountSummary, blocks: (fiveHour: QuotaBlockState, weekly: QuotaBlockState)? = nil) -> QuotaStanding {
        let shown = blocks ?? quotaLines.blocks(for: account)
        guard account.status == .signedIn, account.quotaFreshness != .unavailable, let quota = account.quota else {
            return QuotaStanding(id: account.folder.name)
        }
        // A weekly reset that has passed starts a new week only at the next use.
        let resetsAt = quota.sevenDay.resetsAt.flatMap { $0 > input.now ? $0 : nil }
        return QuotaStanding(
            id: account.folder.name,
            fiveHour: shown.fiveHour.remainingPercent,
            weekly: shown.weekly.remainingPercent,
            weeklyResetsAt: resetsAt
        )
    }

    /// The face from the 5-hour window and the colour from the weekly one, both in the bars' four bands.
    private func buddy(_ standing: QuotaStanding) -> BuddyFace {
        guard let fiveHour = standing.fiveHour, let weekly = standing.weekly else { return .unknown }
        if weekly <= 0 { return BuddyFace(mood: .asleep, color: .empty) }
        let mood: BuddyMood = switch QuotaLevel.fromRemainingPercent(fiveHour) {
        case .ok: .happy
        case .fair: .content
        case .mid: .tired
        case .low: .sleepy
        }
        let color: BuddyColor = switch QuotaLevel.fromRemainingPercent(weekly) {
        case .ok: .ok
        case .fair: .fair
        case .mid: .mid
        case .low: .low
        }
        return BuddyFace(mood: mood, color: color)
    }

    /// The card or line under the current account once that account is out. An account being removed
    /// is not suggested, nor a folder signed in to the current login (account and organization): it
    /// shares the current quota.
    private func recommendation(current: AccountSummary?, others: [AccountSummary]) -> RecommendationSlot? {
        var candidates = others
        if case .removing(let folder) = snapshot.operation {
            candidates.removeAll { $0.folder == folder }
        }
        if let login = current?.quota {
            candidates.removeAll {
                $0.quota?.accountUUID == login.accountUUID && $0.quota?.organizationUUID == login.organizationUUID
            }
        }
        let currentStanding = current.map { standing(for: $0) }
        let standings = candidates.map { standing(for: $0) }
        let formatter = resetFormatter
        guard let decision = Recommender(formatter: formatter).decide(current: currentStanding, others: standings) else {
            return nil
        }
        guard case .switchTo(let target, _) = decision else {
            return .note(RecommendationCopy.reason(for: decision, day: nil, language: language))
        }
        guard let account = candidates.first(where: { $0.folder.name == target }) else { return nil }
        // The same account as its tile, without a result line of its own.
        let card = card(for: account, result: nil)
        let day = standings.first { $0.id == target }?.weeklyResetsAt.map(formatter.weeklyDay(resetAt:))
        let reason = RecommendationCopy.reason(for: decision, day: day, language: language)
        return .card(RecommendedCardState(card: card, reason: reason))
    }

    private func status(for account: AccountSummary) -> AccountCardStatus {
        if case .switching(let target, let step, let completed) = snapshot.operation, target == account.folder {
            return .switching(step: interfaceStep(step), stepsDone: SwitchSteps.done(completed))
        }
        switch account.status {
        case .signedIn:
            return .normal
        case .signedOut:
            return .signedOut
        case .awaitingSignIn:
            return .awaitingSignIn
        case .unreadable:
            return .unavailable
        }
    }

    private func interfaceStep(_ step: CompanionCore.SwitchStep) -> CompanionUI.SwitchStep {
        switch step {
        case .compactingConversation: CompanionUI.SwitchStep.compactingConversation
        case .closingClaude: CompanionUI.SwitchStep.closingClaude
        case .syncingSessions: CompanionUI.SwitchStep.syncingSessions
        case .openingClaude: CompanionUI.SwitchStep.openingClaude
        case .reopeningConversation: CompanionUI.SwitchStep.reopeningConversation
        }
    }

    /// Waiting for Code tasks is said in the switch's dialog, not on the card.
    private func progressLine(for account: AccountSummary) -> CardResultLine? {
        switch snapshot.operation {
        case .removing(let folder) where folder == account.folder:
            return CardResultLine(text: text(.removingAccount), tone: .progress, canDismiss: false)
        case .autoCorrecting where snapshot.currentFolder == account.folder:
            return CardResultLine(text: text(.switchingBack), tone: .progress, canDismiss: false)
        default:
            return nil
        }
    }

    /// The engine reports a task-guard question as waiting too. Until "wait" is chosen nothing is
    /// waiting, so the card and the menu bar stay as they were while the sheet asks.
    private var waitingWasChosen: Bool {
        snapshot.taskGuardPrompt?.isWaiting ?? true
    }

    private func accountNote(for account: AccountSummary) -> String? {
        var notes: [String] = []
        if account.status == .signedIn, account.quota != nil,
           account.quotaFreshness != .fresh, account.quotaFreshness != .unavailable {
            if let failure = account.quotaFailure {
                notes.append(text(.quotaCachedFailure, ["reason": quotaFailureText(failure)]))
            } else if account.quotaFreshness == .stale {
                notes.append(text(.quotaPreviousData))
            }
        }
        if let other = account.duplicateOf {
            notes.append(text(.duplicateNote, ["name": displayName(other)]))
        }
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }

    private func quotaFailureText(_ failure: QuotaFailure) -> String {
        switch failure {
        case .timedOut: text(.quotaTimedOut)
        case .keyUnavailable: text(.quotaKeychain)
        case .signedOut, .cookieMissing: text(.signInAgain)
        case .refused: text(.quotaRefused)
        case .rateLimited(let until): text(.quotaRateLimited, ["time": resetFormatter.minute(until)])
        default: text(.quotaReadFailed)
        }
    }

    private func planLabel(_ plan: String?) -> String? {
        guard let plan else { return nil }
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func channelText(_ channel: SubscriptionChannel) -> String? {
        switch channel {
        case .web: text(.channelWeb)
        case .appStore: text(.channelAppStore)
        case .googlePlay: text(.channelGooglePlay)
        case .unknown: nil
        }
    }

    /// Adding an account: the step under way, the account signed in being one already in the list, or how
    /// it ended (added, shown a moment; or failed, until put away).
    private func addDialog(_ presented: ShownResult?) -> AddDialogState? {
        if let existing = snapshot.pendingAdd?.duplicateOf {
            return .duplicate(name: displayName(existing))
        }
        if case .addingAccount(let phase) = snapshot.operation {
            return addState(phase)
        }
        if let pending = snapshot.pendingAdd {
            return addState(pending.phase)
        }
        if let folder = presented?.addDone {
            let account = accounts.first { $0.folder == folder }
            let detail = [planLabel(account?.plan), account.flatMap { channelText($0.channel) }].compactMap { $0 }
            return .added(name: displayName(folder), detail: detail.isEmpty ? nil : detail.joined(separator: " · "))
        }
        if let reason = presented?.addFailure {
            return .failed(message: text(reasonKey(reason)))
        }
        return nil
    }

    private func addState(_ phase: AddAccountPhase) -> AddDialogState {
        switch phase {
        case .closingClaude: .closingClaude
        case .waitingForSignIn: .waitingForSignIn
        case .importingHistory: .importingHistory
        case .openingClaude: .openingClaude
        }
    }

    /// A switch from the question to its end: asked about after a click, waiting on Code tasks, compacting
    /// first, its steps, done for a moment, or failed until put away.
    private func switchDialog(_ presented: ShownResult?) -> SwitchDialogState? {
        if case .switching(let target, let step, let completed) = snapshot.operation {
            let phase: SwitchDialogState.Phase = step == .compactingConversation
                ? .compacting
                : .running(step: interfaceStep(step), stepsDone: SwitchSteps.done(completed))
            return switchState(target: target, phase: phase)
        }
        if let prompt = snapshot.taskGuardPrompt {
            return switchState(target: prompt.target, phase: .taskGuard(title: taskGuardTitle(prompt), waiting: prompt.isWaiting))
        }
        if let folder = presented?.switchDone {
            return switchState(target: folder, phase: .done)
        }
        if let failure = presented?.switchFailure {
            // A reason that names its step says where it stopped; otherwise the last step seen under way, as
            // a quick switch may finish a step between two snapshots.
            let trace = input.switchTrace?.target == failure.folder.name ? input.switchTrace : nil
            let named: Int? = switch failure.reason {
            case .couldNotCloseClaude: 0
            case .transferFailedReturnedToPreviousAccount, .transferFailedNotReopened: 1
            case .couldNotOpenClaude, .returnedToPreviousAccount: 2
            default: nil
            }
            // A target that cannot carry the conversation on is refused before closing. A trace from
            // an older attempt must not make this refusal look as though the source was already closed.
            let step = failure.reason == .targetCannotContinue ? nil
                : (named ?? trace?.stepsDone).map { min($0, Metrics.switchStepCount - 1) }
            return switchState(target: failure.folder, phase: .failed(failedStep: step, message: failureLine(failure)))
        }
        if let pending = input.pendingSwitch, snapshot.operation == nil,
           let folder = accounts.first(where: { $0.folder.name == pending.folder })?.folder {
            return switchState(target: folder, phase: pending.confirmed ? .running(step: .closingClaude, stepsDone: 0) : .asking,
                               traced: false)
        }
        return nil
    }

    /// `traced`: the account it came from is the one seen when the switch began, not the one in use now.
    private func switchState(target: ProfileFolder, phase: SwitchDialogState.Phase, traced: Bool = true) -> SwitchDialogState {
        let name = displayName(target)
        let traced = traced && input.switchTrace?.target == target.name ? input.switchTrace?.source : nil
        let sourceName = traced ?? snapshot.currentFolder?.name
        let source = sourceName == target.name ? nil : accounts.first { $0.folder.name == sourceName }
        let steps: [CompanionUI.SwitchStep] = [.closingClaude, .syncingSessions, .openingClaude, .reopeningConversation]
        return SwitchDialogState(
            targetID: target.name,
            targetName: name,
            targetBuddy: accounts.first { $0.folder == target }.map { buddy(standing(for: $0)) } ?? .unknown,
            sourceName: source?.displayName,
            sourceBuddy: source.map { buddy(standing(for: $0)) },
            phase: phase,
            steps: steps.map { $0.title(name: name, language: language) }
        )
    }

    /// Why a switch failed. Going back to the account in use says so, naming both.
    private func failureLine(_ failure: (folder: ProfileFolder, reason: FailureReason)) -> String {
        if failure.reason == .returnedToPreviousAccount, let current = snapshot.currentFolder, current != failure.folder {
            return text(.switchFailedBack, ["name": displayName(failure.folder), "previous": displayName(current)])
        }
        return text(reasonKey(failure.reason))
    }

    private var renameDialog: RenameDialogState? {
        guard let id = input.renamingFolder, snapshot.operation == nil,
              let account = accounts.first(where: { $0.folder.name == id }) else { return nil }
        return RenameDialogState(id: id, name: account.displayName)
    }

    private var removeDialog: RemoveDialogState? {
        guard let id = input.removeConfirmFolder, snapshot.operation == nil,
              let account = accounts.first(where: { $0.folder.name == id }) else { return nil }
        return RemoveDialogState(id: id, name: account.displayName)
    }

    /// How many tasks run, or that it could not be told; one sentence, the sheet's title.
    private func taskGuardTitle(_ prompt: TaskGuardPrompt) -> String {
        if prompt.busyCount > 0 {
            return text(.taskGuardCount, ["n": String(prompt.busyCount)])
        }
        return text(prompt.unknown ? .taskGuardUnknown : .taskGuardTitle)
    }

    /// The notices that wait for the person, each in its turn in a dialog, and the one that passes by
    /// itself: a clean result away from the current card, or the switch back under way.
    private func notices(result: ShownResult?) -> (dialogs: [BannerState], passing: HUDState?) {
        var dialogs = snapshot.banners.map(banner(_:))
        if let banner = result?.banner {
            dialogs.append(banner)
        }
        // Nothing else puts these away, so the dialog offers to.
        for index in dialogs.indices where dialogs[index].secondaryActionTitle == nil && !dialogs[index].id.hasPrefix("result:") {
            dialogs[index].closeTitle = text(.dismissNotice)
        }
        if let passing = result?.passing {
            return (dialogs, passing)
        }
        if case .autoCorrecting = snapshot.operation, snapshot.currentFolder == nil {
            return (dialogs, HUDState(id: "switching-back", text: text(.switchingBack), busy: true))
        }
        return (dialogs, nil)
    }

    private func banner(_ banner: Banner) -> BannerState {
        switch banner {
        case .autoSwitchPaused(let reason, let retryAt):
            // A known time is said; `distantFuture` means only another sign-in can let it go on.
            let time = retryAt.flatMap { $0 == .distantFuture ? nil : resetFormatter.moment($0) }
            let key: L10nKey = switch reason {
            // Shown with its account name as `autoSwitchNeedsBypass`; never without one.
            case .noAvailableAccount, .needsBypassAccount:
                retryAt == .distantFuture ? .autoSwitchNoOtherSignIn : time == nil ? .autoSwitchNoAccount : .autoSwitchNoAccountUntil
            case .commandRunning: .autoSwitchCommandRunning
            case .continuationNotReady: time == nil ? .autoSwitchNotReady : .autoSwitchNotReadyUntil
            case .otherAccountsOpen: .autoSwitchOtherAccounts
            case .lastSwitchFailed: .autoSwitchLastFailed
            case .limitRepeated: .autoSwitchLimitRepeated
            case .accountRestricted: .autoSwitchAccountRestricted
            }
            return BannerState(id: "auto-switch:\(reason.rawValue)", kind: .warning,
                               text: text(key, time.map { ["time": $0] } ?? [:]))
        case .autoSwitchNeedsBypass(let account):
            return BannerState(id: "auto-switch:needsBypassAccount", kind: .warning,
                               text: text(.autoSwitchNeedsBypass, ["name": displayName(account)]))
        case .foundAccount(let folder):
            let name = displayName(folder)
            return BannerState(
                id: "found:\(folder.name)",
                kind: .foundAccount,
                text: text(.foundAccount, ["name": name]),
                actionTitle: text(.addFound),
                secondaryActionTitle: text(.dismissFound)
            )
        case .autoCorrected(let folder):
            return BannerState(
                id: "auto:\(folder.name)",
                kind: .autoCorrected,
                text: text(.autoCorrected, ["name": displayName(folder)])
            )
        case .autoCorrectPaused:
            return BannerState(id: "auto-paused", kind: .autoCorrectPaused, text: text(.autoCorrectPaused))
        case .historyImportPaused(let folder, let issue):
            return BannerState(
                id: "history:\(folder.name)",
                kind: .historyImport,
                text: text(historyKey(issue), ["name": displayName(folder)]),
                actionTitle: text(.retry)
            )
        case .quotaUnavailable:
            return BannerState(
                id: "quota",
                kind: .quotaKeychain,
                text: text(.quotaKeychain),
                actionTitle: text(.retry)
            )
        case .claudeNotFound:
            return BannerState(id: "claude-not-found", kind: .warning, text: text(.claudeNotFound))
        case .watchesStayed(let account, let titles):
            // A new conversation left there is news again.
            return BannerState(id: "watches-stayed:\(account.name):\(titles.count)", kind: .neutral,
                text: text(.watchesStayed, ["name": displayName(account), "n": String(titles.count)]),
                details: titles.map { $0.isEmpty ? text(.untitledChat) : $0 })
        case .nativeRecovery(let summary):
            return recoveryBanner(summary)
        case .autoCompacted(let result):
            let id = "compact:\(Int(result.finishedAt.timeIntervalSince1970))"
            let before = contextSize(result.tokensBefore)
            // A paused task that could not go on needs the person, whatever else happened; only a
            // failed compaction is worth trying again by hand first.
            if result.leftTaskPaused {
                let notice = switch result.outcome {
                case .compacted: text(.autoCompactedNotResumed, ["before": before])
                case .skipped: text(.autoCompactNotResumed)
                case .failed: text(.autoCompactFailedNotResumed)
                }
                return BannerState(id: id, kind: .warning, text: notice)
            }
            guard result.outcome != .failed else { return BannerState(id: id, kind: .warning, text: text(.autoCompactFailed)) }
            if result.trigger == .beforeSwitch {
                guard let after = result.tokensAfter else {
                    return BannerState(id: id, kind: .neutral, text: text(.autoCompactedBeforeSwitchSize, ["before": before]))
                }
                return BannerState(id: id, kind: .neutral, text: text(.autoCompactedBeforeSwitch, ["before": before, "after": contextSize(after)]))
            }
            if result.trigger == .hard && result.resumed {
                return BannerState(id: id, kind: .neutral, text: text(.autoCompactedResumed, ["before": before]))
            }
            guard let after = result.tokensAfter else {
                return BannerState(id: id, kind: .neutral, text: text(.autoCompactedSize, ["before": before]))
            }
            return BannerState(id: id, kind: .neutral, text: text(.autoCompacted, ["before": before, "after": contextSize(after)]))
        }
    }

    /// The line under the compaction switch: off, or is the plugin there at all, and watching right now.
    private var autoCompactLine: (text: String, tone: CompactStatusTone) {
        guard input.settings.autoCompactOnLowQuota else { return (text(.autoCompactOff), .off) }
        let status = snapshot.autoCompact.status
        if status.liveConversations > 0 { return (text(.autoCompactPluginLive), .live) }
        guard let last = status.lastReport else { return (text(.autoCompactPluginNone), .quiet) }
        return (text(.autoCompactPluginLastSeen, ["time": clockTime(last, timeZone: input.timeZone)]), .quiet)
    }

    private func historyKey(_ issue: HistoryIssue) -> L10nKey {
        switch issue {
        case .interrupted: .historyImportInterrupted
        case .failed: .historyImportFailed
        case .unavailable: .historyImportUnavailable
        }
    }

    private func menuContent(current: AccountSummary?) -> (title: String, switching: Bool, quotaPercent: Int?) {
        switch snapshot.operation {
        case .switching(let target, _, _):
            return (text(.switchingTo, ["name": displayName(target)]), true, nil)
        case .waitingForTasks(let target) where waitingWasChosen:
            return (text(.switchingTo, ["name": displayName(target)]), true, nil)
        case .autoCorrecting:
            return (text(.switchingBack), true, nil)
        default:
            if let current {
                return (current.displayName, false, menuQuotaPercent(for: current))
            }
            return (text(.productName), false, nil)
        }
    }

    /// The menu shows the 5-hour remaining percent. A window whose reset has passed shows 100 %.
    private func menuQuotaPercent(for account: AccountSummary) -> Int? {
        guard account.quotaFreshness != .unavailable, let quota = account.quota else { return nil }
        let sample = quota.fiveHour
        if let resetAt = sample.resetsAt,
           resetAt.timeIntervalSince(input.now) <= 0,
           account.quotaFreshness != .stale {
            return 100
        }
        guard let used = sample.usedPercent else { return nil }
        let clamped = min(100, max(0, used))
        return Int(floor(100 - clamped))
    }

    private func displayName(_ folder: ProfileFolder) -> String {
        if let current = accounts.first(where: { $0.folder == folder })?.displayName {
            return current
        }
        return input.knownNames[folder.name] ?? folder.name
    }

    private func presentedResult() -> ShownResult? {
        guard snapshot.operation == nil, let result = snapshot.lastResult else { return nil }
        if input.dismissedResultIDs.contains(result.id) { return nil }
        let elapsed = max(0, input.now.timeIntervalSince(result.finishedAt))
        if let ending = dialogEnding(result, elapsed: elapsed) {
            return ending
        }
        let onHero = heroTarget(of: result.outcome)
        let described = describe(result, onHero: onHero)
        if !described.sticky && elapsed >= PanelTiming.cleanResultLifetime {
            return ShownResult(folder: nil, line: nil, schedule: .expired(id: result.id))
        }
        let line = CardResultLine(text: described.text, tone: described.tone, canDismiss: described.sticky)
        let after = described.sticky ? nil : PanelTiming.cleanResultLifetime - elapsed
        let schedule = MappedResult.visible(id: result.id, dismissAfter: after)
        // The hero already shows its name, so that result names no account. Every other result is a banner.
        if onHero, let folder = targetFolder(of: result.outcome) {
            return ShownResult(folder: folder, line: line, schedule: schedule)
        }
        let id = "result:\(result.id.uuidString)"
        guard described.sticky else {
            return ShownResult(folder: nil, line: line, schedule: schedule,
                               passing: HUDState(id: id, text: described.text))
        }
        let banner = BannerState(id: id, kind: .warning, text: described.text, actionTitle: text(.dismissNotice))
        return ShownResult(folder: nil, line: line, schedule: schedule, banner: banner)
    }

    /// A switch or an added account that ends in its dialog: done cleanly, shown a moment; failed, kept
    /// until put away. A removal the panel already confirmed passes without a word.
    private func dialogEnding(_ result: OperationResult, elapsed: TimeInterval) -> ShownResult? {
        func moment(_ lifetime: TimeInterval, _ shown: (inout ShownResult) -> Void) -> ShownResult {
            guard elapsed < lifetime else { return ShownResult(schedule: .expired(id: result.id)) }
            var ending = ShownResult(schedule: .visible(id: result.id, dismissAfter: lifetime - elapsed))
            shown(&ending)
            return ending
        }
        switch result.outcome {
        case .switched(let folder, let warnings) where warnings.isEmpty:
            return moment(PanelTiming.switchDoneLifetime) { $0.switchDone = folder }
        case .added(let folder, let warnings) where warnings.isEmpty:
            return moment(PanelTiming.addDoneLifetime) { $0.addDone = folder }
        case .failed(.switchTo(let folder), let reason) where reason != .cancelled:
            var ending = ShownResult(schedule: .visible(id: result.id, dismissAfter: nil))
            ending.switchFailure = (folder, reason)
            return ending
        case .failed(.addAccount, let reason) where reason != .cancelled:
            var ending = ShownResult(schedule: .visible(id: result.id, dismissAfter: nil))
            ending.addFailure = reason
            return ending
        case .removed(let folder, false) where input.quietRemovals.contains(folder.name):
            return ShownResult(schedule: .expired(id: result.id))
        default:
            return nil
        }
    }

    private func heroTarget(of outcome: OperationResult.Outcome) -> Bool {
        guard let folder = targetFolder(of: outcome),
              folder == snapshot.currentFolder,
              accounts.contains(where: { $0.folder == folder }) else {
            return false
        }
        return true
    }

    private func targetFolder(of outcome: OperationResult.Outcome) -> ProfileFolder? {
        switch outcome {
        case .switched(let folder, _), .added(let folder, _), .removed(let folder, _):
            return folder
        case .failed(let operation, _):
            switch operation {
            case .switchTo(let folder), .remove(let folder), .historyImport(let folder):
                return folder
            case .autoCorrect:
                return snapshot.currentFolder
            case .addAccount:
                return nil
            }
        }
    }

    private func describe(
        _ result: OperationResult,
        onHero: Bool
    ) -> (text: String, tone: CardResultLine.Tone, sticky: Bool) {
        switch result.outcome {
        case .switched(let folder, let warnings):
            let name = displayName(folder)
            if warnings.isEmpty {
                let line = onHero ? text(.switched) : text(.switchedTo, ["name": name])
                return (line, .success, false)
            }
            let lines = warnings.map { switchWarning($0, name: name, onHero: onHero) }
            return (joinParts(lines, onHero: onHero), .warning, true)
        case .added(let folder, let warnings):
            let name = displayName(folder)
            let base = onHero ? text(.added) : text(.addedAccount, ["name": name])
            if warnings.isEmpty {
                return (base, .success, false)
            }
            return (joinParts([base] + warnings.map { clause($0) }, onHero: onHero), .warning, true)
        case .removed(let folder, let partial):
            let name = displayName(folder)
            if partial {
                return (removedPartial(name, onHero: onHero), .warning, true)
            }
            let line = onHero ? text(.removed) : text(.removedAccount, ["name": name])
            return (line, .success, false)
        case .failed(let operation, let reason):
            if reason == .cancelled {
                return (text(.reasonCancelled), .progress, false)
            }
            if reason == .returnedToPreviousAccount {
                return (text(.returnedToPreviousAccount), .failure, true)
            }
            let sentence = text(failureKey(operation), ["reason": text(reasonKey(reason))])
            return (sentence, .failure, true)
        }
    }

    private func switchWarning(_ warning: OperationWarning, name: String, onHero: Bool) -> String {
        switch warning {
        case .sessionsNotSynced(let count):
            unsynced(name: name, count: count, onHero: onHero)
        case .backupFailed:
            text(.warningBackupFailed)
        case .conversationNotReopened:
            text(.switchedConversationNotOpened)
        case .continuityCaptureFailed:
            text(.warningContinuity)
        case .activeOrganizationUnknown:
            text(.warningOrganization)
        case .notCompactedFirst:
            text(.warningNotCompacted)
        case .workContinuationUnavailable:
            text(.warningWorkContinuation)
        }
    }

    private func clause(_ warning: OperationWarning) -> String {
        switch warning {
        case .sessionsNotSynced(let count):
            text(.warningSessions, ["n": String(count)])
        case .backupFailed:
            text(.clauseBackup)
        case .conversationNotReopened:
            text(.clauseConversation)
        case .continuityCaptureFailed:
            text(.clauseContinuity)
        case .activeOrganizationUnknown:
            text(.clauseOrganization)
        case .notCompactedFirst:
            text(.clauseNotCompacted)
        case .workContinuationUnavailable:
            text(.warningWorkContinuation)
        }
    }

    /// The hero already shows the account, so this sentence names nobody.
    private func unsynced(name: String, count: Int, onHero: Bool) -> String {
        let countText = String(count)
        if onHero {
            return text(.switchedUnsynced, ["n": countText])
        }
        let full = text(.switchedWithUnsynced, ["name": name, "n": countText])
        if ResultLayout.fitsBanner(full) {
            return full
        }
        return text(.switchedTo, ["name": name]) + "\n" + text(.warningSessions, ["n": countText])
    }

    private func removedPartial(_ name: String, onHero: Bool) -> String {
        if onHero {
            return text(.removedCleanup)
        }
        let full = text(.removedPartial, ["name": name])
        if ResultLayout.fitsBanner(full) {
            return full
        }
        return text(.removedAccount, ["name": name]) + "\n" + text(.cleanupUnfinished)
    }

    /// Several whole sentences share a line only when that line fits. Otherwise one sentence per line.
    private func joinParts(_ parts: [String], onHero: Bool) -> String {
        let lined = parts.joined(separator: "\n")
        if parts.contains(where: { $0.contains("\n") }) {
            return lined
        }
        let dotted = parts.joined(separator: " · ")
        let fits = onHero ? ResultLayout.fitsHero(dotted) : ResultLayout.fitsBanner(dotted)
        return fits ? dotted : lined
    }

    /// Chinese rounds to 万, English to thousands. 197_065 → 20 / 197.
    private func contextSize(_ tokens: Int) -> String {
        let divisor: Double = language == .zhHans ? 10_000 : 1_000
        return String(Int((Double(tokens) / divisor).rounded()))
    }

    private func failureKey(_ operation: FailedOperation) -> L10nKey {
        switch operation {
        case .switchTo: .switchFailed
        case .addAccount: .failedAdd
        case .remove: .failedRemove
        case .autoCorrect: .failedAutoCorrect
        case .historyImport: .failedHistoryImport
        }
    }

    private func reasonKey(_ reason: FailureReason) -> L10nKey {
        switch reason {
        case .couldNotCloseClaude: .failedToCloseClaude
        case .couldNotOpenClaude: .failedToOpenClaude
        case .couldNotReadProcesses: .reasonCouldNotReadProcesses
        case .targetMissing: .reasonTargetMissing
        case .targetUnreadable: .reasonTargetUnreadable
        case .couldNotPrepareContinuation: .reasonContinuationUnavailable
        case .targetCannotContinue: .reasonTargetCannotContinue
        case .operationInFlight: .reasonOperationInFlight
        case .refusedActiveAccount: .reasonRefusedActive
        case .refusedLastAccount: .reasonRefusedLast
        case .refusedWhileRunning: .reasonRefusedRunning
        case .runningStateUnknown: .reasonRunningUnknown
        case .signedInAccountDiffers: .reasonSignedInDiffers
        case .cancelled: .reasonCancelled
        case .returnedToPreviousAccount: .returnedToPreviousAccount
        case .transferFailedReturnedToPreviousAccount: .transferFailedReturnedToPreviousAccount
        case .transferFailedNotReopened: .transferFailedNotReopened
        }
    }

    /// The work a switch carried over, in one of three states. Until the conversations it opened had
    /// time to report, a problem still reads as continuing; one that remains is named in one line.
    private func recoveryBanner(_ summary: NativeRecoverySummary) -> BannerState {
        let issues = summary.issues ?? []
        let blocked = summary.attention > 0 && !summary.settling
        let continuing = summary.waiting + summary.submitted + summary.executing + summary.attention > 0
        let state: L10nKey? = blocked ? .nativeRecoveryStateBlocked
            : continuing ? .nativeRecoveryStateContinuing
            : summary.ended + summary.inspected > 0 ? .nativeRecoveryStateContinued : nil
        // Commands of a reply the person stopped before the switch: news, alone or under the state.
        let ended = summary.endedWithSwitch > 0
            ? text(.nativeRecoveryEndedWithSwitch, ["n": String(summary.endedWithSwitch)]) : nil
        var lines: [String] = []
        if let state {
            lines.append(text(state))
            let reasons = Set(issues.map(\.reason))
            if blocked, reasons.count == 1, let reason = reasons.first {
                lines.append(text(recoveryIssueKey(reason)))
            } else if blocked {
                lines.append(text(.nativeRecoveryReasonsVary, ["n": String(summary.attention)]))
            } else if let route = recoveryRoute(summary) {
                lines.append(route)
            }
        } else if let ended {
            lines.append(ended)
        }
        // A new state is a new notice: closing one does not hide the next.
        let issueStatus = blocked ? issues.map { "\($0.sessionID):\($0.reason.rawValue)" }.joined(separator: "|") : ""
        let feedback: String? = switch input.hud?.notice {
        case .recoveryOpened?, .recoveryFailed?: input.hud?.notice.text(language)
        default: nil
        }
        return BannerState(
            id: "native-recovery:\(summary.operationID):\(state?.rawValue ?? "ended"):\(summary.endedWithSwitch):\(issueStatus)",
            kind: blocked ? .warning : state == .nativeRecoveryStateContinuing ? .inProgress : .neutral,
            text: lines.joined(separator: "\n"),
            details: state == nil ? [] : [ended].compactMap { $0 },
            actionFeedback: feedback,
            actionTitle: blocked ? text(.openRecoveryRecords) : nil)
    }

    /// "From A to B", or only the account it moved to when both names do not fit one line.
    private func recoveryRoute(_ summary: NativeRecoverySummary) -> String? {
        guard let from = summary.from, let to = summary.to else { return nil }
        let full = text(.nativeRecoveryRoute, ["from": displayName(from), "to": displayName(to)])
        return ResultLayout.fitsBanner(full) ? full : text(.switchedTo, ["name": displayName(to)])
    }

    private func recoveryIssueKey(_ reason: NativeRecoveryIssue.Reason) -> L10nKey {
        switch reason {
        case .missingRecord: .nativeRecoveryMissingRecord
        case .incompatibleRuntime: .nativeRecoveryIncompatibleRuntime
        case .blocked: .nativeRecoveryBlocked
        case .runtimeUnavailable: .nativeRecoveryRuntimeUnavailable
        case .expired: .nativeRecoveryExpired
        case .conversationUnavailable: .nativeRecoveryConversationUnavailable
        case .executionFailed: .nativeRecoveryExecutionFailed
        case .recoveryIncomplete: .nativeRecoveryIncomplete
        }
    }

    private func text(_ key: L10nKey, _ parameters: [String: String] = [:]) -> String {
        key.string(in: language, parameters: parameters)
    }
}

private struct ShownResult {
    var folder: ProfileFolder?
    var line: CardResultLine?
    var schedule: MappedResult
    /// A result that needs reading waits in a dialog; a clean one passes in the middle of the panel.
    var banner: BannerState?
    var passing: HUDState?
    /// Endings shown in the switch's or the add dialog instead.
    var switchDone: ProfileFolder?
    var switchFailure: (folder: ProfileFolder, reason: FailureReason)?
    var addDone: ProfileFolder?
    var addFailure: FailureReason?

    init(folder: ProfileFolder? = nil, line: CardResultLine? = nil, schedule: MappedResult,
         banner: BannerState? = nil, passing: HUDState? = nil) {
        self.folder = folder
        self.line = line
        self.schedule = schedule
        self.banner = banner
        self.passing = passing
    }
}

/// Quota bars the panel can draw without waiting for another snapshot.
private struct QuotaLines {
    var timeZone: TimeZone
    var language: L10nLanguage
    var now: Date

    func blocks(for account: AccountSummary) -> (fiveHour: QuotaBlockState, weekly: QuotaBlockState) {
        let fiveTitle = text(.fiveHour)
        let weekTitle = text(.weekly)
        if account.quotaFreshness == .unavailable {
            return (empty(fiveTitle), empty(weekTitle))
        }
        return (
            window(
                title: fiveTitle,
                sample: account.quota?.fiveHour,
                freshness: account.quotaFreshness,
                fetchedAt: account.quota?.fetchedAt,
                weekly: false,
                hasQuota: account.quota != nil
            ),
            window(
                title: weekTitle,
                sample: account.quota?.sevenDay,
                freshness: account.quotaFreshness,
                fetchedAt: account.quota?.fetchedAt,
                weekly: true,
                hasQuota: account.quota != nil
            )
        )
    }

    private func window(
        title: String,
        sample: QuotaWindow?,
        freshness: QuotaFreshness,
        fetchedAt: Date?,
        weekly: Bool,
        hasQuota: Bool
    ) -> QuotaBlockState {
        if !hasQuota {
            if freshness == .refreshing {
                let line = text(.quotaRefreshing)
                return make(title, percent: nil, line: line, tip: line)
            }
            return empty(title)
        }
        let resetAt = sample?.resetsAt
        let used = sample?.usedPercent
        if let resetAt, resetAt.timeIntervalSince(now) <= 0 {
            if freshness == .stale {
                return make(
                    title,
                    percent: used.map(remaining(fromUsed:)),
                    line: updatedLine(fetchedAt),
                    tip: updatedTip(fetchedAt)
                )
            }
            // This window's reset has passed. The sibling window is decided on its own.
            let line = text(.resetRefreshing)
            return make(title, percent: 100, line: line, tip: tip(freshness, fetchedAt: fetchedAt, fallback: line))
        }
        if resetAt == nil {
            if let used, used != 0 {
                return make(
                    title,
                    percent: remaining(fromUsed: used),
                    line: updatedLine(fetchedAt),
                    tip: updatedTip(fetchedAt)
                )
            }
            let line = text(.notStarted)
            return make(title, percent: 100, line: line, tip: tip(freshness, fetchedAt: fetchedAt, fallback: line))
        }
        let formatter = ResetTimeFormatter(timeZone: timeZone, language: language, now: now)
        let line = weekly ? formatter.weeklyLine(resetAt: resetAt) : formatter.fiveHourLine(resetAt: resetAt)
        let fallback = formatter.tooltip(resetAt: resetAt)
        return make(
            title,
            percent: used.map(remaining(fromUsed:)),
            line: line,
            tip: tip(freshness, fetchedAt: fetchedAt, fallback: fallback)
        )
    }

    private func tip(_ freshness: QuotaFreshness, fetchedAt: Date?, fallback: String) -> String {
        switch freshness {
        case .stale:
            return updatedTip(fetchedAt)
        case .refreshing:
            return text(.quotaRefreshing)
        case .fresh, .resetPassed, .unavailable:
            return fallback
        }
    }

    private func updatedLine(_ fetchedAt: Date?) -> String {
        guard let fetchedAt else { return QuotaMark.unavailable }
        return text(.quotaUpdatedShort, ["time": updatedTime(fetchedAt)])
    }

    private func updatedTip(_ fetchedAt: Date?) -> String {
        guard let fetchedAt else { return QuotaMark.unavailable }
        return text(.quotaUpdatedAt, ["time": updatedTime(fetchedAt)])
    }

    private func updatedTime(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) { return hourMinute(date) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? "MM-dd HH:mm" : "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func empty(_ title: String) -> QuotaBlockState {
        make(title, percent: nil, line: QuotaMark.unavailable, tip: QuotaMark.unavailable)
    }

    private func make(_ title: String, percent: Int?, line: String, tip: String) -> QuotaBlockState {
        QuotaBlockState(
            title: title,
            remainingPercent: percent,
            level: percent.map(QuotaLevel.fromRemainingPercent) ?? .low,
            resetLine: line,
            tooltip: tip
        )
    }

    private func remaining(fromUsed used: Double) -> Int {
        let clamped = min(100, max(0, used))
        return Int(floor(100 - clamped))
    }

    private func hourMinute(_ date: Date) -> String { clockTime(date, timeZone: timeZone) }

    private func text(_ key: L10nKey, _ parameters: [String: String] = [:]) -> String {
        key.string(in: language, parameters: parameters)
    }
}

/// How many of the four steps a switch's dialog lists are done: compacting first is not one of them.
enum SwitchSteps {
    static func done(_ completed: [CompanionCore.SwitchStep]) -> Int {
        min(completed.filter { $0 != .compactingConversation }.count, Metrics.switchStepCount)
    }
}

enum QuotaMark {
    static let unavailable = "\u{2014}"
}

enum PanelTiming {
    static let cleanResultLifetime: TimeInterval = 2
    static let countdownTick = Duration.seconds(60)
    /// The least the header's arrow turns for a quota read, and how long the new figures pop after it.
    static let refreshTurn: TimeInterval = 0.7
    static let refreshSettle = Duration.milliseconds(600)
    /// How long a confirmation in the middle of the panel stays before it fades, and one that can be undone.
    static let hudLifetime = Duration.milliseconds(1_900)
    static let undoLifetime = Duration.seconds(4)
    /// How long a switch's and an added account's dialog say so before they go.
    static let switchDoneLifetime: TimeInterval = 1.2
    static let addDoneLifetime: TimeInterval = 1.4
}
