import Darwin
import Foundation

public enum ContinuityFailure: Error, Equatable, Sendable {
    case identityUnavailable, identityChanged, invalidRecord, missingRecord, sessionMismatch
    case archived, projectMissing, transcriptUnavailable, invalidCLIIdentifier
    case transcriptMissing, transcriptUnreadable, transcriptLineTooLong
    case unreadable
}

public struct ContinuityRecord: Equatable, Sendable {
    public var sessionID: String
    public var cliSessionID: String
    public var cwd: String
    public var worktreePath: String?
    public var lastFocusedAt: Int64
    public var lastActivityAt: Int64
    public var isArchived: Bool
    public var transcriptUnavailable: Bool
    public var title: String?

    public init(sessionID: String, cliSessionID: String, cwd: String, worktreePath: String? = nil,
                lastFocusedAt: Int64, lastActivityAt: Int64, isArchived: Bool = false,
                transcriptUnavailable: Bool = false, title: String? = nil) {
        self.sessionID = sessionID
        self.cliSessionID = cliSessionID
        self.cwd = cwd
        self.worktreePath = worktreePath
        self.lastFocusedAt = lastFocusedAt
        self.lastActivityAt = lastActivityAt
        self.isArchived = isArchived
        self.transcriptUnavailable = transcriptUnavailable
        self.title = title
    }
}

public struct ContinuityCapture: Equatable, Sendable {
    public let record: ContinuityRecord
    public let sourceIdentity: AccountIdentity
}

public struct ContinuityTarget: Equatable, Sendable {
    /// The validated pre-launch record supplies the focus baseline for confirmation.
    public let record: ContinuityRecord
    public let identity: AccountIdentity
}

public struct ContinuityInspector: Sendable {
    public static let transcriptStartBuffer = 64 * 1024
    public static let maximumTranscriptLine = 16 * 1024 * 1024
    private let cliHome: URL
    private let io: SessionFileIO

    public init(paths: AppPaths) { self.init(paths: paths, io: SessionFileIO()) }

    init(paths: AppPaths, io: SessionFileIO) {
        cliHome = paths.claudeCLIHome
        self.io = io
    }

    public func capture(profile: ProfileSnapshot) throws(ContinuityFailure) -> ContinuityCapture? {
        try handlingFiles {
            let (identity, bucket) = try readable(profile)
            try io.checkPath(bucket, under: profile.url)
            guard try io.info(bucket) != nil else { return nil }
            var records: [ContinuityRecord] = []
            for file in try io.list(bucket) where SessionFileIO.isSession(file.lastPathComponent) {
                records.append(try readRecord(at: file))
            }
            records.sort {
                if $0.lastFocusedAt != $1.lastFocusedAt { return $0.lastFocusedAt > $1.lastFocusedAt }
                if $0.lastActivityAt != $1.lastActivityAt { return $0.lastActivityAt > $1.lastActivityAt }
                return $0.sessionID < $1.sessionID
            }
            return records.first.map { ContinuityCapture(record: $0, sourceIdentity: identity) }
        }
    }

    public func validateTarget(_ capture: ContinuityCapture, profile: ProfileSnapshot,
                               expectedIdentity: AccountIdentity) throws(ContinuityFailure) -> ContinuityTarget {
        try handlingFiles {
            let (identity, bucket) = try readable(profile)
            guard identity.accountUUID == expectedIdentity.accountUUID,
                  identity.activeOrganizationUUID == expectedIdentity.activeOrganizationUUID else {
                throw ContinuityFailure.identityChanged
            }
            let file = bucket.appending(path: capture.record.sessionID + ".json")
            try io.checkPath(file, under: profile.url)
            guard try io.info(file) != nil else { throw ContinuityFailure.missingRecord }
            let record = try readRecord(at: file)
            guard record.sessionID == capture.record.sessionID, record.cliSessionID == capture.record.cliSessionID else {
                throw ContinuityFailure.sessionMismatch
            }
            guard !record.isArchived else { throw ContinuityFailure.archived }
            let path = record.worktreePath.flatMap { $0.isEmpty ? nil : $0 } ?? record.cwd
            var directory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &directory),
                  directory.boolValue else { throw ContinuityFailure.projectMissing }
            guard !record.transcriptUnavailable else { throw ContinuityFailure.transcriptUnavailable }
            guard Self.validID(record.cliSessionID) else { throw ContinuityFailure.invalidCLIIdentifier }
            try validateTranscript(record.cliSessionID)
            return ContinuityTarget(record: record, identity: identity)
        }
    }

    public func readRecord(at file: URL) throws(ContinuityFailure) -> ContinuityRecord {
        let data = try handlingFiles {
            var root = file.deletingLastPathComponent()
            var ancestor = root
            while ancestor.path != "/" {
                if ancestor.lastPathComponent == "claude-code-sessions" {
                    root = ancestor.deletingLastPathComponent()
                    break
                }
                ancestor = ancestor.deletingLastPathComponent()
            }
            try io.checkPath(file, under: root)
            return try io.read(file)
        }
        do {
            let object = try SessionJSON.object(data, at: file).filter { !($0.value is NSNull) }
            let id = file.deletingPathExtension().lastPathComponent
            guard id.hasPrefix("local_"), Self.validID(String(id.dropFirst(6))),
                  object["sessionId"] as? String == id else { throw ContinuityFailure.invalidRecord }
            func integer(_ key: String) throws -> Int64 {
                guard let value = object[key] else { return 0 }
                guard let number = SessionJSON.integer(value) else { throw ContinuityFailure.invalidRecord }
                return number
            }
            func boolean(_ key: String) throws -> Bool {
                guard let value = object[key] else { return false }
                guard let flag = SessionJSON.boolean(value) else { throw ContinuityFailure.invalidRecord }
                return flag
            }
            for key in ["cliSessionId", "cwd", "worktreePath"] {
                if let value = object[key], !(value is String) { throw ContinuityFailure.invalidRecord }
            }
            return ContinuityRecord(sessionID: id, cliSessionID: object["cliSessionId"] as? String ?? "",
                cwd: object["cwd"] as? String ?? "", worktreePath: object["worktreePath"] as? String,
                lastFocusedAt: try integer("lastFocusedAt"), lastActivityAt: try integer("lastActivityAt"),
                isArchived: try boolean("isArchived"), transcriptUnavailable: try boolean("transcriptUnavailable"),
                title: (object["title"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(200)) })
        } catch { throw ContinuityFailure.invalidRecord }
    }

    /// Desktop's continue link opens history without necessarily starting its CLI. A prepared
    /// handoff uses Desktop's own quit-resume marker to start that CLI; the plugin still waits
    /// for an independently verified runtime before it can claim or execute the handoff.
    /// Returns the record as it was, for `restoreNativeRecoveryLaunch`.
    @discardableResult
    func prepareNativeRecoveryLaunch(sessionID: String, cliSessionID: String,
                                     profile: ProfileSnapshot, at now: Date) throws -> Data {
        guard sessionID.hasPrefix("local_"), Self.validID(String(sessionID.dropFirst(6))),
              Self.validID(cliSessionID) else { throw ContinuityFailure.invalidRecord }
        let (identity, bucket) = try readable(profile)
        let file = bucket.appending(path: sessionID + ".json")
        let record = try readRecord(at: file)
        guard record.sessionID == sessionID, record.cliSessionID == cliSessionID else {
            throw ContinuityFailure.sessionMismatch
        }
        _ = try validateTarget(ContinuityCapture(record: record, sourceIdentity: identity),
                               profile: profile, expectedIdentity: identity)
        let original = try io.read(file)
        var object = try SessionJSON.object(original, at: file)
        // A pending permission/dialog or an explicit stop still requires the person. Waking a
        // recovery runtime must never dismiss those native holds or change permission mode.
        guard SessionJSON.boolean(object["stoppedUntilPersonSends"]) != true,
              SessionJSON.boolean(object["interruptedAwaitingPerson"]) != true else {
            throw ContinuityFailure.invalidRecord
        }
        object["interruptedByQuitAt"] = Int64(now.timeIntervalSince1970 * 1_000)
        // The field must be present: Desktop treats an absent field on a marked record as an
        // older interruption that requires the person, and will not warm its CLI at launch.
        object["interruptedAwaitingPerson"] = false
        object.removeValue(forKey: "interruptedUnseenResume")
        try io.checkPath(file, under: profile.url)
        try AtomicFile.write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: file)
        return original
    }

    /// Puts a record `prepareNativeRecoveryLaunch` marked back as it was.
    func restoreNativeRecoveryLaunch(sessionID: String, profile: ProfileSnapshot, original: Data) throws {
        guard sessionID.hasPrefix("local_"), Self.validID(String(sessionID.dropFirst(6))) else { throw ContinuityFailure.invalidRecord }
        let (_, bucket) = try readable(profile)
        let file = bucket.appending(path: sessionID + ".json")
        try io.checkPath(file, under: profile.url)
        try AtomicFile.write(original, to: file)
    }

    private func handlingFiles<T>(_ body: () throws -> T) throws(ContinuityFailure) -> T {
        do { return try body() }
        catch let failure as ContinuityFailure { throw failure }
        catch { throw .unreadable }
    }

    public static func isConfirmed(current: ContinuityRecord?, captured: ContinuityTarget,
                                   launchThreshold: Int64, targetRunningWithUnchangedIdentity: Bool) -> Bool {
        guard targetRunningWithUnchangedIdentity, let current else { return false }
        return current.sessionID == captured.record.sessionID && current.cliSessionID == captured.record.cliSessionID &&
            !current.isArchived && current.lastFocusedAt != captured.record.lastFocusedAt &&
            current.lastFocusedAt >= launchThreshold
    }

    private func readable(_ profile: ProfileSnapshot) throws -> (AccountIdentity, URL) {
        guard case .signedIn(let identity) = profile.status, let org = identity.activeOrganizationUUID,
              let bucket = try? SessionBucket(accountUUID: identity.accountUUID, organizationUUID: org) else {
            throw ContinuityFailure.identityUnavailable
        }
        return (identity, profile.url.appending(path: bucket.relativePath))
    }

    private static func validID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        }
    }

    private func validateTranscript(_ id: String) throws {
        let projects = cliHome.appending(path: "projects").resolvingSymlinksInPath()
        guard try io.info(projects) != nil else { throw ContinuityFailure.transcriptMissing }
        var failure = ContinuityFailure.transcriptMissing
        for project in try io.list(projects) {
            do {
                let resolved = project.resolvingSymlinksInPath()
                guard let info = try io.info(resolved), io.isDirectory(info) else { continue }
                let transcript = resolved.appending(path: id + ".jsonl").resolvingSymlinksInPath()
                guard try io.info(transcript) != nil else { continue }
                if try hasTranscriptRow(transcript, id: id) { return }
            }
            catch let error as ContinuityFailure { failure = error }
            catch { failure = .transcriptUnreadable }
        }
        throw failure
    }

    private func hasTranscriptRow(_ file: URL, id: String) throws -> Bool {
        guard let metadata = try io.info(file), io.isRegular(metadata) else { throw ContinuityFailure.transcriptUnreadable }
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ContinuityFailure.transcriptUnreadable }
        defer { _ = close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, io.isRegular(opened) else { throw ContinuityFailure.transcriptUnreadable }
        var pending = Data()
        pending.reserveCapacity(Self.transcriptStartBuffer)
        var buffer = [UInt8](repeating: 0, count: Self.transcriptStartBuffer)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return matches(pending, id: id) }
            if count < 0 {
                if errno == EINTR { continue }
                throw ContinuityFailure.transcriptUnreadable
            }
            let pieces = buffer[..<count].split(separator: 10, omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                guard pending.count + piece.count <= Self.maximumTranscriptLine else { throw ContinuityFailure.transcriptLineTooLong }
                pending.append(contentsOf: piece)
                if index < pieces.count - 1 {
                    if matches(pending, id: id) { return true }
                    pending.removeAll(keepingCapacity: true)
                }
            }
        }
    }

    private func matches(_ line: Data, id: String) -> Bool {
        guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              row["sessionId"] as? String == id, let type = row["type"] as? String else { return false }
        return type == "user" || type == "assistant"
    }
}
