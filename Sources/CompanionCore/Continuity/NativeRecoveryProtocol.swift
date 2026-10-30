import Foundation

/// The background tasks the host listed at a conversation's latest Stop or SubagentStop, by ID,
/// type and state only, beside the plugin's own tracking.
public struct NativeHostWorkInventory: Codable, Equatable, Sendable {
    public struct Task: Codable, Equatable, Sendable {
        public var id: String
        public var type: String
        public var status: String
        public init(id: String, type: String, status: String) {
            self.id = id; self.type = type; self.status = status
        }
    }
    public var backgroundTasks: [Task]
    public init(backgroundTasks: [Task] = []) { self.backgroundTasks = backgroundTasks }
}

public struct NativeRuntimeTask: Codable, Equatable, Sendable {
    public var id: String
    public var kind: NativeWorkKind
    public var toolUseID: String?
    public var agentID: String?
    public var jobID: String?
    public var deadlineAt: Double?
    public var aliases: [String]?
    public var registeredAt: Double?
    public init(id: String, kind: NativeWorkKind, toolUseID: String? = nil, agentID: String? = nil,
                jobID: String? = nil, deadlineAt: Double? = nil, aliases: [String]? = nil, registeredAt: Double? = nil) {
        self.id = id; self.kind = kind; self.toolUseID = toolUseID; self.agentID = agentID
        self.jobID = jobID; self.deadlineAt = deadlineAt
        self.aliases = aliases
        self.registeredAt = registeredAt
    }
}

/// A per-process plugin report, independently checked against the OS and profile before arming.
public struct NativeRuntimeReport: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var sessionID: String
    public var instanceID: String
    public var pid: Int32
    public var procStart: String
    public var reportedAt: Double
    public var busy: Bool
    public var userStopped: Bool
    public var capabilities: [String]
    public var activeTasks: [NativeRuntimeTask]?
    public var quotaBlock: NativeQuotaBlock?
    public var hostWorkInventory: NativeHostWorkInventory?

    public init(sessionID: String, instanceID: String, pid: Int32, procStart: String,
                reportedAt: Double, busy: Bool = false, userStopped: Bool = false,
                capabilities: [String] = ["native-recovery-v1", "native-recovery-v2", "native-recovery-v3", "native-recovery-v4", "native-recovery-v6"],
                activeTasks: [NativeRuntimeTask]? = nil, quotaBlock: NativeQuotaBlock? = nil,
                hostWorkInventory: NativeHostWorkInventory? = nil) {
        self.sessionID = sessionID; self.instanceID = instanceID; self.pid = pid; self.procStart = procStart
        self.reportedAt = reportedAt; self.busy = busy; self.userStopped = userStopped; self.capabilities = capabilities
        self.activeTasks = activeTasks
        self.quotaBlock = quotaBlock
        self.hostWorkInventory = hostWorkInventory
    }
}

public struct NativeProcessSession: Equatable, Sendable {
    public var sessionID: String
    public var pid: Int32
    public var startedAt: Date
    public var busy: Bool
    public init(sessionID: String, pid: Int32, startedAt: Date, busy: Bool) {
        self.sessionID = sessionID; self.pid = pid; self.startedAt = startedAt; self.busy = busy
    }
}

public protocol NativeRuntimeInspecting: Sendable {
    func sessions(profile: URL) async -> [NativeProcessSession]
    func validate(_ report: NativeRuntimeReport, profile: URL, account: AccountIdentity) async -> Bool
}

/// Delivers a validated conversation link to the already running target profile.
/// Implementations must never start another Desktop instance or request broader permissions.
public protocol NativeConversationOpening: Sendable {
    func open(profile: URL, account: AccountIdentity, desktopSessionID: String) async throws
}

public struct NativeRecoveryOperation: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var operationID: String
    public var targetProfile: String
    public var targetAccountID: String
    public var createdAt: Double
    public var ready: Bool = false
    /// Native wakeup may arrive during launch. It can be held, but no request can bind yet.
    public var launchPrepared: Bool?
    public var primaryDesktopSessionID: String?
    public var autoActivationUntil: Double?
    public var focusRestoreAttemptedAt: Double?
    public var sessionIDs: [String]?
    public var sourceProcesses: [NativeRecoverySourceProcess]?
    /// Every request reached a final state; nothing is polled for this operation any more.
    public var finishedAt: Double?
    /// The account the switch left; a return after a failed transfer has none.
    public var sourceProfile: String?
    /// When the target account was open and its conversations could start reporting.
    public var readyAt: Double?
    public init(operationID: String, targetProfile: String, targetAccountID: String, createdAt: Double) {
        self.operationID = operationID; self.targetProfile = targetProfile
        self.targetAccountID = targetAccountID; self.createdAt = createdAt
    }
}

public struct NativeRecoverySourceProcess: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startedAt: Double
    public init(pid: Int32, startedAt: Double) { self.pid = pid; self.startedAt = startedAt }
}

public struct NativeRecoveryRequest: Codable, Sendable {
    public var version: Int = 1
    public var requiredCapability: String? = "native-recovery-v6"
    public var operationID: String
    public var requestID: String
    public var sessionID: String
    public var desktopSessionID: String
    public var targetProfile: String
    public var targetAccountID: String
    public var targetOrganizationID: String?
    public var createdAt: Double
    public var expiresAt: Double
    public var runtimeNotBefore: Double
    public var phase: String = "prepared"
    public var instanceID: String?
    public var pid: Int32?
    public var procStart: String?
    public var armedAt: Double?
    public var runtimeStartedAt: Double?
    public var sourcePID: Int32?
    public var sourceStartedAt: Double?
    public var sourceWasBusy: Bool
    public var sourceUserStopped: Bool = false
    public var activationAttemptedAt: Double?
    public var activationSent: Bool?
    public var activationError: String?
    public var runtimeError: String?
    public var sourceActiveTasks: [NativeRuntimeTask]?
    public var previousAgentResumeIDs: [String]?
    public var work: NativeWorkSnapshot

    public init(operation: NativeRecoveryOperation, target: AccountIdentity,
                work: NativeWorkSnapshot, source: NativeProcessSession?, now: Date) {
        operationID = operation.operationID; requestID = UUID().uuidString
        sessionID = work.cliSessionID; desktopSessionID = work.desktopSessionID
        targetProfile = operation.targetProfile; targetAccountID = target.accountUUID
        targetOrganizationID = target.activeOrganizationUUID
        createdAt = now.timeIntervalSince1970 * 1000; expiresAt = createdAt + 86_400_000
        runtimeNotBefore = operation.createdAt
        sourcePID = source?.pid; sourceStartedAt = source.map { $0.startedAt.timeIntervalSince1970 * 1000 }
        sourceWasBusy = source?.busy == true; self.work = work
    }
}

public struct NativeRecoveryEvidence: Codable, Equatable, Sendable {
    public var tool: String
    public var toolUseID: String?
    public var agentID: String?
    public var taskID: String?
    public var outcome: String
    public var timestamp: Double
}

/// Submission, actual execution and an ended continuation turn are deliberately different states.
public struct NativeRecoveryResult: Codable, Sendable {
    public var version: Int
    public var operationID: String
    public var requestID: String
    public var sessionID: String
    public var instanceID: String
    public var pid: Int32
    public var status: String
    public var updatedAt: Double
    public var turnID: String?
    public var error: String?
    public var evidence: [NativeRecoveryEvidence]
    public var tasks: [NativeRecoveryTaskResult]? = nil
}

public struct NativeRecoveryTaskResult: Codable, Sendable {
    public var sourceTaskID: String
    public var jobID: String?
    public var newTaskID: String?
    public var status: String?
    public var registeredAt: Double?
}

/// Safe, localizable reasons. Raw tool errors stay in the local recovery records.
public struct NativeRecoveryIssue: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case missingRecord, incompatibleRuntime, blocked, runtimeUnavailable
        case expired, conversationUnavailable, executionFailed, recoveryIncomplete
    }
    public var sessionID: String
    public var reason: Reason

    public init(sessionID: String, reason: Reason) {
        self.sessionID = sessionID
        self.reason = reason
    }
}

public struct NativeRecoverySummary: Codable, Equatable, Sendable {
    public var operationID: String
    public var waiting: Int = 0
    public var submitted: Int = 0
    public var executing: Int = 0
    public var ended: Int = 0
    public var inspected: Int = 0
    public var attention: Int = 0
    /// Optional so older saved snapshots remain readable.
    public var issues: [NativeRecoveryIssue]?
    /// Protected background commands of a reply the person stopped before the switch, which the
    /// switch ended: no problem, but news to them.
    public var endedWithSwitch: Int = 0
    /// No request can change any more: the summary is the operation's last word.
    public var finished = false
    /// The accounts the work moved between. A return after a failed transfer names no source.
    public var from: ProfileFolder?
    public var to: ProfileFolder?
    /// The conversations the switch opened may not have reported yet, so nothing about them is a
    /// problem so far.
    public var settling = false
    public var total: Int { waiting + submitted + executing + ended + inspected + attention + endedWithSwitch }
    public init(operationID: String) { self.operationID = operationID }

    /// How long after the target account opens its conversations are given to report.
    public static let settlingTime: TimeInterval = 30
}

/// A conversation whose Artifact comment watch stayed with the account that published the page
/// when that account closed, whether the conversation went on in another account or stayed. No
/// other account can open the page; the conversation is started again for the watch the next
/// time CC-Relay opens that account, unless that opening carries it on anyway.
public struct NativeLeftWatch: Codable, Equatable, Sendable {
    public var desktopSessionID: String
    public var sessionID: String
    public var title: String?
    public var leftAt: Double
    /// The watched pages, by their plain link. Absent in older records, which keep every watch of
    /// the conversation.
    public var pages: [String]?
    /// The account has opened since: nothing is started for the watch any more, and the record is
    /// kept only to tell the other accounts whose page it is.
    public var opened: Bool?

    public init(desktopSessionID: String, sessionID: String, title: String?, leftAt: Double, pages: [String]? = nil) {
        self.desktopSessionID = desktopSessionID; self.sessionID = sessionID; self.title = title; self.leftAt = leftAt
        self.pages = pages
    }

    var markedOpened: NativeLeftWatch { var watch = self; watch.opened = true; return watch }
}

/// An open Claude and the account it is open on. The plugin finds the Claude it runs under among
/// its own parent processes, by its PID and start as the process list shows them, so that each
/// conversation tells the watches kept for its own account from those kept for another.
public struct NativeOpenAccount: Codable, Equatable, Sendable {
    public var pid: Int32
    public var procStart: String
    public var account: String

    public init(_ instance: ClaudeInstance, account: ProfileFolder) {
        pid = instance.pid; procStart = TaskGuardEvaluator.registryStartTime(instance.startedAt); self.account = account.name
    }
}

/// Read by the plugin when the conversation starts: CC-Relay started it only for its watch, so
/// Desktop's own continue that follows is no request for a model turn. The plugin marks it used.
struct NativeWatchReopen: Codable, Equatable {
    var version = 1
    var sessionID: String
    var until: Double
    var used: Bool?
    /// The account it was started in, whose own kept watch the plugin picks up again.
    var account: String?
}

/// How often the engine looks at an operation: often while a switch is fresh, rarely while a
/// conversation may still be opened by hand, and not at all once every request is final.
public enum NativeRecoveryPace: Sendable, Equatable {
    case idle, slow, fast
}
