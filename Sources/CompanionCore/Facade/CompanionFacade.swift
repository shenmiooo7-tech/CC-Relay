import Foundation

public enum QuotaFreshness: String, Equatable, Sendable, Codable {
    case fresh
    case stale
    case refreshing
    case resetPassed
    case unavailable
}

public struct AccountSummary: Equatable, Sendable, Codable {
    public enum Status: String, Equatable, Sendable, Codable {
        case signedIn
        case signedOut
        case awaitingSignIn
        case unreadable
    }

    public var folder: ProfileFolder
    public var displayName: String
    public var status: Status
    public var email: String?
    public var plan: String?
    public var channel: SubscriptionChannel
    public var quota: QuotaSnapshot?
    public var quotaFreshness: QuotaFreshness
    public var quotaFailure: QuotaFailure?
    public var duplicateOf: ProfileFolder?

    public init(
        folder: ProfileFolder,
        displayName: String,
        status: Status,
        email: String? = nil,
        plan: String? = nil,
        channel: SubscriptionChannel = .unknown,
        quota: QuotaSnapshot? = nil,
        quotaFreshness: QuotaFreshness = .unavailable,
        quotaFailure: QuotaFailure? = nil,
        duplicateOf: ProfileFolder? = nil
    ) {
        self.folder = folder
        self.displayName = displayName
        self.status = status
        self.email = email
        self.plan = plan
        self.channel = channel
        self.quota = quota
        self.quotaFreshness = quotaFreshness
        self.quotaFailure = quotaFailure
        self.duplicateOf = duplicateOf
    }
}

public enum SwitchStep: String, Equatable, Sendable, Codable {
    /// A long conversation is compacted on the account it is leaving, before Claude closes.
    case compactingConversation
    case closingClaude
    case syncingSessions
    case openingClaude
    case reopeningConversation
}

public enum AddAccountPhase: String, Equatable, Sendable, Codable {
    case closingClaude
    case waitingForSignIn
    case importingHistory
    case openingClaude
}

public enum OperationState: Equatable, Sendable, Codable {
    case switching(target: ProfileFolder, step: SwitchStep, completedSteps: [SwitchStep])
    case waitingForTasks(target: ProfileFolder)
    case addingAccount(phase: AddAccountPhase)
    case removing(folder: ProfileFolder)
    case autoCorrecting
}

/// Closed set of warnings. The UI localizes these; Core does not supply free text.
public enum OperationWarning: Equatable, Sendable, Codable {
    case sessionsNotSynced(count: Int)
    case backupFailed
    case conversationNotReopened
    case continuityCaptureFailed
    case activeOrganizationUnknown
    /// The conversation was long enough to compact before the switch and was not: its plugin did
    /// not answer in time, declined, failed or does not report it.
    case notCompactedFirst
    case workContinuationUnavailable
}

/// Closed set of failure reasons. The UI localizes these; Core does not supply free text.
public enum FailureReason: Equatable, Sendable, Codable {
    case couldNotCloseClaude
    case couldNotOpenClaude
    /// The target did not open; the account being left was reopened instead.
    case returnedToPreviousAccount
    /// The work could not be transferred; the source reopened without automatic continuation.
    case transferFailedReturnedToPreviousAccount
    case couldNotReadProcesses
    case targetMissing
    case targetUnreadable
    case couldNotPrepareContinuation
    /// The work could not be transferred and the original account could not be opened again either.
    case transferFailedNotReopened
    /// An automatic switch's target cannot run the conversation's permission mode; nothing was closed.
    case targetCannotContinue
    case operationInFlight
    case refusedActiveAccount
    case refusedLastAccount
    case refusedWhileRunning
    case runningStateUnknown
    case signedInAccountDiffers
    case cancelled
}

public enum FailedOperation: Equatable, Sendable, Codable {
    case switchTo(ProfileFolder)
    case addAccount
    case remove(ProfileFolder)
    case autoCorrect
    case historyImport(ProfileFolder)
}

public struct OperationResult: Equatable, Sendable, Codable {
    public enum Outcome: Equatable, Sendable, Codable {
        case switched(to: ProfileFolder, warnings: [OperationWarning])
        case added(folder: ProfileFolder, warnings: [OperationWarning])
        case removed(folder: ProfileFolder, partialCleanup: Bool)
        case failed(operation: FailedOperation, reason: FailureReason)
    }

    /// Lets the UI show a result once even when the next result has the same outcome.
    public var id: UUID
    public var finishedAt: Date
    public var outcome: Outcome

    public init(id: UUID, finishedAt: Date, outcome: Outcome) {
        self.id = id
        self.finishedAt = finishedAt
        self.outcome = outcome
    }
}

public struct TaskGuardPrompt: Equatable, Sendable, Codable {
    public var target: ProfileFolder
    public var busyCount: Int
    public var unknown: Bool
    public var isWaiting: Bool

    public init(target: ProfileFolder, busyCount: Int, unknown: Bool, isWaiting: Bool) {
        self.target = target
        self.busyCount = busyCount
        self.unknown = unknown
        self.isWaiting = isWaiting
    }
}

public struct PendingAddState: Equatable, Sendable, Codable {
    public var folder: ProfileFolder
    public var phase: AddAccountPhase
    /// Set when the account that just signed in is already registered.
    public var duplicateOf: ProfileFolder?

    public init(folder: ProfileFolder, phase: AddAccountPhase, duplicateOf: ProfileFolder? = nil) {
        self.folder = folder
        self.phase = phase
        self.duplicateOf = duplicateOf
    }
}

public enum Banner: Equatable, Sendable, Codable {
    /// `retryAt` is when automatic switching tries again, when that is known; `distantFuture` when
    /// only another account signing in can let it.
    case autoSwitchPaused(AutoSwitchPauseReason, retryAt: Date? = nil)
    /// Claude is neither in its usual place nor anywhere macOS knows it: nothing can be opened.
    case claudeNotFound
    /// Automatic switching waits: the named account has quota left but does not allow the
    /// conversation's bypass mode.
    case autoSwitchNeedsBypass(account: ProfileFolder)
    case foundAccount(folder: ProfileFolder)
    case autoCorrected(to: ProfileFolder)
    case autoCorrectPaused
    case historyImportPaused(folder: ProfileFolder, issue: HistoryIssue)
    case quotaUnavailable
    /// The plugin compacted a long conversation before the account ran out, or tried and failed.
    case autoCompacted(AutoCompactResult)
    case nativeRecovery(NativeRecoverySummary)
    /// Conversations that stayed on this account for their comment watch alone, by title (empty
    /// when untitled). They start again the next time CC-Relay opens the account.
    case watchesStayed(account: ProfileFolder, titles: [String])
}

/// What the compaction plugin last reported, for Settings.
public struct AutoCompactSummary: Equatable, Sendable, Codable {
    public var status: AutoCompactStatus
    public var lastResult: AutoCompactResult?

    public init(status: AutoCompactStatus = AutoCompactStatus(), lastResult: AutoCompactResult? = nil) {
        self.status = status
        self.lastResult = lastResult
    }
}

public struct CompanionSnapshot: Equatable, Sendable, Codable {
    public var accounts: [AccountSummary]
    public var currentFolder: ProfileFolder?
    public var claudeRunning: Bool
    public var operation: OperationState?
    public var isPreparingOperation: Bool
    public var lastResult: OperationResult?
    public var taskGuardPrompt: TaskGuardPrompt?
    public var banners: [Banner]
    public var pendingAdd: PendingAddState?
    public var settings: Settings
    public var appVersion: String
    /// Signed-in profiles whose found-account banner was dismissed; Settings can add them back.
    public var ignoredFolders: [ProfileFolder]
    public var autoCompact: AutoCompactSummary
    /// Whether CC-Relay's Claude Code plugin is ready; nil until it was first looked at.
    public var pluginReady: Bool?
    /// The plugin's update to the app's copy failed, and no install has succeeded since.
    public var pluginUpdateFailed: Bool

    public init(
        accounts: [AccountSummary] = [],
        currentFolder: ProfileFolder? = nil,
        claudeRunning: Bool = false,
        operation: OperationState? = nil,
        isPreparingOperation: Bool = false,
        lastResult: OperationResult? = nil,
        taskGuardPrompt: TaskGuardPrompt? = nil,
        banners: [Banner] = [],
        pendingAdd: PendingAddState? = nil,
        settings: Settings = Settings(),
        appVersion: String,
        ignoredFolders: [ProfileFolder] = [],
        autoCompact: AutoCompactSummary = AutoCompactSummary(),
        pluginReady: Bool? = nil,
        pluginUpdateFailed: Bool = false
    ) {
        self.accounts = accounts
        self.currentFolder = currentFolder
        self.claudeRunning = claudeRunning
        self.operation = operation
        self.isPreparingOperation = isPreparingOperation
        self.lastResult = lastResult
        self.taskGuardPrompt = taskGuardPrompt
        self.banners = banners
        self.pendingAdd = pendingAdd
        self.settings = settings
        self.appVersion = appVersion
        self.ignoredFolders = ignoredFolders
        self.autoCompact = autoCompact
        self.pluginReady = pluginReady
        self.pluginUpdateFailed = pluginUpdateFailed
    }

    public static func empty(appVersion: String = "0.1.0") -> CompanionSnapshot {
        CompanionSnapshot(appVersion: appVersion)
    }
}

public enum TaskGuardChoice: Equatable, Sendable, Codable {
    case waitThenSwitch
    case switchNow
    case cancel
}

public enum DuplicateAddChoice: Equatable, Sendable, Codable {
    case keepBoth
    case discardNew
}

public enum CompanionAction: Equatable, Sendable, Codable {
    case switchTo(folder: ProfileFolder)
    case taskGuard(TaskGuardChoice)
    /// Stop waiting for the compaction before a switch and switch now.
    case skipCompaction
    case addAccount
    case cancelAddAccount
    case resolveDuplicateAdd(DuplicateAddChoice)
    case rename(folder: ProfileFolder, name: String)
    case remove(folder: ProfileFolder)
    case addFoundAccount(folder: ProfileFolder)
    case dismissFoundAccount(folder: ProfileFolder)
    case retryHistoryImport(folder: ProfileFolder)
    case refreshQuota(folder: ProfileFolder?)
    case panelOpened
    case setAutoSync(Bool)
    case setAutoSwitch(Bool)
    /// Ask before a switch started from a click.
    case setConfirmSwitch(Bool)
    case setAutoCompact(Bool)
    /// Install CC-Relay's plugin into Claude Code, for a feature that needs it.
    case installPlugin
    case setLaunchAtLogin(Bool)
    case setLanguage(AppLanguage)
    case setAppearance(AppAppearance)
    case openBackupsFolder
    case openRecoveryFolder
    case dismissResult(id: UUID)
    case quitApp
}

/// Completion of a requested utility action. These receipts belong to the call that returned
/// them, so the UI never infers success from a separately delivered snapshot.
public enum CompanionActionReceipt: Equatable, Sendable {
    case quotaRefresh(updated: Int, requested: Int)
    case backupsOpened
    case recoveryFolderOpened
    case pluginInstalled
    case pluginNotInstalled(PluginInstallFailure)
    case failed
    /// The action was refused before it ran (for example, during shutdown).
    case notPerformed
    /// Other actions continue to report their outcomes through snapshots.
    case unreported
}

/// The only surface the UI talks to.
///
/// `snapshots()` emits the full current snapshot immediately, then again after
/// every change. `perform` never throws: outcomes arrive on the next snapshot
/// through `operation`, `lastResult`, and `banners`. Utility actions that display an immediate
/// confirmation use `performWithReceipt`, which returns their actual result.
public protocol CompanionFacade: Sendable {
    func snapshots() -> AsyncStream<CompanionSnapshot>
    func perform(_ action: CompanionAction) async
    func performWithReceipt(_ action: CompanionAction) async -> CompanionActionReceipt
}
