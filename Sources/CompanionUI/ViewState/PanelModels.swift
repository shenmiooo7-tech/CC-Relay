import CompanionCore
import Foundation

public enum LanguageChoice: String, CaseIterable, Sendable, Equatable {
    case system
    case zhHans
    case en
}

/// The panel's light or dark look, or the system's.
public enum AppearanceChoice: String, CaseIterable, Sendable, Equatable {
    case system
    case light
    case dark
}

/// How the compaction line under its switch reads: the plugin is connected, it has not been heard
/// from lately, or compaction is off.
public enum CompactStatusTone: Sendable, Equatable {
    case live
    case quiet
    case off
}

public enum SwitchStep: CaseIterable, Sendable, Equatable {
    case compactingConversation
    case closingClaude
    case syncingSessions
    case openingClaude
    case reopeningConversation

    func title(name: String, language: L10nLanguage) -> String {
        switch self {
        case .compactingConversation:
            L10nKey.stepCompactConversation.string(in: language)
        case .closingClaude:
            L10nKey.stepCloseClaude.string(in: language)
        case .syncingSessions:
            L10nKey.stepSyncSessions.string(in: language)
        case .openingClaude:
            L10nKey.stepOpenClaude.string(in: language, parameters: ["name": name])
        case .reopeningConversation:
            L10nKey.stepReopenConversation.string(in: language)
        }
    }
}

public enum AccountCardStatus: Sendable, Equatable {
    case normal
    case switching(step: SwitchStep, stepsDone: Int)
    case signedOut
    case awaitingSignIn
    case unavailable

    public var isSwitching: Bool {
        if case .switching = self { return true }
        return false
    }
}

/// What a card shows where its quota bars go: the bars, grey placeholders while the first reading is
/// on its way, or a short line in a tinted box saying why there are none.
public enum CardQuotaDisplay: Sendable, Equatable {
    case figures
    case loading
    case notice(String, CardNoticeTone)
}

public enum CardNoticeTone: Sendable, Equatable {
    /// Yellow: it can't be read just now.
    case warning
    /// Red: it needs the person, such as a new sign-in.
    case failure
    /// Clay: something is under way.
    case progress
}

public struct CardResultLine: Sendable, Equatable {
    public enum Tone: Sendable, Equatable {
        case success
        case warning
        case failure
        case progress
    }

    public var text: String
    public var tone: Tone
    /// Sticky warnings and failures can be dismissed. Progress and clean results cannot.
    public var canDismiss: Bool

    public init(text: String, tone: Tone, canDismiss: Bool) {
        self.text = text
        self.tone = tone
        self.canDismiss = canDismiss
    }
}

public struct QuotaBlockState: Sendable, Equatable {
    public var title: String
    public var remainingPercent: Int?
    public var level: QuotaLevel
    public var resetLine: String
    public var tooltip: String

    public init(
        title: String,
        remainingPercent: Int?,
        level: QuotaLevel,
        resetLine: String,
        tooltip: String
    ) {
        self.title = title
        self.remainingPercent = remainingPercent
        self.level = level
        self.resetLine = resetLine
        self.tooltip = tooltip
    }

    public var fillFraction: Double {
        guard let remainingPercent else { return 0 }
        let clamped = min(100, max(0, remainingPercent))
        if clamped == 0 { return 0 }
        return max(Double(Metrics.minimumBarFraction), Double(clamped) / 100)
    }

    public var percentText: String? {
        remainingPercent.map { "\($0)%" }
    }
}

/// The buddy's face follows the 5-hour window in the quota bars' four bands: the less is left, the
/// sleepier it is. A used-up week puts it to sleep whatever the window says.
public enum BuddyMood: Sendable, Equatable, CaseIterable {
    case happy
    case content
    case tired
    case sleepy
    case asleep
    case unknown

    /// How awake it is, from 0 asleep to 4 wide awake; calm while its quota is not known.
    public var energy: Int {
        switch self {
        case .asleep: 0
        case .sleepy: 1
        case .tired: 2
        case .content, .unknown: 3
        case .happy: 4
        }
    }
}

/// The buddy's colour follows the weekly window in the quota bars' four bands, as a soft version of
/// the bar's colour; grey when the week is spent or nothing is known.
public enum BuddyColor: Sendable, Equatable, CaseIterable {
    case ok
    case fair
    case mid
    case low
    case empty
}

public struct BuddyFace: Sendable, Hashable {
    public var mood: BuddyMood
    public var color: BuddyColor

    public init(mood: BuddyMood, color: BuddyColor) {
        self.mood = mood
        self.color = color
    }

    /// No quota to show: signed out, waiting for sign-in, unreadable, or nothing read yet.
    public static let unknown = BuddyFace(mood: .unknown, color: .empty)
}

/// The plan label's look. Any plan the panel does not name shares one look.
public enum PlanTier: Sendable, Equatable {
    case pro
    /// 5× and a Max plan whose size is not known.
    case max
    case max20
    case other

    public init?(label: String?) {
        switch label {
        case nil: return nil
        case "Pro": self = .pro
        case "Max", "Max 5×": self = .max
        case "Max 20×": self = .max20
        default: self = .other
        }
    }
}

public struct AccountCardState: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var buddy: BuddyFace
    public var planLabel: String?
    /// How the plan is paid for, under the name. No address is shown on a card.
    public var channelText: String?
    public var fiveHour: QuotaBlockState
    public var weekly: QuotaBlockState
    public var status: AccountCardStatus
    public var quota: CardQuotaDisplay
    public var note: String?
    public var result: CardResultLine?

    public init(
        id: String,
        name: String,
        buddy: BuddyFace = .unknown,
        planLabel: String?,
        channelText: String? = nil,
        fiveHour: QuotaBlockState,
        weekly: QuotaBlockState,
        status: AccountCardStatus = .normal,
        quota: CardQuotaDisplay = .figures,
        note: String? = nil,
        result: CardResultLine? = nil
    ) {
        self.id = id
        self.name = name
        self.buddy = buddy
        self.planLabel = planLabel
        self.channelText = channelText
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.status = status
        self.quota = quota
        self.note = note
        self.result = result
    }

    public var planTier: PlanTier? { PlanTier(label: planLabel) }
}

/// The card under the current account once that account is out: the account to use instead.
public struct RecommendedCardState: Sendable, Equatable {
    public var card: AccountCardState
    public var reason: String

    public init(card: AccountCardState, reason: String) {
        self.card = card
        self.reason = reason
    }
}

public enum RecommendationSlot: Sendable, Equatable {
    case card(RecommendedCardState)
    /// No other account can be used now.
    case note(String)
}

/// Adding an account, in a dialog in the middle of the panel: Claude closes, the person signs in with the
/// new account, its history comes in, and then how it ended.
public enum AddDialogState: Sendable, Equatable {
    case closingClaude
    case waitingForSignIn
    case importingHistory
    case openingClaude
    /// Shown a moment, then the dialog goes and the new card joins the list. `detail` is its plan and
    /// how it is paid for.
    case added(name: String, detail: String?)
    /// The account signed in was already in the list: keep both, or drop the new one.
    case duplicate(name: String)
    case failed(message: String)
}

/// A switch, in one dialog in the middle of the panel from the question to the end: the account in use
/// and the one switched to side by side over the steps.
public struct SwitchDialogState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Asked before a switch that a click started, while that is set.
        case asking
        /// Code tasks run: wait for them, switch now, or cancel. `title` says how many.
        case taskGuard(title: String, waiting: Bool)
        /// The long conversation it is leaving is compacted first.
        case compacting
        case running(step: SwitchStep, stepsDone: Int)
        /// Shown a moment before the dialog goes.
        case done
        /// `failedStep` is the step that was under way, when known.
        case failed(failedStep: Int?, message: String)
    }

    public var targetID: String
    public var targetName: String
    public var targetBuddy: BuddyFace
    /// The account in use when the switch began, when there was one.
    public var sourceName: String?
    public var sourceBuddy: BuddyFace?
    public var phase: Phase
    /// The four steps, in order.
    public var steps: [String]

    public init(
        targetID: String,
        targetName: String,
        targetBuddy: BuddyFace,
        sourceName: String?,
        sourceBuddy: BuddyFace?,
        phase: Phase,
        steps: [String]
    ) {
        self.targetID = targetID
        self.targetName = targetName
        self.targetBuddy = targetBuddy
        self.sourceName = sourceName
        self.sourceBuddy = sourceBuddy
        self.phase = phase
        self.steps = steps
    }
}

/// A new name for an account, asked in a dialog in the middle of the panel.
public struct RenameDialogState: Sendable, Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Removing an account asks first, in a dialog in the middle of the panel.
/// Turning on a feature that needs the plugin while it is missing: the question, the install under way,
/// and how it went.
public struct PluginDialogState: Sendable, Equatable {
    public enum Feature: Sendable, Equatable {
        case autoSwitch
        case autoCompact
    }

    public enum Phase: Sendable, Equatable {
        case asking
        case installing
        case done
        /// The plugin went in, but the feature was refused while another operation ran.
        case installedButOff
        case failed(PluginInstallFailure)
    }

    public var feature: Feature
    public var phase: Phase

    public init(feature: Feature, phase: Phase = .asking) {
        self.feature = feature
        self.phase = phase
    }
}

public struct RemoveDialogState: Sendable, Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum BannerKind: Sendable, Equatable {
    case autoCorrected
    case autoCorrectPaused
    case warning
    case inProgress
    case neutral
    case foundAccount
    case historyImport
    case quotaKeychain
}

/// A notice that waits for the person: shown one at a time in a dialog in the middle of the panel.
public struct BannerState: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: BannerKind
    public var text: String
    public var details: [String]
    public var actionFeedback: String?
    public var actionTitle: String?
    public var secondaryActionTitle: String?
    /// False while the action is already running.
    public var actionEnabled: Bool
    /// Puts the dialog away for now when nothing else does; it comes back if the notice does.
    public var closeTitle: String?

    public init(
        id: String,
        kind: BannerKind,
        text: String,
        details: [String] = [],
        actionFeedback: String? = nil,
        actionTitle: String? = nil,
        secondaryActionTitle: String? = nil,
        actionEnabled: Bool = true,
        closeTitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.details = details
        self.actionFeedback = actionFeedback
        self.actionTitle = actionTitle
        self.secondaryActionTitle = secondaryActionTitle
        self.actionEnabled = actionEnabled
        self.closeTitle = closeTitle
    }
}

/// Where a read of every account's quota, from the header's button, is.
public enum QuotaRefreshPhase: Sendable, Equatable {
    case idle
    case refreshing
    /// The new figures just came in: they pop once and the arrow settles.
    case updated
}

public struct PanelHeaderState: Sendable, Equatable {
    public var title: String
    public var refresh: QuotaRefreshPhase
    /// False while a switch or another operation runs.
    public var canRefresh: Bool

    public init(title: String, refresh: QuotaRefreshPhase = .idle, canRefresh: Bool = true) {
        self.title = title
        self.refresh = refresh
        self.canRefresh = canRefresh
    }
}

/// A short line in the middle of the panel that blocks nothing: a confirmation that fades by itself,
/// or something under way that goes when it is done. One that can be undone carries a button for it.
public struct HUDState: Sendable, Equatable {
    /// A new one each time, so the same words shown twice in a row still show again.
    public var id: String
    public var text: String
    /// Under way: a turning arc instead of a tick.
    public var busy: Bool
    /// The undo button's word, when there is one.
    public var actionTitle: String?

    public init(id: String, text: String, busy: Bool = false, actionTitle: String? = nil) {
        self.id = id
        self.text = text
        self.busy = busy
        self.actionTitle = actionTitle
    }
}

public struct SettingsViewState: Sendable, Equatable {
    public var launchAtLogin: Bool
    /// Ask before a switch that a click starts.
    public var confirmSwitch: Bool
    public var autoSyncOnSwitch: Bool
    public var autoSwitchOnQuota: Bool
    public var autoCompactOnLowQuota: Bool
    /// Whether the compaction plugin is reporting, or that compaction is off, under its switch.
    public var autoCompactStatus: String
    public var autoCompactTone: CompactStatusTone
    public var appearance: AppearanceChoice
    public var language: LanguageChoice
    public var version: String
    /// False while an operation is in flight.
    public var controlsEnabled: Bool
    /// The plugin's own update failed: one row says so, with a retry.
    public var pluginUpdateFailed: Bool
    /// Signed-in profiles whose found-account banner was dismissed, each with an "add back" button.
    public var ignoredAccounts: [IgnoredAccountRow]

    public init(
        launchAtLogin: Bool = true,
        confirmSwitch: Bool = true,
        autoSyncOnSwitch: Bool = true,
        autoSwitchOnQuota: Bool = false,
        autoCompactOnLowQuota: Bool = true,
        autoCompactStatus: String = "",
        autoCompactTone: CompactStatusTone = .quiet,
        appearance: AppearanceChoice = .system,
        language: LanguageChoice = .system,
        version: String = "",
        controlsEnabled: Bool = true,
        pluginUpdateFailed: Bool = false,
        ignoredAccounts: [IgnoredAccountRow] = []
    ) {
        self.launchAtLogin = launchAtLogin
        self.confirmSwitch = confirmSwitch
        self.autoSyncOnSwitch = autoSyncOnSwitch
        self.autoSwitchOnQuota = autoSwitchOnQuota
        self.autoCompactOnLowQuota = autoCompactOnLowQuota
        self.autoCompactStatus = autoCompactStatus
        self.autoCompactTone = autoCompactTone
        self.appearance = appearance
        self.language = language
        self.version = version
        self.controlsEnabled = controlsEnabled
        self.pluginUpdateFailed = pluginUpdateFailed
        self.ignoredAccounts = ignoredAccounts
    }
}

public struct IgnoredAccountRow: Sendable, Equatable, Identifiable {
    /// The profile folder name.
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct PanelViewState: Sendable, Equatable {
    public var language: L10nLanguage
    public var header: PanelHeaderState
    public var current: AccountCardState?
    /// Nil when there is no other account to suggest.
    public var recommendation: RecommendationSlot?
    public var others: [AccountCardState]
    /// Notices waiting for the person, the first one in the dialog; the next shows once it goes.
    public var banners: [BannerState]
    public var addDialog: AddDialogState?
    public var switchDialog: SwitchDialogState?
    public var renameDialog: RenameDialogState?
    public var removeDialog: RemoveDialogState?
    public var pluginDialog: PluginDialogState?
    public var isSettingsOpen: Bool
    public var settings: SettingsViewState
    public var operationBusy: Bool
    public var hud: HUDState?

    public init(
        language: L10nLanguage,
        header: PanelHeaderState,
        current: AccountCardState? = nil,
        recommendation: RecommendationSlot? = nil,
        others: [AccountCardState] = [],
        banners: [BannerState] = [],
        addDialog: AddDialogState? = nil,
        switchDialog: SwitchDialogState? = nil,
        renameDialog: RenameDialogState? = nil,
        removeDialog: RemoveDialogState? = nil,
        pluginDialog: PluginDialogState? = nil,
        isSettingsOpen: Bool = false,
        settings: SettingsViewState = SettingsViewState(),
        operationBusy: Bool = false,
        hud: HUDState? = nil
    ) {
        self.language = language
        self.header = header
        self.current = current
        self.recommendation = recommendation
        self.others = others
        self.banners = banners
        self.addDialog = addDialog
        self.switchDialog = switchDialog
        self.renameDialog = renameDialog
        self.removeDialog = removeDialog
        self.pluginDialog = pluginDialog
        self.isSettingsOpen = isSettingsOpen
        self.settings = settings
        self.operationBusy = operationBusy
        self.hud = hud
    }

    public static func placeholder(
        language: L10nLanguage = L10nLanguage.resolve(preferredLanguages: Locale.preferredLanguages)
    ) -> PanelViewState {
        PanelViewState(
            language: language,
            header: PanelHeaderState(title: L10nKey.productName.string(in: language))
        )
    }

    /// Any dialog of the panel's own: a switch, an account being added, renamed or removed, the plugin.
    public var hasDialog: Bool {
        switchDialog != nil || addDialog != nil || renameDialog != nil || removeDialog != nil || pluginDialog != nil
    }

    /// The notice in the dialog: the first one waiting. It waits while a switch or another operation
    /// runs, and while another dialog shows: its answers could not act until then.
    public var shownNotice: BannerState? {
        !hasDialog && !operationBusy ? banners.first : nil
    }

    /// The add button rests while something runs or a dialog is open.
    public var canAddAccount: Bool {
        !interactionLocked && !hasDialog
    }

    public var interactionLocked: Bool {
        if operationBusy { return true }
        if current?.status.isSwitching == true { return true }
        return others.contains { $0.status.isSwitching }
    }
}

enum NameCheck {
    enum Problem: Equatable {
        case empty
        case tooLong
    }

    static func problem(in name: String) -> Problem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.count > Metrics.maxNameCharacters { return .tooLong }
        return nil
    }

    static func message(for problem: Problem, language: L10nLanguage) -> String {
        switch problem {
        case .empty: L10nKey.nameEmpty.string(in: language)
        case .tooLong: L10nKey.nameTooLong.string(in: language)
        }
    }
}
