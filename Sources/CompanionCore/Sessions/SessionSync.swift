import Foundation

public struct SyncPlan: Sendable {
    public let source: ProfileSnapshot
    public let target: ProfileSnapshot
    public let sourceIdentity: AccountIdentity
    public let targetIdentity: AccountIdentity

    public init(source: ProfileSnapshot, target: ProfileSnapshot) throws {
        guard source.url.standardizedFileURL.resolvingSymlinksInPath().path != target.url.standardizedFileURL.resolvingSymlinksInPath().path,
              case .signedIn(let a) = source.status, case .signedIn(let b) = target.status,
              !a.accountUUID.isEmpty, !b.accountUUID.isEmpty else { throw SessionDataError.invalidPlan }
        _ = try ProfileFolder(a.accountUUID)
        _ = try ProfileFolder(b.accountUUID)
        if let org = a.activeOrganizationUUID { _ = try ProfileFolder(org) }
        if let org = b.activeOrganizationUUID { _ = try ProfileFolder(org) }
        self.source = source
        self.target = target
        sourceIdentity = a
        targetIdentity = b
    }
}

public enum SyncWarning: Equatable, Sendable { case unknownOrganization, missingActiveOrganizationBucket }
public struct SyncIssue: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case file, traversal, archiveIndex }
    public let path: URL
    public let kind: Kind
}
public struct SyncReport: Equatable, Sendable {
    public var copied: [URL] = []
    public var replaced: [URL] = []
    public var skipped: [URL] = []
    public var conflicts: [URL] = []
    public var errors: [SyncIssue] = []
    public var warnings: [SyncWarning] = []
    public var aborted = false
    public var touchedBuckets: [URL] = []
}
public struct TwoWaySyncReport: Equatable, Sendable {
    public let forward: SyncReport
    public let reverse: SyncReport
    public let unresolved: [String]
}

public struct SessionSync: Sendable {
    private let io: SessionFileIO
    public init() { io = SessionFileIO() }
    init(io: SessionFileIO) { self.io = io }

    public func sync(_ plan: SyncPlan) -> SyncReport {
        var report = SyncReport()
        let sourceRoot = plan.source.url.appending(path: "claude-code-sessions/" + plan.sourceIdentity.accountUUID)
        let targetRoot = plan.target.url.appending(path: "claude-code-sessions/" + plan.targetIdentity.accountUUID)
        let sourceOrg = plan.sourceIdentity.activeOrganizationUUID
        let targetOrg = plan.targetIdentity.activeOrganizationUUID
        var rehome = false
        var files: [URL] = []
        do {
            try io.checkPath(sourceRoot, under: plan.source.url)
            try io.checkPath(targetRoot, under: plan.target.url)
            if sourceOrg == nil || targetOrg == nil { report.warnings.append(.unknownOrganization) }
            if let sourceOrg, let targetOrg, sourceOrg != targetOrg {
                if let value = try io.info(sourceRoot.appending(path: sourceOrg)), io.isDirectory(value) { rehome = true }
                else { report.warnings.append(.missingActiveOrganizationBucket) }
            }
            if try io.info(sourceRoot) != nil { try gather(sourceRoot, into: &files, issues: &report.errors) }
        } catch {
            report.errors.append(SyncIssue(path: sourceRoot, kind: .traversal))
            report.aborted = true
            return report
        }
        var touched = Set<URL>()
        for source in files {
            let relative = String(source.path.dropFirst(sourceRoot.path.count + 1))
            var components = relative.split(separator: "/").map(String.init)
            if rehome && components.count > 1 {
                if components[0] == targetOrg { report.skipped.append(source); continue }
                if components[0] == sourceOrg { components[0] = targetOrg! }
            }
            let target = components.reduce(targetRoot) { $0.appending(path: $1) }
            do {
                try io.checkPath(target, under: plan.target.url)
                try io.makeDirectory(target.deletingLastPathComponent())
                touched.insert(target.deletingLastPathComponent())
                let stem = source.deletingPathExtension().lastPathComponent
                let deletion = target.deletingLastPathComponent().appending(path: "deleted_" + stem.dropFirst(6))
                if try io.info(deletion) != nil { report.skipped.append(target); continue }
                guard let sourceInfo = try io.info(source), io.isRegular(sourceInfo) else {
                    throw SessionDataError.unexpectedType(source)
                }
                let destinationInfo = try io.info(target)
                if let destinationInfo {
                    guard io.isRegular(destinationInfo) else { throw SessionDataError.unexpectedType(target) }
                    if try io.read(source) == io.read(target) { report.skipped.append(target); continue }
                    if !SessionFileIO.newer(sourceInfo, than: destinationInfo) { report.conflicts.append(target); continue }
                }
                try io.copy(source, to: target)
                if destinationInfo == nil { report.copied.append(target) }
                else { report.replaced.append(target) }
            } catch { report.errors.append(SyncIssue(path: target, kind: .file)) }
        }
        report.touchedBuckets = touched.sorted { $0.path < $1.path }
        for bucket in report.touchedBuckets {
            do { try ArchiveIndexRebuilder().rebuild(bucket: bucket) }
            catch { report.errors.append(SyncIssue(path: bucket, kind: .archiveIndex)) }
        }
        return report
    }

    public func syncTwoWay(_ plan: SyncPlan) throws -> TwoWaySyncReport {
        let forward = sync(plan)
        if forward.aborted {
            return TwoWaySyncReport(forward: forward, reverse: SyncReport(), unresolved: [])
        }
        let reverse = sync(try SyncPlan(source: plan.target, target: plan.source))
        let a = Set(forward.conflicts.map(\.lastPathComponent))
        let b = Set(reverse.conflicts.map(\.lastPathComponent))
        return TwoWaySyncReport(forward: forward, reverse: reverse, unresolved: a.intersection(b).sorted())
    }

    private func gather(_ directory: URL, into files: inout [URL], issues: inout [SyncIssue]) throws {
        for child in try io.list(directory) {
            let name = child.lastPathComponent
            if name == "waiting-input" || SessionFileIO.isIgnoredMetadata(name) { continue }
            guard let value = try io.info(child) else { throw SessionDataError.treeChanged }
            if io.isDirectory(value) {
                try gather(child, into: &files, issues: &issues)
            } else if io.isRegular(value) {
                if SessionFileIO.isSession(name) { files.append(child) }
            } else {
                issues.append(SyncIssue(path: child, kind: .traversal))
            }
        }
    }
}
