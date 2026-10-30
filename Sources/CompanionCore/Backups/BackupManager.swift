import Foundation

public struct BackupSnapshot: Equatable, Sendable {
    public let url: URL
    public let reused: Bool
}

public struct BackupManager: Sendable {
    private let root: URL
    private let clock: any Clock
    private let calendar: Calendar
    private let log: CompanionLog
    private let io: SessionFileIO

    public init(paths: AppPaths, clock: any Clock = SystemClock(), calendar: Calendar = .current,
                log: CompanionLog? = nil) {
        self.init(paths: paths, clock: clock, calendar: calendar,
                  log: log ?? CompanionLog(paths: paths, clock: clock), io: SessionFileIO())
    }

    init(paths: AppPaths, clock: any Clock, calendar: Calendar = .current, log: CompanionLog,
         io: SessionFileIO) {
        root = paths.companionDataDirectory.appending(path: "Backups")
        self.clock = clock
        self.calendar = calendar
        self.log = log
        self.io = io
    }

    /// Callers must establish that no Claude instance is using the profile.
    /// extraFiles contains top-level file names, such as claude_desktop_config.json.
    public func backup(profile: ProfileSnapshot, extraFiles: [String] = [], reuseIfUnchanged: Bool = true,
                       prune: Bool = true) throws -> BackupSnapshot? {
        let extraFiles = try validatedExtraFiles(extraFiles)
        let directory = root.appending(path: profile.folder.name)
        removeStalePartials(in: directory)
        let tree = profile.url.appending(path: "claude-code-sessions")
        guard let current = try snapshotFingerprint(profile.url, extraFiles: extraFiles) else { return nil }
        try io.makeDirectory(directory)
        if reuseIfUnchanged, let newest = try snapshots(in: directory).first {
            let stored = try? StableJSON.decode([FingerprintEntry].self,
                from: io.read(newest.url.appending(path: "fingerprint.json")))
            let measured = try? snapshotFingerprint(newest.url, extraFiles: extraFiles)
            if stored == current && measured == current {
                if prune { pruneSafely(folder: profile.folder, protecting: newest.url) }
                return BackupSnapshot(url: newest.url, reused: true)
            }
        }
        let name = stamp(clock.now())
        let destination = try unusedSnapshot(in: directory, stamp: name)
        let stage = directory.appending(path: "." + destination.lastPathComponent + "-" + UUID().uuidString + ".partial")
        try io.makeDirectory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        let stagedTree = stage.appending(path: "claude-code-sessions")
        if try io.info(tree) != nil { try io.copyTree(tree, to: stagedTree) }
        for name in extraFiles {
            let source = profile.url.appending(path: name)
            if try io.info(source) != nil { try io.copy(source, to: stage.appending(path: name)) }
        }
        guard try snapshotFingerprint(stage, extraFiles: extraFiles) == current,
              try snapshotFingerprint(profile.url, extraFiles: extraFiles) == current else {
            throw SessionDataError.treeChanged
        }
        try AtomicFile.write(StableJSON.encode(current), to: stage.appending(path: "fingerprint.json"))
        guard try io.info(destination) == nil else { throw SessionDataError.noAvailableName(destination) }
        try io.rename(stage, destination)
        if prune { pruneSafely(folder: profile.folder, protecting: destination) }
        return BackupSnapshot(url: destination, reused: false)
    }

    /// Restores the sessions tree only; extra profile files in the snapshot are not restored.
    /// Running-process checks remain the caller's responsibility.
    public func restore(snapshot: URL, into profile: ProfileSnapshot) throws {
        let source = snapshot.appending(path: "claude-code-sessions")
        try io.checkPath(source, under: snapshot)
        try io.requireDirectory(source)
        let current = profile.url.appending(path: "claude-code-sessions")
        let stage = profile.url.appending(path: "claude-code-sessions.restoring")
        let old = profile.url.appending(path: "claude-code-sessions.old")
        try io.checkPath(current, under: profile.url)
        // Stale trees may be recovery evidence. Never silently delete them.
        guard try io.info(stage) == nil, try io.info(old) == nil else { throw SessionDataError.unexpectedType(stage) }
        let expected = try fingerprint(source)
        _ = try backup(profile: profile, reuseIfUnchanged: false, prune: false)
        try io.makeDirectory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        try io.copyTree(source, to: stage)
        guard try fingerprint(stage) == expected, try fingerprint(source) == expected else { throw SessionDataError.treeChanged }
        let hadCurrent = try io.info(current) != nil
        if hadCurrent { try io.rename(current, old) }
        do { try io.rename(stage, current) }
        catch {
            if hadCurrent {
                do { try io.rename(old, current) }
                catch { throw SessionDataError.rollbackFailed }
            }
            throw error
        }
        if hadCurrent {
            do {
                let trash = root.appending(path: ".trash")
                try io.makeDirectory(trash)
                let name = day(clock.now()) + "-" + profile.folder.name + "-" + stamp(clock.now())
                try io.rename(old, unused(in: trash, base: name))
            } catch { log.warning(.backup, "Restored sessions; displaced tree retained at its recovery path") }
        }
    }

    private struct FingerprintEntry: Codable, Equatable {
        let path: String
        let size: Int64
        let seconds: Int64
        let nanoseconds: Int64
    }

    private func validatedExtraFiles(_ names: [String]) throws -> [String] {
        for name in names {
            guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), name != ".", !name.contains(".."),
                  name.lowercased() != "claude-code-sessions", name.lowercased() != "fingerprint.json" else {
                throw SessionDataError.invalidPlan
            }
        }
        return Set(names).sorted()
    }

    private func snapshotFingerprint(_ directory: URL, extraFiles: [String]) throws -> [FingerprintEntry]? {
        let tree = directory.appending(path: "claude-code-sessions")
        try io.checkPath(tree, under: directory)
        var result: [FingerprintEntry] = []
        if let value = try io.info(tree) {
            guard io.isDirectory(value) else { throw SessionDataError.unexpectedType(tree) }
            // A presence entry distinguishes an empty sessions tree from an absent one.
            result.append(FingerprintEntry(path: "claude-code-sessions", size: 0, seconds: 0, nanoseconds: 0))
            result += try fingerprint(tree).map {
                FingerprintEntry(path: "claude-code-sessions/" + $0.path, size: $0.size,
                    seconds: $0.seconds, nanoseconds: $0.nanoseconds)
            }
        }
        for name in extraFiles {
            let file = directory.appending(path: name)
            try io.checkPath(file, under: directory)
            guard let value = try io.info(file) else { continue }
            guard io.isRegular(value) else { throw SessionDataError.unexpectedType(file) }
            // This namespace is disjoint from every path inside the sessions tree.
            result.append(FingerprintEntry(path: "profile/" + name, size: Int64(value.st_size),
                seconds: Int64(value.st_mtimespec.tv_sec), nanoseconds: Int64(value.st_mtimespec.tv_nsec)))
        }
        return result.isEmpty ? nil : result.sorted { $0.path < $1.path }
    }

    private func fingerprint(_ tree: URL) throws -> [FingerprintEntry] {
        var result: [FingerprintEntry] = []
        try fingerprintWalk(tree, relative: "", into: &result)
        return result.sorted { $0.path < $1.path }
    }

    private func fingerprintWalk(_ directory: URL, relative: String, into result: inout [FingerprintEntry]) throws {
        for child in try io.list(directory) {
            let name = child.lastPathComponent
            if SessionFileIO.isIgnoredMetadata(name) { continue }
            guard let info = try io.info(child) else { throw SessionDataError.treeChanged }
            let path = relative.isEmpty ? name : relative + "/" + name
            if io.isDirectory(info) { try fingerprintWalk(child, relative: path, into: &result) }
            else if io.isRegular(info) {
                result.append(FingerprintEntry(path: path, size: Int64(info.st_size),
                    seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec)))
            } else { throw SessionDataError.unexpectedType(child) }
        }
    }

    private struct NamedSnapshot {
        let url: URL
        let stamp: String
        let collision: Int
    }

    private func removeStalePartials(in directory: URL) {
        do {
            guard try io.info(directory) != nil else { return }
            let cutoff = clock.now().addingTimeInterval(-600)
            for entry in try io.list(directory) where isPartialName(entry.lastPathComponent) {
                do {
                    guard let metadata = try io.info(entry), io.isDirectory(metadata) else { continue }
                    let modified = Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec) +
                        Double(metadata.st_mtimespec.tv_nsec) / 1e9)
                    if modified < cutoff { try FileManager.default.removeItem(at: entry) }
                } catch { log.warning(.backup, "Could not remove an abandoned partial snapshot") }
            }
        } catch { log.warning(.backup, "Could not inspect partial snapshots") }
    }

    private func isPartialName(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".partial") else { return false }
        let body = String(name.dropFirst().dropLast(".partial".count))
        guard body.count > 37, UUID(uuidString: String(body.suffix(36))) != nil,
              body.dropLast(36).last == "-" else { return false }
        return parseSnapshot(String(body.dropLast(37))) != nil
    }

    private func snapshots(in directory: URL) throws -> [NamedSnapshot] {
        guard try io.info(directory) != nil else { return [] }
        var result: [NamedSnapshot] = []
        for child in try io.list(directory) {
            guard let parsed = parseSnapshot(child.lastPathComponent),
                  let info = try io.info(child), io.isDirectory(info) else { continue }
            result.append(NamedSnapshot(url: child, stamp: parsed.0, collision: parsed.1))
        }
        return result.sorted { $0.stamp == $1.stamp ? $0.collision > $1.collision : $0.stamp > $1.stamp }
    }

    private func parseSnapshot(_ name: String) -> (String, Int)? {
        guard name.range(of: #"^\d{8}-\d{6}(-([2-9]|[1-9][0-9]|100))?$"#, options: .regularExpression) != nil else { return nil }
        let base = String(name.prefix(15))
        let formatter = formatter("yyyyMMdd-HHmmss")
        guard let date = formatter.date(from: base), formatter.string(from: date) == base else { return nil }
        return (base, name.count == 15 ? 1 : Int(name.dropFirst(16))!)
    }

    private func unused(in directory: URL, base: String) throws -> URL {
        for count in 1...100 {
            let candidate = directory.appending(path: base + (count == 1 ? "" : "-\(count)"))
            if try io.info(candidate) == nil { return candidate }
        }
        throw SessionDataError.noAvailableName(directory)
    }

    private func unusedSnapshot(in directory: URL, stamp: String) throws -> URL {
        // Retention can free a lower counter in this same second. Reusing that
        // counter would make the new snapshot look oldest and immediately prune it.
        let highest = try snapshots(in: directory).filter { $0.stamp == stamp }.map(\.collision).max() ?? 0
        guard highest < 100 else { throw SessionDataError.noAvailableName(directory) }
        for count in (highest + 1)...100 {
            let candidate = directory.appending(path: stamp + (count == 1 ? "" : "-\(count)"))
            if try io.info(candidate) == nil { return candidate }
        }
        throw SessionDataError.noAvailableName(directory)
    }

    private func pruneSafely(folder: ProfileFolder, protecting snapshot: URL) {
        do {
            let directory = root.appending(path: folder.name)
            let trash = root.appending(path: ".trash")
            // Count the protected snapshot within the five retained entries even
            // when a clock rollback puts its name behind the other snapshots.
            let others = try snapshots(in: directory).filter { $0.url.path != snapshot.path }
            for entry in others.dropFirst(4) {
                do {
                    try io.makeDirectory(trash)
                    let name = day(clock.now()) + "-" + folder.name + "-" + entry.url.lastPathComponent
                    try io.rename(entry.url, unused(in: trash, base: name))
                } catch { log.warning(.backup, "Could not move an expired snapshot to backup trash") }
            }
            try pruneTrash(trash)
        } catch { log.warning(.backup, "Could not inspect backup retention") }
    }

    private func pruneTrash(_ trash: URL) throws {
        guard try io.info(trash) != nil else { return }
        let today = calendar.startOfDay(for: clock.now())
        guard let cutoff = calendar.date(byAdding: .day, value: -30, to: today) else { return }
        for entry in try io.list(trash) {
            guard let date = trashDate(entry.lastPathComponent), date <= cutoff,
                  let info = try io.info(entry), io.isDirectory(info) else { continue }
            do { try FileManager.default.removeItem(at: entry) }
            catch { log.warning(.backup, "Could not remove an expired backup trash entry") }
        }
    }

    private func trashDate(_ name: String) -> Date? {
        guard name.count > 25 else { return nil }
        let prefix = String(name.prefix(8))
        let formatter = formatter("yyyyMMdd")
        guard name.dropFirst(8).first == "-", let date = formatter.date(from: prefix),
              formatter.string(from: date) == prefix else { return nil }
        // Parse the folder from the right; folders may themselves contain '-' and dates.
        let remainder = String(name.dropFirst(9))
        for index in remainder.indices where remainder[index] == "-" {
            let folder = String(remainder[..<index])
            let snapshotName = String(remainder[remainder.index(after: index)...])
            if (try? ProfileFolder(folder)) != nil && parseTrashSnapshot(snapshotName) { return date }
        }
        return nil
    }

    private func parseTrashSnapshot(_ name: String) -> Bool {
        if parseSnapshot(name) != nil { return true }
        guard let separator = name.lastIndex(of: "-"), let suffix = Int(name[name.index(after: separator)...]),
              (2...100).contains(suffix) else { return false }
        return parseSnapshot(String(name[..<separator])) != nil
    }

    private func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }
    private func stamp(_ date: Date) -> String { formatter("yyyyMMdd-HHmmss").string(from: date) }
    private func day(_ date: Date) -> String { formatter("yyyyMMdd").string(from: date) }
}
