import Darwin
import XCTest
@testable import CompanionCore

final class SessionSyncTests: XCTestCase {
    func testSourceSpecialEntriesAreReportedWithoutFollowingThem() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let good = try writeSession(world.sourceBucket, "good")
        let account = world.sourceBucket.deletingLastPathComponent()
        let outside = world.scratch.root.appending(path: "untraversed-org")
        try writeSession(outside, "outside")
        let orgLink = account.appending(path: "linked-org")
        let fileLink = world.sourceBucket.appending(path: "linked-file")
        let sessionLink = world.sourceBucket.appending(path: "local_link.json")
        let fifo = account.appending(path: "pipe")
        try FileManager.default.createSymbolicLink(at: orgLink, withDestinationURL: outside)
        for link in [fileLink, sessionLink] { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: good) }
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        for name in [".DS_Store", "._local_ignored.json"] {
            try FileManager.default.createSymbolicLink(at: account.appending(path: name), withDestinationURL: outside)
        }
        let waiting = world.sourceBucket.appending(path: "waiting-input")
        try FileManager.default.removeItem(at: waiting)
        XCTAssertEqual(mkfifo(waiting.path, 0o600), 0)
        let report = SessionSync().sync(try SyncPlan(source: world.source, target: world.target))
        XCTAssertFalse(report.aborted)
        XCTAssertEqual(Set(report.errors.map(\.path.path)), Set([orgLink, fileLink, sessionLink, fifo].map(\.path)))
        XCTAssertTrue(report.errors.allSatisfy { $0.kind == .traversal })
        XCTAssertEqual(report.copied.map(\.lastPathComponent), ["local_good.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.targetBucket.appending(path: "local_outside.json").path))
    }

    func testForwardTraversalAbortPreventsReverseWrites() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        try writeSession(world.targetBucket, "reverse")
        var io = SessionFileIO()
        let sourcePath = world.sourceBucket.path
        io.beforeList = { url in
            if url.path == sourcePath { throw SessionDataError.filesystem(url, code: EACCES) }
        }
        let result = try SessionSync(io: io).syncTwoWay(SyncPlan(source: world.source, target: world.target))
        XCTAssertTrue(result.forward.aborted)
        XCTAssertEqual(result.reverse, SyncReport())
        XCTAssertTrue(result.unresolved.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.sourceBucket.appending(path: "local_reverse.json").path))
    }

    func testRehomingResidueOtherOrgAndAccountIsolation() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let source = try writeSession(world.sourceBucket, "active", fields: ["future": ["preserve": true]])
        let root = world.source.url.appending(path: "claude-code-sessions")
        try writeSession(root.appending(path: "account-a/org-b"), "residue")
        try writeSession(root.appending(path: "account-a/third-org"), "third")
        try writeSession(root.appending(path: "foreign-account/org-a"), "foreign")
        let report = SessionSync().sync(try SyncPlan(source: world.source, target: world.target))
        XCTAssertFalse(report.aborted)
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertEqual(report.copied.count, 2)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertEqual(try AtomicFile.read(source), try AtomicFile.read(world.targetBucket.appending(path: "local_active.json")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.target.url.appending(path: "claude-code-sessions/account-b/third-org/local_third.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.targetBucket.appending(path: "local_residue.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.targetBucket.appending(path: "local_foreign.json").path))
    }

    func testEqualUnknownAndMissingActiveOrgKeepPaths() throws {
        for variant in 0..<3 {
            var world = try SessionTestWorld()
            defer { world.cleanup() }
            var identity = AccountIdentity(accountUUID: "account-b", activeOrganizationUUID: "org-a")
            if variant == 1 { identity.activeOrganizationUUID = nil }
            world.target.status = .signedIn(identity)
            let org = variant == 2 ? "other" : "org-a"
            if variant == 2 {
                world.target.status = .signedIn(AccountIdentity(accountUUID: "account-b", activeOrganizationUUID: "org-b"))
                try FileManager.default.removeItem(at: world.sourceBucket)
            }
            try writeSession(world.source.url.appending(path: "claude-code-sessions/account-a/" + org), "kept")
            let report = SessionSync().sync(try SyncPlan(source: world.source, target: world.target))
            XCTAssertEqual(report.copied.count, 1)
            XCTAssertTrue(report.errors.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: world.target.url.appending(path: "claude-code-sessions/account-b/" + org + "/local_kept.json").path))
            if variant == 1 { XCTAssertEqual(report.warnings, [.unknownOrganization]) }
            if variant == 2 { XCTAssertEqual(report.warnings, [.missingActiveOrganizationBucket]) }
        }
    }

    func testContentThenMtimeMatrixAndMetadataPreservation() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let identical = try writeSession(world.sourceBucket, "identical", seconds: 300)
        try AtomicFile.write(AtomicFile.read(identical), to: world.targetBucket.appending(path: identical.lastPathComponent))
        try setFileTime(world.targetBucket.appending(path: identical.lastPathComponent), seconds: 100)
        let absent = try writeSession(world.sourceBucket, "absent", seconds: 200, nanos: 123_456_789, mode: 0o640)
        for (id, sourceTime, targetTime) in [("newer", 300, 100), ("older", 100, 300), ("equal", 200, 200)] {
            try writeSession(world.sourceBucket, id, fields: ["title": "source"], seconds: sourceTime)
            try writeSession(world.targetBucket, id, fields: ["title": "target"], seconds: targetTime)
        }
        try writeSession(world.sourceBucket, "nanonewer", fields: ["title": "source"], seconds: 200, nanos: 2)
        try writeSession(world.targetBucket, "nanonewer", fields: ["title": "target"], seconds: 200, nanos: 1)
        let report = SessionSync().sync(try SyncPlan(source: world.source, target: world.target))
        XCTAssertEqual(report.copied.map(\.lastPathComponent), ["local_absent.json"])
        XCTAssertEqual(report.replaced.map(\.lastPathComponent), ["local_nanonewer.json", "local_newer.json"])
        XCTAssertEqual(report.skipped.map(\.lastPathComponent), ["local_identical.json"])
        XCTAssertEqual(report.conflicts.map(\.lastPathComponent), ["local_equal.json", "local_older.json"])
        XCTAssertTrue(report.errors.isEmpty)
        let copied = world.targetBucket.appending(path: absent.lastPathComponent)
        XCTAssertEqual(try posixMode(of: copied), 0o640)
        let a = try XCTUnwrap(SessionFileIO().info(absent)), b = try XCTUnwrap(SessionFileIO().info(copied))
        XCTAssertEqual(a.st_mtimespec.tv_sec, b.st_mtimespec.tv_sec)
        XCTAssertEqual(a.st_mtimespec.tv_nsec, b.st_mtimespec.tv_nsec)
        try assertNoStages(world.scratch.root)
    }

    func testDeletionMarkersScheduledTasksAndWaitingInputNeverCopied() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        try writeSession(world.sourceBucket, "deleted")
        try AtomicFile.write(Data(), to: world.targetBucket.appending(path: "deleted_deleted"))
        try AtomicFile.write(Data("source schedule".utf8), to: world.sourceBucket.appending(path: "scheduled-tasks.json"))
        let original = try AtomicFile.read(world.targetBucket.appending(path: "scheduled-tasks.json"))
        try writeSession(world.sourceBucket.appending(path: "waiting-input"), "hidden")
        try AtomicFile.write(Data(), to: world.sourceBucket.appending(path: "deleted_only-source"))
        let report = SessionSync().sync(try SyncPlan(source: world.source, target: world.target))
        XCTAssertTrue(report.copied.isEmpty)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertEqual(try AtomicFile.read(world.targetBucket.appending(path: "scheduled-tasks.json")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.targetBucket.appending(path: "waiting-input/local_hidden.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.targetBucket.appending(path: "deleted_only-source").path))
    }

    func testNonRegularTargetsArePerFileErrorsAndGoodFilesContinue() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        for id in ["link", "dangling", "directory", "good"] { try writeSession(world.sourceBucket, id) }
        let protected = world.scratch.root.appending(path: "protected")
        try AtomicFile.write(Data("unchanged".utf8), to: protected)
        try FileManager.default.createSymbolicLink(at: world.targetBucket.appending(path: "local_link.json"), withDestinationURL: protected)
        try FileManager.default.createSymbolicLink(at: world.targetBucket.appending(path: "local_dangling.json"), withDestinationURL: world.scratch.root.appending(path: "absent"))
        try FileManager.default.createDirectory(at: world.targetBucket.appending(path: "local_directory.json"), withIntermediateDirectories: true)
        let report = SessionSync().sync(try SyncPlan(source: world.source, target: world.target))
        XCTAssertEqual(report.errors.filter { $0.kind == .file }.count, 3)
        XCTAssertEqual(report.copied.count, 1)
        XCTAssertEqual(try AtomicFile.read(protected), Data("unchanged".utf8))
        XCTAssertFalse(report.aborted)
    }

    func testParentSymlinkRefusalAndTraversalAbort() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        try writeSession(world.sourceBucket, "one")
        var io = SessionFileIO()
        io.beforeList = { url in
            if url.lastPathComponent == "org-a" { throw SessionDataError.filesystem(url, code: EACCES) }
        }
        let failed = SessionSync(io: io).sync(try SyncPlan(source: world.source, target: world.target))
        XCTAssertTrue(failed.aborted)
        XCTAssertEqual(failed.errors.map(\.kind), [.traversal])
        XCTAssertTrue(failed.copied.isEmpty)
        try FileManager.default.removeItem(at: world.targetBucket)
        let outside = world.scratch.root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: world.targetBucket, withDestinationURL: outside)
        let refused = SessionSync().sync(try SyncPlan(source: world.source, target: world.target))
        XCTAssertEqual(refused.errors.filter { $0.kind == .file }.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testRenameFailureRemovesStageAndPreservesDestination() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        try writeSession(world.sourceBucket, "one", fields: ["value": "new"], seconds: 300)
        let target = try writeSession(world.targetBucket, "one", fields: ["value": "old"], seconds: 100)
        let original = try AtomicFile.read(target)
        var io = SessionFileIO()
        io.beforeRename = { _, target in throw SessionDataError.filesystem(target, code: EIO) }
        let report = SessionSync(io: io).sync(try SyncPlan(source: world.source, target: world.target))
        XCTAssertEqual(report.errors.filter { $0.kind == .file }.count, 1)
        XCTAssertEqual(try AtomicFile.read(target), original)
        try assertNoStages(world.scratch.root)
    }

    func testTwoWayBasenameIntersectionAndConvergence() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        for (id, a, b) in [("equal", 200, 200), ("older", 100, 300), ("newer", 300, 100)] {
            try writeSession(world.sourceBucket, id, fields: ["origin": "a"], seconds: a)
            try writeSession(world.targetBucket, id, fields: ["origin": "b"], seconds: b)
        }
        let result = try SessionSync().syncTwoWay(SyncPlan(source: world.source, target: world.target))
        XCTAssertEqual(result.unresolved, ["local_equal.json"])
        for id in ["older", "newer"] {
            XCTAssertEqual(try AtomicFile.read(world.sourceBucket.appending(path: "local_\(id).json")),
                           try AtomicFile.read(world.targetBucket.appending(path: "local_\(id).json")))
        }
    }

    func testPlanValidation() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        XCTAssertThrowsError(try SyncPlan(source: world.source, target: world.source))
        var alias = world.source
        alias.url = URL(fileURLWithPath: world.source.url.path, isDirectory: true)
        XCTAssertThrowsError(try SyncPlan(source: world.source, target: alias))
        var unsigned = world.target
        unsigned.status = .awaitingSignIn
        XCTAssertThrowsError(try SyncPlan(source: world.source, target: unsigned))
        unsigned.status = .signedIn(AccountIdentity(accountUUID: ""))
        XCTAssertThrowsError(try SyncPlan(source: world.source, target: unsigned))
        unsigned.status = .signedIn(AccountIdentity(accountUUID: "../escape"))
        XCTAssertThrowsError(try SyncPlan(source: world.source, target: unsigned))
    }
}
