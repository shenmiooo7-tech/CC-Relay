import Foundation

/// Facts read from the selected native conversation, never an instruction to replay a tool.
public struct NativeWorkSnapshot: Codable, Equatable, Sendable {
    public var version: Int = 1
    public let desktopSessionID: String
    public let cliSessionID: String
    public let cwd: String
    public let capturedAt: Double
    public let sourceProfile: String
    public let sourceAccountID: String
    public let transcriptPath: String
    public let transcriptSize: Int64
    public let headUUID: String?
    public let headSource: String
    public let branchComplete: Bool
    /// Verified native fork ancestors connect copied history; none of their work is inherited.
    public let ancestorSessionIDs: [String]?
    public let warnings: [String]
    public let latestUser: NativeWorkPointer?
    public let latestAssistant: NativeWorkPointer?
    public let latestAssistantInterrupted: Bool
    public let latestAssistantStopReason: String?
    public let tasks: [NativeWorkTask]
    public let artifacts: [NativeArtifactReference]
    /// Encoded explicitly for the native-session bridge. Inspection is not authorization to rerun.
    public let needsContinuation: Bool

    public var tasksNeedingInspection: [NativeWorkTask] { tasks.filter { $0.state.needsInspection } }
    public var tasksNeedingAttention: [NativeWorkTask] { tasks.filter { $0.state == .failed } }
    public var hasArmedArtifactWatches: Bool { branchComplete && artifacts.contains { $0.state == "armed" } }
    /// The pages of its armed comment watches, each once, by their plain link.
    public var armedPages: [String] {
        var seen = Set<String>()
        return artifacts.filter { $0.state == "armed" }.compactMap(\.page).filter { seen.insert($0).inserted }
    }

    public init(desktopSessionID: String, cliSessionID: String, cwd: String, capturedAt: Double,
                sourceProfile: String, sourceAccountID: String, transcriptPath: String, transcriptSize: Int64,
                headUUID: String?, headSource: String, branchComplete: Bool, warnings: [String] = [],
                latestUser: NativeWorkPointer? = nil, latestAssistant: NativeWorkPointer? = nil,
                latestAssistantInterrupted: Bool = false, latestAssistantStopReason: String? = nil,
                tasks: [NativeWorkTask] = [], artifacts: [NativeArtifactReference] = [],
                ancestorSessionIDs: [String]? = nil) {
        self.desktopSessionID = desktopSessionID; self.cliSessionID = cliSessionID; self.cwd = cwd
        self.capturedAt = capturedAt; self.sourceProfile = sourceProfile; self.sourceAccountID = sourceAccountID
        self.transcriptPath = transcriptPath; self.transcriptSize = transcriptSize
        self.headUUID = headUUID; self.headSource = headSource; self.branchComplete = branchComplete; self.warnings = warnings
        self.ancestorSessionIDs = ancestorSessionIDs
        self.latestUser = latestUser; self.latestAssistant = latestAssistant
        self.latestAssistantInterrupted = latestAssistantInterrupted; self.latestAssistantStopReason = latestAssistantStopReason
        self.tasks = tasks; self.artifacts = artifacts
        let workStart = latestUser?.sourceLine ?? 0
        needsContinuation = branchComplete && (latestAssistantInterrupted || tasks.contains {
            $0.state.needsInspection && max($0.sourceLine, $0.resultLine ?? 0) >= workStart
        })
    }

    /// The same facts without the claim that they make a whole branch: nothing is replayed from them,
    /// and the conversation still goes on from its own history.
    func unverified() -> NativeWorkSnapshot {
        NativeWorkSnapshot(desktopSessionID: desktopSessionID, cliSessionID: cliSessionID, cwd: cwd,
            capturedAt: capturedAt, sourceProfile: sourceProfile, sourceAccountID: sourceAccountID,
            transcriptPath: transcriptPath, transcriptSize: transcriptSize, headUUID: headUUID,
            headSource: headSource, branchComplete: false, warnings: warnings,
            latestUser: latestUser, latestAssistant: latestAssistant,
            latestAssistantInterrupted: latestAssistantInterrupted, latestAssistantStopReason: latestAssistantStopReason,
            tasks: tasks, artifacts: artifacts, ancestorSessionIDs: ancestorSessionIDs)
    }

    /// A conversation whose history could not be read: it only goes on from that history itself.
    static func unread(_ record: ContinuityRecord, profile: ProfileSnapshot, accountID: String, now: Date) -> NativeWorkSnapshot {
        NativeWorkSnapshot(desktopSessionID: record.sessionID, cliSessionID: record.cliSessionID,
            cwd: record.worktreePath ?? record.cwd, capturedAt: now.timeIntervalSince1970 * 1000,
            sourceProfile: profile.folder.name, sourceAccountID: accountID, transcriptPath: "", transcriptSize: 0,
            headUUID: nil, headSource: "unread", branchComplete: false, warnings: ["historyUnreadable"])
    }

    /// A small refusal keeps the evidence location visible without producing an unreadable ticket.
    func sizeRefusal() -> NativeWorkSnapshot {
        NativeWorkSnapshot(desktopSessionID: desktopSessionID, cliSessionID: cliSessionID, cwd: cwd,
            capturedAt: capturedAt, sourceProfile: sourceProfile, sourceAccountID: sourceAccountID,
            transcriptPath: transcriptPath, transcriptSize: transcriptSize, headUUID: headUUID,
            headSource: headSource, branchComplete: false,
            warnings: ["Snapshot too large: \(tasks.count) task records and \(artifacts.count) artifact records remain in the original transcript."],
            latestUser: latestUser, latestAssistant: latestAssistant)
    }
    func carryingCommands(_ ids: Set<String>, agentIDs: Set<String> = []) -> NativeWorkSnapshot {
        NativeWorkSnapshot(desktopSessionID: desktopSessionID, cliSessionID: cliSessionID, cwd: cwd,
            capturedAt: capturedAt, sourceProfile: sourceProfile, sourceAccountID: sourceAccountID,
            transcriptPath: transcriptPath, transcriptSize: transcriptSize, headUUID: headUUID,
            headSource: headSource, branchComplete: branchComplete,
            warnings: warnings + ["Only surviving commands and their unfinished original owners were carried; unrelated agent or artifact attempts are not replayed."],
            latestUser: latestUser, latestAssistant: latestAssistant,
            tasks: tasks.filter { (ids.contains($0.id) && [.bash, .monitor].contains($0.kind)) ||
                ($0.kind == .agent && agentIDs.contains($0.id) && $0.state.needsInspection) },
            ancestorSessionIDs: ancestorSessionIDs)
    }

    func markingExplicitStops(_ stopped: [NativeRuntimeTask]) -> NativeWorkSnapshot {
        guard !stopped.isEmpty else { return self }
        let ids = Set(stopped.flatMap { [$0.id] + ($0.aliases ?? []) })
        let uses = Set(stopped.compactMap(\.toolUseID).filter { !$0.isEmpty })
        let updated = tasks.map { original -> NativeWorkTask in
            var task = original
            if ids.contains(task.id) || uses.contains(task.toolUseID) { task.state = .stopped; task.explicitlyStopped = true }
            return task
        }
        return NativeWorkSnapshot(desktopSessionID: desktopSessionID, cliSessionID: cliSessionID, cwd: cwd,
            capturedAt: capturedAt, sourceProfile: sourceProfile, sourceAccountID: sourceAccountID,
            transcriptPath: transcriptPath, transcriptSize: transcriptSize, headUUID: headUUID,
            headSource: headSource, branchComplete: branchComplete, warnings: warnings,
            latestUser: latestUser, latestAssistant: latestAssistant, latestAssistantInterrupted: latestAssistantInterrupted,
            latestAssistantStopReason: latestAssistantStopReason, tasks: updated, artifacts: artifacts,
            ancestorSessionIDs: ancestorSessionIDs)
    }

    /// A native output client may be replaced during handoff. Its original transcript ID can
    /// remain interrupted even after the verified execution and its continuation have ended.
    func markingFinishedCommands(_ states: [String: NativeWorkState]) -> NativeWorkSnapshot {
        guard !states.isEmpty else { return self }
        var tasks = tasks
        for index in tasks.indices where [.bash, .monitor].contains(tasks[index].kind) {
            if let state = states[tasks[index].toolUseID], [.completed, .failed].contains(state),
               tasks[index].explicitlyStopped != true { tasks[index].state = state }
        }
        return NativeWorkSnapshot(desktopSessionID: desktopSessionID, cliSessionID: cliSessionID, cwd: cwd,
            capturedAt: capturedAt, sourceProfile: sourceProfile, sourceAccountID: sourceAccountID,
            transcriptPath: transcriptPath, transcriptSize: transcriptSize, headUUID: headUUID,
            headSource: headSource, branchComplete: branchComplete, warnings: warnings,
            latestUser: latestUser, latestAssistant: latestAssistant, latestAssistantInterrupted: latestAssistantInterrupted,
            latestAssistantStopReason: latestAssistantStopReason, tasks: tasks, artifacts: artifacts,
            ancestorSessionIDs: ancestorSessionIDs)
    }
}

public struct NativeWorkPointer: Codable, Equatable, Sendable {
    public let uuid: String
    public let sourceLine: Int
    public let timestamp: String?
    public init(uuid: String, sourceLine: Int, timestamp: String? = nil) {
        self.uuid = uuid; self.sourceLine = sourceLine; self.timestamp = timestamp
    }
}

public enum NativeWorkKind: String, Codable, Sendable { case bash, monitor, agent }

public enum NativeWorkState: String, Codable, Sendable {
    case requested, backgroundRegistered, completed, failed, stopped, interrupted, unknown
    public var needsInspection: Bool {
        self == .requested || self == .backgroundRegistered || self == .interrupted || self == .unknown
    }
}

public struct NativeWorkTask: Codable, Equatable, Sendable {
    public var id: String
    public let toolUseID: String
    public let kind: NativeWorkKind
    public var state: NativeWorkState
    public let description: String?
    public let agentType: String?
    public let sourceLine: Int
    public var resultLine: Int?
    public var outputPath: String?
    /// A successful native TaskStop, distinct from an output client stopped during teardown.
    public var explicitlyStopped: Bool?

    public init(id: String, toolUseID: String, kind: NativeWorkKind, state: NativeWorkState,
                description: String? = nil, agentType: String? = nil, sourceLine: Int,
                resultLine: Int? = nil, outputPath: String? = nil, explicitlyStopped: Bool? = nil) {
        self.id = id; self.toolUseID = toolUseID; self.kind = kind; self.state = state
        self.description = description; self.agentType = agentType; self.sourceLine = sourceLine
        self.resultLine = resultLine; self.outputPath = outputPath
        self.explicitlyStopped = explicitlyStopped
    }
}

public struct NativeArtifactReference: Codable, Equatable, Sendable {
    public var id: String?
    public var url: String?
    /// Persisted subscription intent, not proof that a live connection exists in the new account.
    public var state: String?
    public var sourceLine: Int?
    /// Whether automatic comment replies were armed, separately from the socket subscription.
    public var replies: Bool?
    public init(id: String? = nil, url: String? = nil, state: String? = nil, sourceLine: Int? = nil, replies: Bool? = nil) {
        self.id = id; self.url = url; self.state = state; self.sourceLine = sourceLine; self.replies = replies
    }
    /// The page's plain link: the same for its `/code/` form and with a closing slash.
    public var page: String? {
        guard var link = url?.replacingOccurrences(of: "/code/artifact/", with: "/artifact/") else { return nil }
        if link.hasSuffix("/") { link.removeLast() }
        return link
    }
}

/// Small, read-only startup input; no message bodies or executable tool parameters cross the bridge.
public struct NativeArtifactRecoveryInput: Codable, Equatable, Sendable {
    public var version = 1
    public let sessionID: String
    public let branchComplete: Bool
    public let artifacts: [NativeArtifactReference]
}

public enum NativeWorkCaptureFailure: Error, Equatable, Sendable {
    case invalidSession, transcriptMissing, ambiguousTranscript, unreadable, permissionDenied, lineTooLarge, transcriptTooLarge
}
