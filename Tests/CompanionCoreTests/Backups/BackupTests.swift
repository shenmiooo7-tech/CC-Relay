import Darwin
import XCTest
@testable import CompanionCore

final class BackupTests: XCTestCase {
    func testIgnoredMetadataLinksAndPipesDoNotEnterBackup() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let file = try writeSession(world.sourceBucket, "one")
        try FileManager.default.createSymbolicLink(at: world.sourceBucket.appending(path: ".DS_Store"), withDestinationURL: world.scratch.root)
        try FileManager.default.createSymbolicLink(at: world.sourceBucket.appending(path: "._local_x.json"), withDestinationURL: file)
        XCTAssertEqual(mkfifo(world.sourceBucket.appending(path: "._pipe").path, 0o600), 0)
        let snapshot = try XCTUnwrap(BackupManager(paths: world.paths).backup(profile: world.source))
        let bucket = snapshot.url.appending(path: "claude-code-sessions/account-a/org-a")
        for name in [".DS_Store", "._local_x.json", "._pipe"] { XCTAssertNil(try SessionFileIO().info(bucket.appending(path: name))) }
        XCTAssertEqual(try AtomicFile.read(bucket.appending(path: file.lastPathComponent)), try AtomicFile.read(file))
    }

    func testClockRollbackDoesNotPruneTheNewlyPublishedSnapshot() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let file = try writeSession(world.sourceBucket, "one")
        let future = TestClock(now: instant.addingTimeInterval(86_400))
        let futureManager = BackupManager(paths: world.paths, clock: future, calendar: utc)
        for _ in 0..<5 {
            _ = try futureManager.backup(profile: world.source, reuseIfUnchanged: false)
            future.advance(by: 1)
        }
        try setFileTime(file, seconds: 200)
        let manager = BackupManager(paths: world.paths, clock: TestClock(now: instant), calendar: utc)
        let current = try XCTUnwrap(manager.backup(profile: world.source))
        XCTAssertFalse(current.reused)
        XCTAssertEqual(current.url.lastPathComponent, "20261025-120000")
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.url.appending(path: "fingerprint.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: world.backups.path).count, 5)
    }

    func testAbandonedPartialCleanupPreservesFreshAndForeignEntries() throws {
        for hasTree in [false, true] {
            let world = try SessionTestWorld()
            defer { world.cleanup() }
            if !hasTree { try FileManager.default.removeItem(at: world.source.url.appending(path: "claude-code-sessions")) }
            func partial() -> URL {
                world.backups.appending(path: ".20261025-110000-" + UUID().uuidString + ".partial")
            }
            let stale = partial(), fresh = partial(), boundary = partial(), regular = partial(), link = partial()
            let foreign = world.backups.appending(path: ".not-our-backup.partial")
            for directory in [stale, fresh, boundary, foreign] {
                try AtomicFile.write(Data("incomplete copy".utf8), to: directory.appending(path: "copy"))
            }
            let seconds = Int(instant.timeIntervalSince1970)
            for directory in [stale, foreign] { try setFileTime(directory, seconds: seconds - 601) }
            try setFileTime(fresh, seconds: seconds - 599)
            try setFileTime(boundary, seconds: seconds - 600)
            try AtomicFile.write(Data("foreign file".utf8), to: regular)
            try setFileTime(regular, seconds: seconds - 601)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
            try setFileTime(link, seconds: seconds - 601)
            let manager = BackupManager(paths: world.paths, clock: TestClock(now: instant), calendar: utc)
            let result = try manager.backup(profile: world.source)
            XCTAssertEqual(result != nil, hasTree)
            XCTAssertNil(try SessionFileIO().info(stale))
            for survivor in [fresh, boundary, foreign, regular, link] { XCTAssertNotNil(try SessionFileIO().info(survivor)) }
        }
    }

    func testExtraProfileFilesPreserveBytesModeTimeAndParticipateInReuse() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let name = "claude_desktop_config.json"
        let file = world.source.url.appending(path: name)
        let original = Data("{\n  \"preferences\": {\"enabled\": true}, \"future\": [1, 2]\n}\n".utf8)
        try AtomicFile.write(original, to: file, permissions: 0o640)
        try setFileTime(file, seconds: 200, nanos: 123_456_789)
        let treeFile = world.source.url.appending(path: "claude-code-sessions/profile/" + name)
        try AtomicFile.write(original, to: treeFile)
        try setFileTime(treeFile, seconds: 200, nanos: 123_456_789)
        let manager = BackupManager(paths: world.paths, clock: TestClock(now: instant), calendar: utc)
        let first = try XCTUnwrap(manager.backup(profile: world.source, extraFiles: [name]))
        let copy = first.url.appending(path: name)
        XCTAssertEqual(try AtomicFile.read(copy), original)
        XCTAssertEqual(try posixMode(of: copy), 0o640)
        XCTAssertEqual(try SessionFileIO().info(copy)?.st_mtimespec.tv_sec, 200)
        XCTAssertEqual(try SessionFileIO().info(copy)?.st_mtimespec.tv_nsec, 123_456_789)
        XCTAssertTrue(try XCTUnwrap(manager.backup(profile: world.source, extraFiles: [name])).reused)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(first.url.appending(path: "fingerprint.json"))) as? [[String: Any]])
        let paths = stored.compactMap { $0["path"] as? String }
        XCTAssertTrue(paths.contains("profile/" + name))
        XCTAssertTrue(paths.contains("claude-code-sessions/profile/" + name))
        let updated = Data(#"{"preferences":{"enabled":false}}"#.utf8)
        try AtomicFile.write(updated, to: file)
        try setFileTime(file, seconds: 201)
        let second = try XCTUnwrap(manager.backup(profile: world.source, extraFiles: [name]))
        XCTAssertFalse(second.reused)
        XCTAssertEqual(try AtomicFile.read(second.url.appending(path: name)), updated)
        try FileManager.default.removeItem(at: second.url.appending(path: name))
        XCTAssertFalse(try XCTUnwrap(manager.backup(profile: world.source, extraFiles: [name])).reused)
        try manager.restore(snapshot: first.url, into: world.source)
        XCTAssertEqual(try AtomicFile.read(file), updated)
    }

    func testExtraFileAloneIsBackedUpAndMissingDataReturnsNil() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let name = "claude_desktop_config.json"
        try FileManager.default.removeItem(at: world.source.url.appending(path: "claude-code-sessions"))
        let manager = BackupManager(paths: world.paths, clock: TestClock(now: instant), calendar: utc)
        XCTAssertNil(try manager.backup(profile: world.source, extraFiles: [name]))
        let original = Data(#"{"preferences":{}}"#.utf8)
        try AtomicFile.write(original, to: world.source.url.appending(path: name))
        let snapshot = try XCTUnwrap(manager.backup(profile: world.source, extraFiles: [name]))
        XCTAssertEqual(try AtomicFile.read(snapshot.url.appending(path: name)), original)
        XCTAssertNil(try SessionFileIO().info(snapshot.url.appending(path: "claude-code-sessions")))
        XCTAssertTrue(try XCTUnwrap(manager.backup(profile: world.source, extraFiles: [name])).reused)
        XCTAssertNil(try manager.backup(profile: world.source))
    }

    func testExtraFileNamesAndNonRegularFilesAreRefused() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let manager = BackupManager(paths: world.paths)
        for invalid in ["", ".", "..", "../outside", "nested/file.json", "bad..json", "bad\0.json", "claude-code-sessions", "fingerprint.json", "Fingerprint.JSON"] {
            XCTAssertThrowsError(try manager.backup(profile: world.source, extraFiles: [invalid]), invalid)
        }
        let config = world.source.url.appending(path: "claude_desktop_config.json")
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: world.source.url.appending(path: "config.json"))
        XCTAssertThrowsError(try manager.backup(profile: world.source, extraFiles: [config.lastPathComponent]))
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        XCTAssertThrowsError(try manager.backup(profile: world.source, extraFiles: [config.lastPathComponent]))
        try FileManager.default.removeItem(at: config)
        XCTAssertEqual(mkfifo(config.path, 0o600), 0)
        XCTAssertThrowsError(try manager.backup(profile: world.source, extraFiles: [config.lastPathComponent]))
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var instant: Date { ISO8601Fractional.date(from: "2026-10-25T12:00:00Z")! }

    func testWholeTreeReuseTripleAgreementMtimeAndExplicitFreshCopy() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let file = try writeSession(world.sourceBucket, "one", seconds: 200, nanos: 987_654_321, mode: 0o640)
        let marker = world.sourceBucket.appending(path: "deleted_old")
        try AtomicFile.write(Data(), to: marker)
        let manager = BackupManager(paths: world.paths, clock: TestClock(now: instant), calendar: utc)
        let first = try XCTUnwrap(manager.backup(profile: world.source))
        XCTAssertEqual(first.url.lastPathComponent, "20261025-120000")
        XCTAssertFalse(first.reused)
        let snapshotTree = first.url.appending(path: "claude-code-sessions")
        let copied = snapshotTree.appending(path: "account-a/org-a/local_one.json")
        XCTAssertEqual(try AtomicFile.read(copied), try AtomicFile.read(file))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotTree.appending(path: "account-a/org-a/deleted_old").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotTree.appending(path: "account-a/org-a/scheduled-tasks.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotTree.appending(path: "account-a/org-a/waiting-input").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.appending(path: "config.json").path))
        XCTAssertEqual(try posixMode(of: copied), 0o640)
        XCTAssertEqual(try posixMode(of: snapshotTree), 0o700)
        XCTAssertEqual(try SessionFileIO().info(copied)?.st_mtimespec.tv_nsec, 987_654_321)
        XCTAssertEqual(try manager.backup(profile: world.source), BackupSnapshot(url: first.url, reused: true))
        try AtomicFile.write(Data("ignored".utf8), to: world.sourceBucket.appending(path: ".DS_Store"))
        try AtomicFile.write(Data("ignored".utf8), to: world.sourceBucket.appending(path: "._one"))
        XCTAssertTrue(try XCTUnwrap(manager.backup(profile: world.source)).reused)
        try setFileTime(file, seconds: 201, nanos: 987_654_321)
        let second = try XCTUnwrap(manager.backup(profile: world.source))
        XCTAssertFalse(second.reused)
        XCTAssertEqual(second.url.lastPathComponent, "20261025-120000-2")
        try FileManager.default.removeItem(at: second.url.appending(path: "claude-code-sessions/account-a/org-a/deleted_old"))
        let third = try XCTUnwrap(manager.backup(profile: world.source))
        XCTAssertFalse(third.reused)
        try AtomicFile.write(Data("broken".utf8), to: third.url.appending(path: "fingerprint.json"))
        let fourth = try XCTUnwrap(manager.backup(profile: world.source))
        XCTAssertFalse(fourth.reused)
        let explicit = try XCTUnwrap(manager.backup(profile: world.source, reuseIfUnchanged: false))
        XCTAssertFalse(explicit.reused)
        try assertNoStages(world.scratch.root)
    }

    func testDeletionMarkerChangesFingerprintAndOnlyNewestCanBeReused() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let marker = world.sourceBucket.appending(path: "deleted_id")
        let manager = BackupManager(paths: world.paths, clock: TestClock(now: instant), calendar: utc)
        let first = try XCTUnwrap(manager.backup(profile: world.source))
        try AtomicFile.write(Data(), to: marker)
        let second = try XCTUnwrap(manager.backup(profile: world.source))
        XCTAssertNotEqual(first.url, second.url)
        try FileManager.default.removeItem(at: marker)
        let third = try XCTUnwrap(manager.backup(profile: world.source))
        XCTAssertFalse(third.reused)
        XCTAssertNotEqual(first.url, third.url)
    }

    func testSnapshotIsInvisibleUntilCompleteAndFailureRemovesPartial() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        try writeSession(world.sourceBucket, "one")
        let directory = world.backups
        var io = SessionFileIO()
        io.beforeCopy = { _, target in
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertEqual(names.count, 1)
            XCTAssertTrue(names[0].hasSuffix(".partial"))
            XCTAssertTrue(target.path.contains(".partial/"))
        }
        let manager = BackupManager(paths: world.paths, clock: TestClock(now: instant), calendar: utc,
            log: CompanionLog(paths: world.paths), io: io)
        let snapshot = try XCTUnwrap(manager.backup(profile: world.source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.url.appending(path: "fingerprint.json").path))
        try assertNoStages(world.scratch.root)
        io.beforeCopy = { _, target in throw SessionDataError.filesystem(target, code: EIO) }
        let failing = BackupManager(paths: world.paths, clock: TestClock(now: instant), calendar: utc,
            log: CompanionLog(paths: world.paths), io: io)
        XCTAssertThrowsError(try failing.backup(profile: world.source, reuseIfUnchanged: false))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [snapshot.url.lastPathComponent])
        try assertNoStages(world.scratch.root)
    }

    func testRetentionTrashDatesAndForeignNames() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let manager = BackupManager(paths: world.paths, clock: TestClock(now: instant), calendar: utc)
        let trash = world.paths.companionDataDirectory.appending(path: "Backups/.trash")
        let fixtures = ["20260925-Claude-20260101-000000", "20260926-Claude-20260101-000000",
                        "20260901-manual", "manual", "20260230-Claude-20260101-000000",
                        "20260901-Claude-20260101-000000-100-2"]
        for name in fixtures { try FileManager.default.createDirectory(at: trash.appending(path: name), withIntermediateDirectories: true) }
        let foreign = world.backups.appending(path: "foreign-20200101")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: world.backups.appending(path: "20260230-000000"), withIntermediateDirectories: true)
        for _ in 0..<7 { _ = try manager.backup(profile: world.source, reuseIfUnchanged: false) }
        let names = try FileManager.default.contentsOfDirectory(atPath: world.backups.path).sorted()
        XCTAssertEqual(names, ["20260230-000000", "20261025-120000-3", "20261025-120000-4", "20261025-120000-5", "20261025-120000-6", "20261025-120000-7", "foreign-20200101"])
        let trashNames = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        XCTAssertTrue(trashNames.contains("20261025-Claude-20261025-120000"))
        XCTAssertTrue(trashNames.contains("20261025-Claude-20261025-120000-2"))
        XCTAssertFalse(trashNames.contains(fixtures[0]))
        XCTAssertTrue(trashNames.contains(fixtures[1]))
        XCTAssertTrue(trashNames.contains(fixtures[2]))
        XCTAssertTrue(trashNames.contains(fixtures[3]))
        XCTAssertTrue(trashNames.contains(fixtures[4]))
        XCTAssertFalse(trashNames.contains(fixtures[5]))
    }

    func testCollisionExhaustionDoesNotOverwriteAndPruneFailureIsOnlyLogged() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        for number in 1...100 {
            let suffix = number == 1 ? "" : "-\(number)"
            try FileManager.default.createDirectory(at: world.backups.appending(path: "20261025-120000" + suffix), withIntermediateDirectories: true)
        }
        let manager = BackupManager(paths: world.paths, clock: TestClock(now: instant), calendar: utc)
        XCTAssertThrowsError(try manager.backup(profile: world.source, reuseIfUnchanged: false))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: world.backups.path).count, 100)
        let later = TestClock(now: instant.addingTimeInterval(1))
        var io = SessionFileIO()
        io.beforeRename = { _, target in
            if target.path.contains("/.trash/") { throw SessionDataError.filesystem(target, code: EACCES) }
        }
        let logging = BackupManager(paths: world.paths, clock: later, calendar: utc,
            log: CompanionLog(paths: world.paths), io: io)
        XCTAssertNotNil(try logging.backup(profile: world.source, reuseIfUnchanged: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.paths.companionDataDirectory.appending(path: "Logs/cc-relay.log").path))
    }

    func testMissingTreeIsNoDataButWrongTypesAndTraversalErrorsFail() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let tree = world.source.url.appending(path: "claude-code-sessions")
        let manager = BackupManager(paths: world.paths)
        try FileManager.default.removeItem(at: tree)
        XCTAssertNil(try manager.backup(profile: world.source))
        try AtomicFile.write(Data(), to: tree)
        XCTAssertThrowsError(try manager.backup(profile: world.source))
        try FileManager.default.removeItem(at: tree)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        var io = SessionFileIO()
        io.beforeList = { url in throw SessionDataError.filesystem(url, code: EACCES) }
        let failing = BackupManager(paths: world.paths, clock: TestClock(), log: CompanionLog(paths: world.paths), io: io)
        XCTAssertThrowsError(try failing.backup(profile: world.source))
    }

    func testRestorePreservesCurrentBackupAndArchivesDisplacedTree() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let file = try writeSession(world.sourceBucket, "one", fields: ["state": "original"], seconds: 100)
        let manager = BackupManager(paths: world.paths, clock: TestClock(now: instant), calendar: utc)
        let snapshot = try XCTUnwrap(manager.backup(profile: world.source))
        let original = try AtomicFile.read(file)
        try writeSession(world.sourceBucket, "one", fields: ["state": "changed"], seconds: 200)
        let changed = try AtomicFile.read(file)
        try manager.restore(snapshot: snapshot.url, into: world.source)
        XCTAssertEqual(try AtomicFile.read(file), original)
        let safety = world.backups.appending(path: "20261025-120000-2/claude-code-sessions/account-a/org-a/local_one.json")
        XCTAssertEqual(try AtomicFile.read(safety), changed)
        let displaced = world.paths.companionDataDirectory.appending(path: "Backups/.trash/20261025-Claude-20261025-120000/account-a/org-a/local_one.json")
        XCTAssertEqual(try AtomicFile.read(displaced), changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.source.url.appending(path: "claude-code-sessions.restoring").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.source.url.appending(path: "claude-code-sessions.old").path))
    }

    func testRestoreRollsBackOnFinalRenameFailureAndDoesNotPruneSource() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let file = try writeSession(world.sourceBucket, "one", fields: ["state": "original"])
        let manager = BackupManager(paths: world.paths, clock: TestClock(now: instant), calendar: utc)
        let source = try XCTUnwrap(manager.backup(profile: world.source, prune: false))
        for _ in 0..<5 { _ = try manager.backup(profile: world.source, reuseIfUnchanged: false, prune: false) }
        try writeSession(world.sourceBucket, "one", fields: ["state": "current"], seconds: 200)
        let original = try AtomicFile.read(file)
        var io = SessionFileIO()
        io.beforeRename = { source, target in
            if source.lastPathComponent == "claude-code-sessions.restoring" { throw SessionDataError.filesystem(target, code: EIO) }
        }
        let failing = BackupManager(paths: world.paths, clock: TestClock(now: instant), calendar: utc,
            log: CompanionLog(paths: world.paths), io: io)
        XCTAssertThrowsError(try failing.restore(snapshot: source.url, into: world.source))
        XCTAssertEqual(try AtomicFile.read(file), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: world.backups.path).count, 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.source.url.appending(path: "claude-code-sessions.restoring").path))
        try assertNoStages(world.scratch.root)
    }

    func testRestoreRefusesStaleRecoveryTrees() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let manager = BackupManager(paths: world.paths)
        let source = try XCTUnwrap(manager.backup(profile: world.source))
        let stage = world.source.url.appending(path: "claude-code-sessions.restoring")
        try AtomicFile.write(Data("recovery evidence".utf8), to: stage.appending(path: "keep"))
        XCTAssertThrowsError(try manager.restore(snapshot: source.url, into: world.source))
        XCTAssertEqual(try AtomicFile.read(stage.appending(path: "keep")), Data("recovery evidence".utf8))
    }

    func testRestoreBackupFailureAndRollbackFailurePreserveRecoveryEvidence() throws {
        for failRollback in [false, true] {
            let world = try SessionTestWorld()
            defer { world.cleanup() }
            let file = try writeSession(world.sourceBucket, "one", fields: ["state": "old"])
            let manager = BackupManager(paths: world.paths, clock: TestClock(now: instant), calendar: utc)
            let snapshot = try XCTUnwrap(manager.backup(profile: world.source))
            try writeSession(world.sourceBucket, "one", fields: ["state": "current"], seconds: 200)
            let expected = try AtomicFile.read(file)
            var io = SessionFileIO()
            if failRollback {
                io.beforeRename = { source, target in
                    if source.lastPathComponent == "claude-code-sessions.restoring" || source.lastPathComponent == "claude-code-sessions.old" {
                        throw SessionDataError.filesystem(target, code: EIO)
                    }
                }
            } else {
                io.beforeCopy = { _, target in
                    if target.path.contains(".partial/") { throw SessionDataError.filesystem(target, code: EIO) }
                }
            }
            let failing = BackupManager(paths: world.paths, clock: TestClock(now: instant), calendar: utc,
                log: CompanionLog(paths: world.paths), io: io)
            XCTAssertThrowsError(try failing.restore(snapshot: snapshot.url, into: world.source)) {
                if failRollback { XCTAssertEqual($0 as? SessionDataError, .rollbackFailed) }
            }
            let survivor = failRollback ? world.source.url.appending(path: "claude-code-sessions.old/account-a/org-a/local_one.json") : file
            XCTAssertEqual(try AtomicFile.read(survivor), expected)
            XCTAssertFalse(FileManager.default.fileExists(atPath: world.source.url.appending(path: "claude-code-sessions.restoring").path))
            try assertNoStages(world.scratch.root)
        }
    }

    func testSnapshotPublicationNeverOverwritesAConcurrentName() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let destination = world.backups.appending(path: "20261025-120000")
        var io = SessionFileIO()
        io.beforeRename = { source, target in
            if source.lastPathComponent.hasSuffix(".partial") {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            }
        }
        let manager = BackupManager(paths: world.paths, clock: TestClock(now: instant), calendar: utc,
            log: CompanionLog(paths: world.paths), io: io)
        XCTAssertThrowsError(try manager.backup(profile: world.source))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        try assertNoStages(world.scratch.root)
    }

    func testTrashRetentionUsesCalendarDaysAcrossDaylightSaving() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 30, hour: 12)))
        let trash = world.paths.companionDataDirectory.appending(path: "Backups/.trash")
        let cutoffEntry = trash.appending(path: "20260228-Claude-20260101-000000")
        let keep = trash.appending(path: "20260301-Claude-20260101-000000")
        for url in [cutoffEntry, keep] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let manager = BackupManager(paths: world.paths, clock: TestClock(now: now), calendar: calendar)
        _ = try manager.backup(profile: world.source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cutoffEntry.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
    }
}
