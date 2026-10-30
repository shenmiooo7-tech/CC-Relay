import Darwin
import Foundation

/// Reads native Claude records at a fixed file-size boundary. It never edits a transcript or runs a tool.
public struct NativeWorkCapture: Sendable {
    private let paths: AppPaths
    public init(paths: AppPaths) { self.paths = paths }

    /// Reopening the same CLI session needs no account-switch ticket. Resolve its one original
    /// transcript, including persisted native monitor records removed from in-memory compaction.
    public func artifactRecoveryInput(sessionID: String, cliHome: URL? = nil) throws -> NativeArtifactRecoveryInput {
        guard validID(sessionID) else { throw NativeWorkCaptureFailure.invalidSession }
        let transcript = try locate(sessionID, cliHome: cliHome)
        // This runs each time a conversation opens. Most never watched an artifact: with no mention of
        // one anywhere in the raw bytes, the whole transcript need not be parsed. A file that cannot be
        // read falls through to the capture below, which reports why.
        if let bytes = try? Data(contentsOf: transcript, options: .alwaysMapped), bytes.range(of: Data("rtifact".utf8)) == nil {
            return NativeArtifactRecoveryInput(sessionID: sessionID, branchComplete: true, artifacts: [])
        }
        var snapshot = try capture(transcript: transcript, desktopSessionID: "local_" + sessionID,
            cliSessionID: sessionID, cwd: "", sourceProfile: "", sourceAccountID: "")
        // A fork's branch connects only through its parents, which its Desktop record names.
        if !snapshot.branchComplete, let ancestors = forkAncestors(cliSessionID: sessionID) {
            snapshot = try capture(transcript: transcript, desktopSessionID: "local_" + sessionID,
                cliSessionID: sessionID, cwd: "", sourceProfile: "", sourceAccountID: "", ancestorSessionIDs: ancestors)
        }
        return NativeArtifactRecoveryInput(sessionID: sessionID, branchComplete: snapshot.branchComplete,
            artifacts: Array(snapshot.artifacts.filter { $0.state == "armed" }.prefix(33)))
    }

    /// Resolves one original Monitor input from disk when compaction removed it from the
    /// host's in-memory history. Parameters are returned in memory, never stored in a snapshot.
    public func monitorInput(work: NativeWorkSnapshot, task: NativeRuntimeTask) throws -> Data {
        guard work.branchComplete, task.kind == .monitor, task.jobID == nil,
              validID(work.cliSessionID), let toolID = task.toolUseID, validID(toolID),
              task.agentID.map(validID) != false else { throw NativeWorkCaptureFailure.invalidSession }
        let main = URL(fileURLWithPath: work.transcriptPath)
        guard main.lastPathComponent == work.cliSessionID + ".jsonl" else { throw NativeWorkCaptureFailure.invalidSession }
        let transcript = task.agentID.map {
            main.deletingPathExtension().appending(path: "subagents/agent-" + $0 + ".jsonl")
        } ?? main
        let read = try lines(transcript, after: nil, sessionID: work.cliSessionID,
                             fresh: NativeTranscriptFacts(monitorToolUseID: toolID, sidechainAgentID: task.agentID,
                                 ancestorSessionIDs: task.agentID == nil ? Set(work.ancestorSessionIDs ?? []) : []))
        var parsed = read.checkpoint.facts
        if let tail = read.tail { autoreleasepool { parsed.consume(tail, line: read.checkpoint.lineCount + 1, sessionID: work.cliSessionID) } }
        let size = read.size
        let snapshot = parsed.snapshot(desktopSessionID: work.desktopSessionID, cliSessionID: work.cliSessionID,
            cwd: work.cwd, sourceProfile: work.sourceProfile, sourceAccountID: work.sourceAccountID,
            transcript: transcript, size: size, preferredHead: task.agentID == nil ? work.headUUID : nil,
            published: [], now: Date())
        let ids = Set([task.id] + (task.aliases ?? []))
        let matches = snapshot.tasks.filter { $0.kind == .monitor && $0.toolUseID == toolID && ids.contains($0.id) }
        guard snapshot.branchComplete, matches.count == 1, let match = matches.first,
              match.state.needsInspection, match.explicitlyStopped != true else { throw NativeWorkCaptureFailure.invalidSession }
        let calls = parsed.rows.values.flatMap { row in row.events.compactMap { event -> (Int, Data?)? in
            guard case .call(let call) = event, call.id == toolID, call.name == "Monitor" else { return nil }
            return (row.line, call.monitorInput)
        } }
        guard calls.count == 1, let call = calls.first, call.0 == match.sourceLine,
              let input = call.1 else { throw NativeWorkCaptureFailure.invalidSession }
        return input
    }

    public func capture(_ continuity: ContinuityCapture, profile: ProfileSnapshot,
                        now: Date = Date()) throws -> NativeWorkSnapshot {
        var fresh: NativeCaptureCheckpoint?
        return try capture(continuity, profile: profile, now: now, checkpoint: &fresh)
    }

    /// Continues from `checkpoint` when the transcript only grew since it was taken, so a
    /// conversation read before Desktop closed is not read again in full afterwards.
    public func capture(_ continuity: ContinuityCapture, profile: ProfileSnapshot, now: Date = Date(),
                        checkpoint: inout NativeCaptureCheckpoint?) throws -> NativeWorkSnapshot {
        let record = continuity.record
        guard validID(record.cliSessionID), record.sessionID.hasPrefix("local_"),
              case .signedIn(let identity) = profile.status,
              identity.accountUUID == continuity.sourceIdentity.accountUUID,
              let org = identity.activeOrganizationUUID else { throw NativeWorkCaptureFailure.invalidSession }
        let bucket = try SessionBucket(accountUUID: identity.accountUUID, organizationUUID: org)
        let desktop = profile.url.appending(path: bucket.relativePath).appending(path: record.sessionID + ".json")
        let io = SessionFileIO()
        try io.checkPath(desktop, under: profile.url)
        guard let object = try JSONSerialization.jsonObject(with: io.read(desktop)) as? [String: Any],
              object["sessionId"] as? String == record.sessionID,
              object["cliSessionId"] as? String == record.cliSessionID else { throw NativeWorkCaptureFailure.invalidSession }
        let transcript = try locate(record.cliSessionID)
        let references = (object["publishedArtifacts"] as? [[String: Any]] ?? []).compactMap { value -> NativeArtifactReference? in
            guard let url = artifactURL(value["url"] as? String) else { return nil }
            return NativeArtifactReference(id: value["artifact_id"] as? String, url: url)
        }
        return try capture(transcript: transcript, desktopSessionID: record.sessionID, cliSessionID: record.cliSessionID,
                           cwd: record.worktreePath ?? record.cwd, sourceProfile: profile.folder.name,
                           sourceAccountID: identity.accountUUID, preferredHeadUUID: object["lastAssistantUuid"] as? String,
                           artifacts: references,
                           ancestorSessionIDs: try forkAncestors(object, profileURL: profile.url, bucket: bucket),
                           now: now, checkpoint: &checkpoint)
    }

    /// Desktop copies a fork's earlier nodes verbatim, including their original CLI session IDs.
    /// Only records explicitly linked in this same account bucket can supply ancestry connectors.
    private func forkAncestors(_ record: [String: Any], profileURL: URL, bucket: SessionBucket) throws -> Set<String> {
        let io = SessionFileIO()
        var record = record, seen = Set<String>(), ancestors = Set<String>()
        for _ in 0..<16 {
            guard let parent = record["forkedFromSessionId"] as? String,
                  parent.hasPrefix("local_"), validID(parent), seen.insert(parent).inserted else { break }
            let file = profileURL.appending(path: bucket.relativePath).appending(path: parent + ".json")
            try io.checkPath(file, under: profileURL)
            guard try io.info(file) != nil,
                  let source = try JSONSerialization.jsonObject(with: io.read(file)) as? [String: Any],
                  source["sessionId"] as? String == parent,
                  let cli = source["cliSessionId"] as? String, validID(cli) else { break }
            ancestors.insert(cli); record = source
        }
        return ancestors
    }

    /// The fork ancestry of a conversation known only by its CLI session, as when it opens again: its
    /// Desktop record is looked for in every profile's session buckets, and only the bucket it is found
    /// in may link it to parents. Nil when no record there names any.
    private func forkAncestors(cliSessionID: String) -> Set<String>? {
        let io = SessionFileIO(), mention = Data(cliSessionID.utf8)
        func children(_ url: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        }
        for profile in children(paths.claudeProfilesRoot) where profile.lastPathComponent.hasPrefix("Claude") {
            for account in children(profile.appending(path: "claude-code-sessions")) {
                for organization in children(account) {
                    guard let bucket = try? SessionBucket(accountUUID: account.lastPathComponent,
                                                          organizationUUID: organization.lastPathComponent) else { continue }
                    for file in children(organization) where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                        guard (try? io.checkPath(file, under: profile)) != nil,
                              let data = try? io.read(file), data.range(of: mention) != nil,
                              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                              record["cliSessionId"] as? String == cliSessionID,
                              let ancestors = try? forkAncestors(record, profileURL: profile, bucket: bucket),
                              !ancestors.isEmpty else { continue }
                        return ancestors
                    }
                }
            }
        }
        return nil
    }

    /// A separate entry point makes branch and task-status parsing testable without live account data.
    func capture(transcript: URL, desktopSessionID: String, cliSessionID: String, cwd: String,
                 sourceProfile: String = "test", sourceAccountID: String = "test",
                 preferredHeadUUID: String? = nil, artifacts: [NativeArtifactReference] = [],
                 ancestorSessionIDs: Set<String> = [],
                 now: Date = Date()) throws -> NativeWorkSnapshot {
        var fresh: NativeCaptureCheckpoint?
        return try capture(transcript: transcript, desktopSessionID: desktopSessionID, cliSessionID: cliSessionID, cwd: cwd,
                           sourceProfile: sourceProfile, sourceAccountID: sourceAccountID, preferredHeadUUID: preferredHeadUUID,
                           artifacts: artifacts, ancestorSessionIDs: ancestorSessionIDs, now: now, checkpoint: &fresh)
    }

    func capture(transcript: URL, desktopSessionID: String, cliSessionID: String, cwd: String,
                 sourceProfile: String = "test", sourceAccountID: String = "test",
                 preferredHeadUUID: String? = nil, artifacts: [NativeArtifactReference] = [],
                 ancestorSessionIDs: Set<String> = [],
                 now: Date = Date(), checkpoint: inout NativeCaptureCheckpoint?) throws -> NativeWorkSnapshot {
        let read = try lines(transcript, after: checkpoint, sessionID: cliSessionID,
                             fresh: NativeTranscriptFacts(ancestorSessionIDs: ancestorSessionIDs))
        checkpoint = read.checkpoint
        // A last line without its newline may still be being written: it counts for this
        // snapshot, never for the checkpoint a later capture continues from.
        var parsed = read.checkpoint.facts
        if let tail = read.tail { autoreleasepool { parsed.consume(tail, line: read.checkpoint.lineCount + 1, sessionID: cliSessionID) } }
        return parsed.snapshot(desktopSessionID: desktopSessionID, cliSessionID: cliSessionID, cwd: cwd,
                               sourceProfile: sourceProfile, sourceAccountID: sourceAccountID, transcript: transcript,
                               size: read.size, preferredHead: preferredHeadUUID, published: artifacts, now: now)
    }

    private func locate(_ id: String, cliHome: URL? = nil) throws -> URL {
        let projects = (cliHome ?? paths.claudeCLIHome).appending(path: "projects")
        let fm = FileManager.default
        let directories: [URL]
        do {
            directories = try fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)
        } catch {
            let error = error as NSError
            if (error.domain == NSCocoaErrorDomain && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(error.code)) ||
                (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) {
                throw NativeWorkCaptureFailure.transcriptMissing
            }
            if error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoPermission.rawValue {
                throw NativeWorkCaptureFailure.permissionDenied
            }
            if error.domain == NSPOSIXErrorDomain { throw captureReadFailure(Int32(error.code)) }
            throw NativeWorkCaptureFailure.unreadable
        }
        var found: [URL] = []
        // Ordinary files in projects/ are not project buckets. A bucket that cannot be inspected
        // might hold the transcript, so when nothing turns up the lookup fails rather than reading
        // as an empty new session; it does not hide a transcript found in a readable bucket.
        var hidden: NativeWorkCaptureFailure?
        for directory in directories {
            var bucketInfo = stat()
            if stat(directory.path, &bucketInfo) != 0 {
                if errno != ENOENT { hidden = hidden ?? captureReadFailure(errno) }
                continue
            }
            guard bucketInfo.st_mode & S_IFMT == S_IFDIR else { continue }
            let candidate = directory.resolvingSymlinksInPath().appending(path: id + ".jsonl")
            var info = stat()
            if lstat(candidate.path, &info) == 0 {
                if info.st_mode & S_IFMT == S_IFREG { found.append(candidate) } else { hidden = hidden ?? .unreadable }
            } else if errno != ENOENT { hidden = hidden ?? captureReadFailure(errno) }
        }
        let unique = Set(found.map(\.path))
        if unique.isEmpty, let hidden { throw hidden }
        guard unique.count == 1, let path = unique.first else {
            throw unique.isEmpty ? NativeWorkCaptureFailure.transcriptMissing : NativeWorkCaptureFailure.ambiguousTranscript
        }
        return URL(fileURLWithPath: path)
    }

    private func lines(_ url: URL, after previous: NativeCaptureCheckpoint?, sessionID: String,
                       fresh: NativeTranscriptFacts = NativeTranscriptFacts()) throws
        -> (checkpoint: NativeCaptureCheckpoint, tail: Data?, size: Int64) {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw captureReadFailure(errno) }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw NativeWorkCaptureFailure.unreadable }
        guard info.st_size <= 1_073_741_824 else { throw NativeWorkCaptureFailure.transcriptTooLarge }
        let size = Int64(info.st_size), device = Int64(info.st_dev), inode = UInt64(info.st_ino)
        // Continue only where the same file merely grew: same inode, and the bytes just before
        // the old end unchanged. Anything else is read again from the start.
        var state = NativeCaptureCheckpoint(facts: fresh, path: url.path, device: device, inode: inode)
        if let previous, previous.path == url.path, previous.device == device, previous.inode == inode,
           previous.facts.ancestorSessionIDs == fresh.ancestorSessionIDs,
           previous.offset <= size, Self.fingerprint(fd, before: previous.offset) == previous.fingerprint {
            state = previous
        }
        guard lseek(fd, off_t(state.offset), SEEK_SET) == off_t(state.offset) else { throw NativeWorkCaptureFailure.unreadable }
        var remaining = size - state.offset, pending = Data(), consumed = state.offset
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while remaining > 0 {
            let count = Darwin.read(fd, &bytes, min(bytes.count, Int(remaining)))
            if count < 0 { if errno == EINTR { continue }; throw NativeWorkCaptureFailure.unreadable }
            guard count > 0 else { throw NativeWorkCaptureFailure.unreadable }
            remaining -= Int64(count)
            let pieces = bytes[..<count].split(separator: 10, omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                guard pending.count + piece.count <= 16 * 1024 * 1024 else { throw NativeWorkCaptureFailure.lineTooLarge }
                pending.append(contentsOf: piece)
                if index < pieces.count - 1 {
                    state.lineCount += 1
                    consumed += Int64(pending.count + 1)
                    autoreleasepool { state.facts.consume(pending, line: state.lineCount, sessionID: sessionID) }
                    pending.removeAll(keepingCapacity: true)
                }
            }
        }
        state.offset = consumed
        state.fingerprint = Self.fingerprint(fd, before: consumed)
        return (state, pending.isEmpty ? nil : pending, size)
    }

    /// Up to 4 KiB that end at `offset`: enough to notice a transcript rewritten in place.
    private static func fingerprint(_ fd: Int32, before offset: Int64) -> Data {
        let length = Int(min(4_096, offset))
        guard length > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: length)
        let count = pread(fd, &buffer, length, off_t(offset - Int64(length)))
        return count == length ? Data(buffer) : Data([0xFF])
    }
}

/// Where a capture stopped: the facts read so far and the end of the last complete line.
/// It lives only between the reads before and after Desktop closes, never on disk.
public struct NativeCaptureCheckpoint: Sendable {
    fileprivate var facts: NativeTranscriptFacts
    fileprivate let path: String
    fileprivate let device: Int64
    fileprivate let inode: UInt64
    fileprivate var offset: Int64 = 0
    fileprivate var lineCount = 0
    fileprivate var fingerprint = Data()

    fileprivate init(facts: NativeTranscriptFacts, path: String, device: Int64, inode: UInt64) {
        self.facts = facts; self.path = path; self.device = device; self.inode = inode
    }
}

private struct NativeTranscriptFacts {
    struct Row {
        var id: String; var parent: String?; var line: Int; var type: String; var timestamp: String?
        var physicalParent: String?; var physicalRoot: Bool; var preserved: PreservedSegment?; var compactSummary: Bool
        var human: Bool; var interrupted: Bool; var stopReason: String?; var compact: Bool
        var safeFollowup: Bool; var toolUses: [String]; var toolResults: [String]
        var events: [Event]
        var pointer: NativeWorkPointer { NativeWorkPointer(uuid: id, sourceLine: line, timestamp: timestamp) }
    }
    struct PreservedSegment {
        let head: String; let anchor: String; let tail: String
        init?(_ fields: [String: Any]?) {
            guard let head = fields?["headUuid"] as? String, validID(head),
                  let anchor = fields?["anchorUuid"] as? String, validID(anchor),
                  let tail = fields?["tailUuid"] as? String, validID(tail),
                  head != anchor, tail != anchor else { return nil }
            self.head = head; self.anchor = anchor; self.tail = tail
        }
    }
    struct Call {
        var id: String; var name: String; var kind: NativeWorkKind?; var background: Bool
        var targetID: String?; var description: String?; var agentType: String?
        var artifactURL: String?; var artifactStopped: Bool; var artifactStarted: Bool; var artifactReplies: Bool?
        var monitorInput: Data?
    }
    struct Result {
        var toolID: String; var nativeID: String?; var agentID: String?; var status: String?
        var isAsync: Bool; var error: Bool; var interrupted: Bool; var outputPath: String?
        var stopTarget: String?; var artifactID: String?; var artifactURL: String?
        var artifactWatching: Bool?; var artifactReplies: Bool?
        var resumedAgentID: String?
    }
    enum Event {
        case call(Call), result(Result)
        case notification(ids: [String], toolID: String?, state: NativeWorkState, kind: NativeWorkKind?)
        case status(id: String, kind: NativeWorkKind, state: NativeWorkState, output: String?)
    }
    struct ArtifactState { var id: String; var state: String; var line: Int; var writtenAt: Double }
    var rows: [String: Row] = [:]
    var lastID: String?
    var artifactStates: [ArtifactState] = []
    var malformed = false
    var monitorToolUseID: String?
    var sidechainAgentID: String?
    var ancestorSessionIDs: Set<String> = []
    var sawSessionNode = false

    mutating func consume(_ data: Data, line: Int, sessionID: String) {
        // These contain repeated message bodies, not transcript nodes. The fast path avoids
        // allocating their large payloads; a differently formatted line still gets parsed normally.
        let prefix = String(decoding: data.prefix(80), as: UTF8.self)
        if prefix.hasPrefix("{\"type\":\"api-") || prefix.hasPrefix("{\"type\": \"api-") { return }
        guard !data.isEmpty else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { malformed = true; return }
        guard let rowSession = object["sessionId"] as? String, let type = object["type"] as? String else { return }
        if rowSession != sessionID {
            // These prove the parent chain only. A fork does not acquire its parent's tasks,
            // pending prompts, artifact watches or reply consent through copied history.
            guard !sawSessionNode, ancestorSessionIDs.contains(rowSession),
                  ["user", "assistant", "system", "attachment"].contains(type),
                  object["isSidechain"] as? Bool != true,
                  let id = object["uuid"] as? String, validID(id) else { return }
            let compact = type == "system" && object["subtype"] as? String == "compact_boundary"
            let metadata = object["compactMetadata"] as? [String: Any]
            let preserved = metadata?["preservedSegment"] as? [String: Any]
            let physicalParent = object["parentUuid"] as? String
            let parent = physicalParent ?? (compact ? object["logicalParentUuid"] as? String ?? preserved?["tailUuid"] as? String : nil)
            rows[id] = Row(id: id, parent: parent, line: line, type: "ancestry", timestamp: object["timestamp"] as? String,
                           physicalParent: physicalParent, physicalRoot: object["parentUuid"] == nil || object["parentUuid"] is NSNull,
                           preserved: compact ? PreservedSegment(preserved) : nil,
                           compactSummary: type == "user" && object["isCompactSummary"] as? Bool == true,
                           human: false, interrupted: false, stopReason: nil, compact: compact,
                           safeFollowup: false, toolUses: [], toolResults: [], events: [])
            lastID = id
            return
        }
        if type == "artifact-comment-monitor", let artifacts = object["artifacts"] as? [String: [String: Any]] {
            for (id, value) in artifacts {
                guard validID(id), let state = value["state"] as? String else { continue }
                artifactStates.append(ArtifactState(id: id, state: String(state.prefix(64)), line: line,
                                                    writtenAt: (value["writtenAtMs"] as? NSNumber)?.doubleValue ?? 0))
            }
            return
        }
        if let sidechainAgentID, object["agentId"] as? String != sidechainAgentID { return }
        guard ["user", "assistant", "system", "attachment"].contains(type),
              object["isSidechain"] as? Bool != true || sidechainAgentID != nil,
              let id = object["uuid"] as? String, validID(id) else { return }
        sawSessionNode = true
        let compact = type == "system" && object["subtype"] as? String == "compact_boundary"
        let metadata = object["compactMetadata"] as? [String: Any]
        let preserved = metadata?["preservedSegment"] as? [String: Any]
        let physicalParent = object["parentUuid"] as? String
        let physicalRoot = object["parentUuid"] == nil || object["parentUuid"] is NSNull
        let parent = physicalParent ?? (compact ? object["logicalParentUuid"] as? String ?? preserved?["tailUuid"] as? String : nil)
        let message = object["message"] as? [String: Any] ?? [:]
        let content = blocks(message["content"])
        let origin = object["origin"] as? [String: Any]
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        let notification = object["isCompactSummary"] as? Bool != true &&
            (origin?["kind"] as? String == "task-notification" ||
             (object["promptSource"] as? String == "system" && origin?["kind"] as? String != "plugin" &&
              text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<task-notification>")))
        let human = type == "user" && !notification && object["promptSource"] as? String != "system" && object["isMeta"] as? Bool != true &&
            object["isCompactSummary"] as? Bool != true && origin?["kind"] as? String != "plugin" &&
            !content.contains { $0["type"] as? String == "tool_result" } && !text.isEmpty
        let stopReason = message["stop_reason"] as? String
        let toolUses = content.compactMap { $0["type"] as? String == "tool_use" ? $0["id"] as? String : nil }
        let toolResults = content.compactMap { $0["type"] as? String == "tool_result" ? $0["tool_use_id"] as? String : nil }
        let pureResult = !toolResults.isEmpty && content.allSatisfy { $0["type"] as? String == "tool_result" }
        let safeFollowup = (type == "user" && (notification || pureResult)) || type == "attachment" ||
            (type == "system" && object["subtype"] as? String == "stop_hook_summary")
        let errorKind = object["apiError"] as? String ?? object["error"] as? String
        let interrupted = type == "assistant" && (object["isApiErrorMessage"] as? Bool == true ||
            ["rate_limit", "rate_limit_error", "api_error", "overloaded_error", "interrupted"].contains(errorKind ?? "") ||
            stopReason == "max_tokens" || ["You've hit your limit", "You've hit your session limit", "You've hit your usage limit"].contains { text.hasPrefix($0) })
        var events: [Event] = []
        for block in content {
            switch block["type"] as? String {
            case "tool_use":
                guard let toolID = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                let kind: NativeWorkKind? = name == "Bash" ? .bash : name == "Monitor" ? .monitor : ["Agent", "Task"].contains(name) ? .agent : nil
                guard kind != nil || ["TaskStop", "TaskOutput", "GetTask", "Artifact", "ArtifactComments", "SendMessage"].contains(name) else { continue }
                let agentMessage = name == "SendMessage" && (input["type"] as? String).map { $0 == "message" } != false
                let action = input["action"] as? String
                let monitorInput = name == "Monitor" && toolID == monitorToolUseID
                    ? try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) : nil
                events.append(.call(Call(id: toolID, name: name, kind: kind,
                    background: name == "Monitor" || input["run_in_background"] as? Bool == true,
                    targetID: input["task_id"] as? String ?? input["taskId"] as? String ?? input["agent_id"] as? String ??
                        (agentMessage ? input["to"] as? String ?? input["recipient"] as? String : nil),
                    description: short(input["description"] as? String), agentType: short(input["subagent_type"] as? String),
                    artifactURL: artifactURL(input["url"] as? String),
                    artifactStopped: ["Artifact", "ArtifactComments"].contains(name) &&
                        (action == "unwatch" || (action == "watch" && input["on"] as? Bool == false)),
                    artifactStarted: ["Artifact", "ArtifactComments"].contains(name) && ["watch", "resume_replies"].contains(action ?? "") &&
                        input["url"] as? String != nil && input["on"] as? Bool != false,
                    artifactReplies: input["replies"] as? Bool,
                    monitorInput: monitorInput.flatMap { $0.count <= 262_144 ? $0 : nil })))
            case "tool_result":
                guard let toolID = block["tool_use_id"] as? String else { continue }
                let value = object["toolUseResult"] as? [String: Any] ?? [:]
                let legacyTask = value["task"] as? [String: Any] ?? [:]
                let watch = value["watch"] as? [String: Any] ?? [:]
                let resumed = value["resume_replies"] as? [String: Any] ?? [:]
                events.append(.result(Result(toolID: toolID,
                    nativeID: value["backgroundTaskId"] as? String ?? value["taskId"] as? String ?? value["task_id"] as? String,
                    agentID: value["agentId"] as? String ?? value["agent_id"] as? String,
                    status: value["status"] as? String ?? legacyTask["status"] as? String, isAsync: value["isAsync"] as? Bool == true,
                    error: block["is_error"] as? Bool == true || value["is_error"] as? Bool == true,
                    interrupted: value["interrupted"] as? Bool == true,
                    outputPath: path(value["backgroundOutputPath"] as? String ?? value["persistedOutputPath"] as? String ?? value["outputFile"] as? String ?? value["output_file"] as? String),
                    stopTarget: value["task_id"] as? String,
                    artifactID: value["artifact_id"] as? String,
                    artifactURL: artifactURL(value["url"] as? String ?? watch["url"] as? String ?? resumed["url"] as? String),
                    artifactWatching: watch["watching"] as? Bool ?? resumed["resumed"] as? Bool,
                    artifactReplies: resumed["resumed"] as? Bool ?? (watch["auto_reply"] as? String).map { $0 == "armed" },
                    resumedAgentID: value["success"] as? Bool == true ? value["resumedAgentId"] as? String : nil)))
            default: break
            }
        }
        if type == "user", notification, let notice = nativeTaskNotice(text) {
            let rawStatus = notice.status
            let state: NativeWorkState?
            if rawStatus == "stopped" && (text.contains("previous session ended") || text.contains("No completion record")) { state = .interrupted }
            else { state = taskState(rawStatus) }
            if let state {
                let kind: NativeWorkKind? = text.contains("Background agent") ? .agent : text.contains("shell command") ? .bash : nil
                events.append(.notification(ids: [notice.id], toolID: notice.toolID, state: state, kind: kind))
            }
        }
        if type == "attachment", let attachment = object["attachment"] as? [String: Any],
           attachment["type"] as? String == "task_status", let taskID = attachment["taskId"] as? String, validID(taskID),
           let state = taskState(attachment["status"] as? String) {
            let kind: NativeWorkKind = (attachment["taskType"] as? String ?? "").contains("agent") ? .agent : .bash
            events.append(.status(id: taskID, kind: kind, state: state, output: path(attachment["outputFilePath"] as? String)))
        }
        // Current Desktop delivers a completion that arrives during a turn as a queued
        // attachment, rather than another user row. Read only the host task envelope;
        // rendered text, ordinary queued prompts and tool output are not task evidence.
        if type == "attachment", let attachment = object["attachment"] as? [String: Any],
           attachment["type"] as? String == "queued_command",
           attachment["commandMode"] as? String == "task-notification",
           (attachment["origin"] as? [String: Any])?["kind"] as? String == "task-notification",
           let prompt = attachment["prompt"] as? String, let notice = nativeTaskNotice(prompt),
           let state = taskState(notice.status) {
            let interrupted = state == .stopped && (prompt.contains("previous session ended") || prompt.contains("No completion record"))
            events.append(.notification(ids: [notice.id], toolID: notice.toolID,
                                        state: interrupted ? .interrupted : state, kind: nil))
        }
        rows[id] = Row(id: id, parent: parent, line: line, type: type, timestamp: object["timestamp"] as? String,
                       physicalParent: physicalParent, physicalRoot: physicalRoot,
                       preserved: compact ? PreservedSegment(preserved) : nil,
                       compactSummary: type == "user" && object["isCompactSummary"] as? Bool == true,
                       human: human, interrupted: interrupted, stopReason: stopReason, compact: compact,
                       safeFollowup: safeFollowup, toolUses: toolUses, toolResults: toolResults, events: events)
        lastID = id
    }

    /// Compaction can append rewritten rows with the same UUIDs, attaching its preserved
    /// segment below the new summary. In that layout logicalParentUuid still names the old
    /// tail, which is now a descendant: using it as a parent would manufacture a cycle.
    /// Suppress that back-edge only when the latest physical rows prove the complete layout.
    private func resolvedCompactionParents() -> [String: Row] {
        var resolved = rows
        for boundary in rows.values where boundary.compact && boundary.physicalRoot {
            guard let segment = boundary.preserved, boundary.parent == segment.tail,
                  segment.head != boundary.id, segment.anchor != boundary.id, segment.tail != boundary.id,
                  rows[segment.head]?.physicalParent == segment.anchor,
                  attached(rows[segment.anchor]?.physicalParent, to: boundary.id),
                  rows[segment.anchor]?.compactSummary == true else { continue }
            var cursor: String? = segment.tail, seen = Set<String>()
            while let id = cursor, seen.insert(id).inserted, let row = rows[id] {
                if id == segment.head {
                    resolved[boundary.id]?.parent = nil
                    break
                }
                // The preserved tail must reach its head before the summary or boundary.
                if id == segment.anchor || id == boundary.id { break }
                cursor = row.physicalParent
            }
        }
        return resolved
    }

    /// The summary hangs under its boundary, directly or below the attachments compaction adds first.
    private func attached(_ start: String?, to boundary: String) -> Bool {
        var cursor = start, seen = Set<String>()
        while let id = cursor, seen.insert(id).inserted {
            if id == boundary { return true }
            guard let row = rows[id], row.type == "attachment" else { return false }
            cursor = row.physicalParent
        }
        return false
    }

    func snapshot(desktopSessionID: String, cliSessionID: String, cwd: String, sourceProfile: String,
                  sourceAccountID: String, transcript: URL, size: Int64, preferredHead: String?,
                  published: [NativeArtifactReference], now: Date) -> NativeWorkSnapshot {
        let rows = resolvedCompactionParents()
        var warnings: [String] = malformed ? ["malformedTranscriptLine"] : []
        var head: String?, headSource: String
        if let preferredHead, rows[preferredHead] != nil { head = preferredHead; headSource = "desktopRecord" }
        else { head = lastID; headSource = "transcriptTail"; warnings.append(preferredHead == nil ? "headInferred" : "desktopHeadMissing") }
        var extensionAmbiguous = false
        let children = Dictionary(grouping: rows.values.filter { $0.parent != nil }, by: { $0.parent! })
        if headSource == "desktopRecord", let anchor = head {
            // Desktop saves an assistant anchor. Its matching tool results and asynchronous
            // notifications can follow it without updating that field. Never step across a
            // new conversational turn or choose one arm of a fork on the user's behalf.
            var knownTools = Set<String>(), ancestor: String? = anchor, ancestry = Set<String>()
            while let id = ancestor, ancestry.insert(id).inserted, let row = rows[id] {
                knownTools.formUnion(row.toolUses); ancestor = row.parent
            }
            var followed = Set<String>([anchor])
            while let id = head {
                let next = children[id] ?? []
                if next.count > 1 {
                    if next.contains(where: \.safeFollowup) { extensionAmbiguous = true; warnings.append("ambiguousNativeFollowup") }
                    break
                }
                guard let row = next.first, row.safeFollowup,
                      row.toolResults.allSatisfy({ knownTools.contains($0) }), followed.insert(row.id).inserted else { break }
                head = row.id; headSource = "desktopRecordWithNativeResults"
            }
        }
        var selected: [Row] = [], seen = Set<String>(), cursor = head
        var complete = !malformed && !extensionAmbiguous && (preferredHead == nil || rows[preferredHead!] != nil)
        while let id = cursor {
            guard seen.insert(id).inserted else { complete = false; warnings.append("parentCycle"); break }
            guard let row = rows[id] else { complete = false; warnings.append("missingParent"); break }
            selected.append(row); cursor = row.parent
        }
        selected.reverse()
        // A step that calls several tools records each result under its own call, so only the last
        // result lies on the path to the head. The others hang off their calls: read them right after.
        let path = Set(selected.map(\.id))
        selected = selected.flatMap { row in
            [row] + (children[row.id] ?? []).filter { child in
                !path.contains(child.id) && child.safeFollowup && !child.toolResults.isEmpty &&
                    child.toolResults.allSatisfy(row.toolUses.contains)
            }.sorted { $0.line < $1.line }
        }
        if selected.isEmpty { complete = false; warnings.append("emptyBranch") }
        var builder = NativeWorkBuilder(artifacts: published)
        var latestUser: NativeWorkPointer?, latestAssistant: NativeWorkPointer?, interrupted = false, stopReason: String?
        for row in selected {
            if row.human { latestUser = row.pointer }
            if row.type == "assistant" { latestAssistant = row.pointer; interrupted = row.interrupted; stopReason = row.stopReason }
            for event in row.events { builder.apply(event, line: row.line, timestamp: row.timestamp) }
        }
        for state in artifactStates {
            builder.artifact(id: state.id, url: nil, state: state.state, line: state.line,
                time: state.writtenAt, replies: state.state == "armed")
        }
        if !artifactStates.isEmpty { warnings.append("artifactStateIsPersistedNotLive") }
        if builder.finalTasks.contains(where: { $0.state.needsInspection }) { warnings.append("pendingStateIsNotRuntimeLiveness") }
        return NativeWorkSnapshot(desktopSessionID: desktopSessionID, cliSessionID: cliSessionID, cwd: cwd,
            capturedAt: now.timeIntervalSince1970 * 1000, sourceProfile: sourceProfile, sourceAccountID: sourceAccountID,
            transcriptPath: transcript.path, transcriptSize: size, headUUID: head, headSource: headSource,
            branchComplete: complete, warnings: Array(Set(warnings)).sorted(), latestUser: latestUser,
            latestAssistant: latestAssistant, latestAssistantInterrupted: interrupted, latestAssistantStopReason: stopReason,
            tasks: builder.finalTasks, artifacts: builder.artifacts,
            ancestorSessionIDs: ancestorSessionIDs.isEmpty ? nil : ancestorSessionIDs.sorted())
    }
}

private struct NativeWorkBuilder {
    var calls: [String: NativeTranscriptFacts.Call] = [:]
    var tasks: [String: NativeWorkTask] = [:]
    var nativeIDs: [String: String] = [:]
    var background = Set<String>()
    var terminal = Set<String>()
    var artifacts: [NativeArtifactReference]
    var artifactTimes: [String: Double] = [:]
    // Only an armed reply or a stop changes intent. A plain-watch receipt with no replies
    // must not erase it, even when older native telemetry is applied after branch messages.
    var artifactReplyIntents: [String: (enabled: Bool, time: Double, line: Int)] = [:]

    var finalTasks: [NativeWorkTask] {
        tasks.values.filter { background.contains($0.toolUseID) || $0.kind != .bash || $0.state.needsInspection || $0.state == .stopped || $0.toolUseID.isEmpty }
            .sorted { $0.sourceLine == $1.sourceLine ? $0.id < $1.id : $0.sourceLine < $1.sourceLine }
    }

    mutating func apply(_ event: NativeTranscriptFacts.Event, line: Int, timestamp: String?) {
        switch event {
        case .call(let call):
            calls[call.id] = call
            if let kind = call.kind {
                tasks[call.id] = NativeWorkTask(id: call.id, toolUseID: call.id, kind: kind, state: .requested,
                    description: call.description, agentType: call.agentType, sourceLine: line)
                if call.background { background.insert(call.id) }
            }
            if call.artifactStopped { artifact(id: nil, url: call.artifactURL, state: "stopped", line: line, time: milliseconds(timestamp)) }
        case .result(let result):
            guard let call = calls[result.toolID] else { return }
            if call.name == "SendMessage", !result.error,
               let id = result.resumedAgentID, id == call.targetID,
               let key = nativeIDs[id], tasks[key]?.kind == .agent {
                // A real native revival starts a new execution of this same Agent. An old
                // terminal result must not suppress its later completion notification.
                terminal.remove(key)
                tasks[key]?.state = .backgroundRegistered; tasks[key]?.resultLine = line
                tasks[key]?.explicitlyStopped = nil
                return
            }
            if ["Artifact", "ArtifactComments"].contains(call.name) {
                artifact(id: result.artifactID, url: result.artifactURL ?? call.artifactURL,
                         state: call.artifactStopped ? "stopped" : call.artifactStarted && !result.error && result.artifactWatching != false ? "armed" : nil,
                         line: line, time: milliseconds(timestamp), replies: result.artifactReplies ?? call.artifactReplies); return
            }
            if call.name == "TaskStop", !result.error, let id = result.stopTarget ?? call.targetID {
                update(id: id, toolID: nil, state: .stopped, kind: nil, line: line)
                if let key = nativeIDs[id] { tasks[key]?.explicitlyStopped = true }
                return
            }
            if ["TaskOutput", "GetTask"].contains(call.name), let id = call.targetID, let state = taskState(result.status) {
                update(id: id, toolID: nil, state: state, kind: nil, line: line); return
            }
            guard var task = tasks[call.id] else { return }
            let nativeID = result.nativeID ?? (call.kind == .agent ? result.agentID : nil)
            if let nativeID, validID(nativeID) {
                task.id = nativeID; nativeIDs[nativeID] = call.id; background.insert(call.id)
            }
            task.resultLine = line; task.outputPath = result.outputPath
            if !terminal.contains(call.id) {
                if result.error { task.state = .failed }
                else if let state = taskState(result.status), state != .backgroundRegistered { task.state = state }
                else if nativeID != nil || result.isAsync { task.state = .backgroundRegistered }
                else if result.interrupted { task.state = .stopped }
                else if call.background { task.state = .unknown }
                else { task.state = .completed }
            }
            tasks[call.id] = task
            if [.completed, .failed, .stopped].contains(task.state) { terminal.insert(call.id) }
        case .notification(let ids, let toolID, let state, let kind):
            if ids.isEmpty, let toolID, let task = tasks[toolID] { update(id: task.id, toolID: toolID, state: state, kind: kind, line: line) }
            for id in ids { update(id: id, toolID: toolID, state: state, kind: kind, line: line) }
        case .status(let id, let kind, let state, let output):
            update(id: id, toolID: nil, state: state, kind: kind, line: line)
            if let key = nativeIDs[id], let output { tasks[key]?.outputPath = output }
        }
    }

    private mutating func update(id: String, toolID: String?, state: NativeWorkState, kind: NativeWorkKind?, line: Int) {
        guard validID(id) else { return }
        let key = nativeIDs[id] ?? toolID.flatMap { tasks[$0] == nil ? nil : $0 } ?? "native:" + id
        if tasks[key] == nil {
            guard let kind = kind ?? (state == .stopped ? .bash : nil) else { return }
            tasks[key] = NativeWorkTask(id: id, toolUseID: toolID ?? "", kind: kind, state: state, sourceLine: line)
        }
        nativeIDs[id] = key
        guard !terminal.contains(key) else { return }
        tasks[key]?.id = id; tasks[key]?.state = state; tasks[key]?.resultLine = line
        if [.completed, .failed, .stopped].contains(state) { terminal.insert(key) }
    }

    mutating func artifact(id: String?, url: String?, state: String?, line: Int, time: Double, replies: Bool? = nil) {
        guard id != nil || url != nil else { return }
        let inferredID = url.flatMap { URL(string: $0)?.lastPathComponent }
        let index = artifacts.firstIndex { (id != nil && $0.id == id) || (url != nil && $0.url == url) ||
            (id != nil && $0.url.flatMap { URL(string: $0)?.lastPathComponent } == id) || (inferredID != nil && $0.id == inferredID) }
        let key = id ?? url!
        if let index {
            let oldKey = artifacts[index].id ?? artifacts[index].url ?? key
            let previousTime = artifactTimes[oldKey] ?? 0
            if let id { artifacts[index].id = id }
            if let url { artifacts[index].url = url }
            let newKey = artifacts[index].id ?? artifacts[index].url ?? key
            if let intent = artifactReplyIntents.removeValue(forKey: oldKey) { artifactReplyIntents[newKey] = intent }
            artifactTimes[newKey] = previousTime
            if let state, time >= previousTime {
                artifacts[index].state = state; artifacts[index].sourceLine = line; artifactTimes[newKey] = time
            }
            artifacts[index].replies = replyIntent(key: newKey, state: state, replies: replies, time: time, line: line)
                ?? artifacts[index].replies ?? replies
        } else {
            // The native monitor's slug is authoritative even when compaction removed publish.
            let originalURL = url ?? id.map { "https://claude.ai/code/artifact/" + $0 }
            let intent = replyIntent(key: key, state: state, replies: replies, time: time, line: line)
            artifacts.append(NativeArtifactReference(id: id, url: originalURL, state: state, sourceLine: line, replies: intent ?? replies)); artifactTimes[key] = time
        }
    }

    private mutating func replyIntent(key: String, state: String?, replies: Bool?, time: Double, line: Int) -> Bool? {
        if state == "stopped" || (state == "armed" && replies == true) {
            let old = artifactReplyIntents[key]
            if old == nil || time > old!.time || (time == old!.time && line >= old!.line) {
                artifactReplyIntents[key] = (state != "stopped", time, line)
            }
        }
        return artifactReplyIntents[key]?.enabled
    }
}

private func captureReadFailure(_ code: Int32) -> NativeWorkCaptureFailure {
    code == EACCES || code == EPERM ? .permissionDenied : .unreadable
}
private func validID(_ value: String) -> Bool {
    (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
    }
}
private func blocks(_ value: Any?) -> [[String: Any]] {
    if let text = value as? String { return [["type": "text", "text": text]] }
    return value as? [[String: Any]] ?? []
}
private func taskState(_ value: String?) -> NativeWorkState? {
    switch value {
    case "completed", "complete", "succeeded": return .completed
    case "failed", "error": return .failed
    case "stopped", "cancelled", "killed": return .stopped
    case "running", "in_progress", "working", "async_launched", "remote_launched": return .backgroundRegistered
    case "interrupted": return .interrupted
    default: return nil
    }
}
/// Task output can contain XML-looking notifications. Only the outer host envelope is evidence.
private func nativeTaskNotice(_ text: String) -> (id: String, toolID: String?, status: String?)? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "<task-notification>"
    guard trimmed.hasPrefix(prefix),
          let expression = try? NSRegularExpression(pattern: "^<([a-z-]+)>([^<>]*)</\\1>\\s*") else { return nil }
    var rest = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    var id: String?, toolID: String?, status: String?
    for _ in 0..<8 {
        if ["<summary>", "<result>", "<output>", "<event>", "</task-notification>"].contains(where: { rest.hasPrefix($0) }) {
            guard let id else { return nil }
            return (id, toolID, status)
        }
        let string = rest as NSString
        guard let match = expression.firstMatch(in: rest, range: NSRange(location: 0, length: string.length)) else { return nil }
        let name = string.substring(with: match.range(at: 1))
        let value = string.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "task-id":
            guard id == nil, validID(value) else { return nil }; id = value
        case "tool-use-id":
            guard toolID == nil, validID(value) else { return nil }; toolID = value
        case "status":
            guard status == nil else { return nil }; status = value
        case "output-file": break
        default: return nil
        }
        rest = string.substring(from: match.range.length)
    }
    return nil
}
private func short(_ value: String?) -> String? { value.map { String($0.prefix(240)) } }
private func path(_ value: String?) -> String? {
    guard let value, value.hasPrefix("/"), value.utf8.count <= 4096, !value.contains("\0") else { return nil }
    return value
}
private func artifactURL(_ value: String?) -> String? {
    guard let value, var url = URLComponents(string: value), url.scheme == "https", url.host == "claude.ai",
          url.user == nil, url.password == nil, url.path.contains("/artifact/") else { return nil }
    url.query = nil; url.fragment = nil
    return url.string
}
private func milliseconds(_ value: String?) -> Double {
    guard let value else { return 0 }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date.timeIntervalSince1970 * 1000 }
    formatter.formatOptions = [.withInternetDateTime]
    return (formatter.date(from: value)?.timeIntervalSince1970 ?? 0) * 1000
}
