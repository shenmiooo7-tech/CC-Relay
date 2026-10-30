import Darwin
import XCTest
@testable import CompanionCore

final class ContinuityTests: XCTestCase {
    func testRecoveryLaunchUsesNativeWakeupWithoutChangingPermissionsOrTheOriginalError() throws {
        let world = try SessionTestWorld(); defer { world.cleanup() }
        let (inspector, capture, _, file, _) = try prepare(world)
        try modifyJSON(file) {
            $0["permissionMode"] = "default"
            $0["error"] = "account limit"
            $0["interruptedAwaitingPerson"] = NSNull()
        }
        let now = Date(timeIntervalSince1970: 1_793_140_000)
        try inspector.prepareNativeRecoveryLaunch(sessionID: capture.record.sessionID,
            cliSessionID: capture.record.cliSessionID, profile: world.target, at: now)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        XCTAssertEqual(SessionJSON.integer(value["interruptedByQuitAt"]), 1_793_140_000_000)
        XCTAssertEqual(SessionJSON.boolean(value["interruptedAwaitingPerson"]), false)
        XCTAssertEqual(value["permissionMode"] as? String, "default")
        XCTAssertEqual(value["error"] as? String, "account limit")
        XCTAssertEqual(try inspector.readRecord(at: file).cliSessionID, capture.record.cliSessionID)
    }

    func testRecoveryLaunchPreservesNativePersonHoldsAndRejectsReplacedSessions() throws {
        for held in ["stoppedUntilPersonSends", "interruptedAwaitingPerson", "cliSessionId"] {
            let world = try SessionTestWorld(); defer { world.cleanup() }
            let (inspector, capture, _, file, _) = try prepare(world)
            try modifyJSON(file) { $0[held] = held == "cliSessionId" ? "replaced-session" : true }
            let before = try AtomicFile.read(file)
            XCTAssertThrowsError(try inspector.prepareNativeRecoveryLaunch(sessionID: capture.record.sessionID,
                cliSessionID: capture.record.cliSessionID, profile: world.target, at: Date()))
            XCTAssertEqual(try AtomicFile.read(file), before)
        }
    }

    func testTranscriptLookupFollowsHomeProjectsProjectAndFileLinks() throws {
        for component in 0..<4 {
            let world = try SessionTestWorld()
            defer { world.cleanup() }
            let (inspector, capture, identity, _, transcript) = try prepare(world)
            let originals = [world.paths.claudeCLIHome, world.paths.claudeCLIHome.appending(path: "projects"),
                transcript.deletingLastPathComponent(), transcript]
            let original = originals[component]
            let relocated = world.scratch.root.appending(path: "relocated-transcripts")
            try FileManager.default.moveItem(at: original, to: relocated)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: relocated)
            XCTAssertNoThrow(try inspector.validateTarget(capture, profile: world.target, expectedIdentity: identity))
        }
    }

    func testUnreadableProjectDoesNotBlockReadableTranscript() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let (_, capture, identity, _, _) = try prepare(world)
        let blocked = world.paths.claudeCLIHome.appending(path: "projects/aaa-blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        defer { _ = chmod(blocked.path, 0o700) }
        XCTAssertEqual(chmod(blocked.path, 0), 0)
        var io = SessionFileIO()
        let blockedPath = blocked.resolvingSymlinksInPath().path
        io.beforeInfo = { url in
            if url.path == blockedPath { throw SessionDataError.filesystem(url, code: EACCES) }
        }
        let inspector = ContinuityInspector(paths: world.paths, io: io)
        XCTAssertNoThrow(try inspector.validateTarget(capture, profile: world.target, expectedIdentity: identity))
    }

    func testBucketLinksAndPathFailuresStayInsideContinuityFailure() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let (inspector, capture, identity, file, _) = try prepare(world)
        let relocated = world.scratch.root.appending(path: "relocated-bucket")
        try FileManager.default.moveItem(at: world.targetBucket, to: relocated)
        try FileManager.default.createSymbolicLink(at: world.targetBucket, withDestinationURL: relocated)
        XCTAssertThrowsError(try inspector.validateTarget(capture, profile: world.target, expectedIdentity: identity)) {
            XCTAssertEqual($0 as? ContinuityFailure, .unreadable)
        }
        XCTAssertThrowsError(try inspector.capture(profile: world.target)) {
            XCTAssertEqual($0 as? ContinuityFailure, .unreadable)
        }
        XCTAssertThrowsError(try inspector.readRecord(at: file)) {
            XCTAssertEqual($0 as? ContinuityFailure, .unreadable)
        }
        var io = SessionFileIO()
        io.beforeList = { url in throw SessionDataError.filesystem(url, code: EIO) }
        XCTAssertThrowsError(try ContinuityInspector(paths: world.paths, io: io).capture(profile: world.source)) {
            XCTAssertEqual($0 as? ContinuityFailure, .unreadable)
        }
    }

    func testDiskErrorsDifferFromBadJSONAndNullFieldsUseAbsentDefaults() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let inspector = ContinuityInspector(paths: world.paths)
        let file = world.sourceBucket.appending(path: "local_missing.json")
        XCTAssertThrowsError(try inspector.readRecord(at: file)) { XCTAssertEqual($0 as? ContinuityFailure, .unreadable) }
        try AtomicFile.write(Data("{".utf8), to: file)
        XCTAssertThrowsError(try inspector.readRecord(at: file)) { XCTAssertEqual($0 as? ContinuityFailure, .invalidRecord) }
        try AtomicFile.write(Data(#"{"sessionId":"local_missing","cliSessionId":null,"cwd":null,"worktreePath":null,"lastFocusedAt":null,"lastActivityAt":null,"isArchived":null,"transcriptUnavailable":null}"#.utf8), to: file)
        XCTAssertEqual(try inspector.readRecord(at: file), ContinuityRecord(sessionID: "local_missing", cliSessionID: "", cwd: "",
            lastFocusedAt: 0, lastActivityAt: 0))
        XCTAssertNotNil(try inspector.capture(profile: world.source))
        try modifyJSON(file) { $0["sessionId"] = NSNull() }
        XCTAssertThrowsError(try inspector.readRecord(at: file)) { XCTAssertEqual($0 as? ContinuityFailure, .invalidRecord) }
    }

    private func prepare(_ world: SessionTestWorld) throws -> (ContinuityInspector, ContinuityCapture, AccountIdentity, URL, URL) {
        let project = world.scratch.root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try writeSession(world.sourceBucket, "one", fields: ["cliSessionId": "cli-one", "cwd": project.path,
            "lastFocusedAt": 100, "lastActivityAt": 200])
        let inspector = ContinuityInspector(paths: world.paths)
        let capture = try XCTUnwrap(inspector.capture(profile: world.source))
        let report = SessionSync().sync(try SyncPlan(source: world.source, target: world.target))
        XCTAssertTrue(report.errors.isEmpty)
        let transcript = world.paths.claudeCLIHome.appending(path: "projects/project/cli-one.jsonl")
        try AtomicFile.write(Data(#"{"type":"user","sessionId":"cli-one"}"#.utf8), to: transcript)
        let identity = AccountIdentity(accountUUID: "account-b", activeOrganizationUUID: "org-b")
        return (inspector, capture, identity, world.targetBucket.appending(path: "local_one.json"), transcript)
    }

    func testCaptureFocusThenActivityThenStableIDTieRules() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let inspector = ContinuityInspector(paths: world.paths)
        XCTAssertNil(try inspector.capture(profile: world.source))
        try writeSession(world.sourceBucket, "background", fields: ["lastFocusedAt": 1, "lastActivityAt": 9999])
        try writeSession(world.sourceBucket, "b", fields: ["lastFocusedAt": 100, "lastActivityAt": 200])
        XCTAssertEqual(try inspector.capture(profile: world.source)?.record.sessionID, "local_b")
        try writeSession(world.sourceBucket, "a", fields: ["lastFocusedAt": 100, "lastActivityAt": 201])
        XCTAssertEqual(try inspector.capture(profile: world.source)?.record.sessionID, "local_a")
        try writeSession(world.sourceBucket, "b", fields: ["lastFocusedAt": 100, "lastActivityAt": 201])
        XCTAssertEqual(try inspector.capture(profile: world.source)?.record.sessionID, "local_a")
        let outside = world.source.url.appending(path: "claude-code-sessions/account-a/other-org")
        try writeSession(outside, "outside", fields: ["lastFocusedAt": 9999])
        XCTAssertEqual(try inspector.capture(profile: world.source)?.record.sessionID, "local_a")
        let malformed = try writeSession(world.sourceBucket, "malformed")
        try modifyJSON(malformed) { $0["sessionId"] = "different" }
        XCTAssertThrowsError(try inspector.capture(profile: world.source)) {
            XCTAssertEqual($0 as? ContinuityFailure, .invalidRecord)
        }
        var unknown = world.source
        unknown.status = .signedIn(AccountIdentity(accountUUID: "account-a"))
        XCTAssertThrowsError(try inspector.capture(profile: unknown)) {
            XCTAssertEqual($0 as? ContinuityFailure, .identityUnavailable)
        }
    }

    func testCaptureRejectsMalformedTypesIDsAndNonRegularRecords() throws {
        for kind in 0..<5 {
            let world = try SessionTestWorld()
            defer { world.cleanup() }
            let file = try writeSession(world.sourceBucket, "bad")
            if kind == 0 { try AtomicFile.write(Data("{".utf8), to: file) }
            if kind == 1 { try modifyJSON(file) { $0["lastFocusedAt"] = "100" } }
            if kind == 2 { try modifyJSON(file) { $0["isArchived"] = 1 } }
            if kind == 3 {
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            }
            if kind == 4 {
                try FileManager.default.removeItem(at: file)
                try writeSession(world.sourceBucket, "invalid_id")
            }
            XCTAssertThrowsError(try ContinuityInspector(paths: world.paths).capture(profile: world.source))
        }
    }

    func testTargetRecordValidationFailures() throws {
        let mutations: [(ContinuityFailure, (inout [String: Any]) -> Void)] = [
            (.sessionMismatch, { $0["cliSessionId"] = "different" }),
            (.invalidRecord, { $0["sessionId"] = "local_different" }),
            (.archived, { $0["isArchived"] = true }),
            (.projectMissing, { $0["cwd"] = "missing-fixture-project" }),
            (.projectMissing, { $0["worktreePath"] = "missing-fixture-worktree" }),
            (.transcriptUnavailable, { $0["transcriptUnavailable"] = true }),
            (.invalidRecord, { $0["transcriptUnavailable"] = "true" }),
        ]
        for (expected, mutate) in mutations {
            let world = try SessionTestWorld()
            defer { world.cleanup() }
            let (inspector, capture, identity, file, _) = try prepare(world)
            try modifyJSON(file, mutate)
            XCTAssertThrowsError(try inspector.validateTarget(capture, profile: world.target, expectedIdentity: identity)) {
                XCTAssertEqual($0 as? ContinuityFailure, expected)
            }
        }
    }

    func testTargetIdentityMissingRecordAndCLIIdentifierFailures() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let (inspector, capture, identity, file, _) = try prepare(world)
        let wrongAccount = AccountIdentity(accountUUID: "changed", activeOrganizationUUID: "org-b")
        let wrongOrg = AccountIdentity(accountUUID: "account-b", activeOrganizationUUID: "changed")
        for expected in [wrongAccount, wrongOrg] {
            XCTAssertThrowsError(try inspector.validateTarget(capture, profile: world.target, expectedIdentity: expected)) {
                XCTAssertEqual($0 as? ContinuityFailure, .identityChanged)
            }
        }
        var signedOut = world.target
        signedOut.status = .signedOut(lastAccountUUID: "account-b")
        XCTAssertThrowsError(try inspector.validateTarget(capture, profile: signedOut, expectedIdentity: identity)) {
            XCTAssertEqual($0 as? ContinuityFailure, .identityUnavailable)
        }
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try inspector.validateTarget(capture, profile: world.target, expectedIdentity: identity)) {
            XCTAssertEqual($0 as? ContinuityFailure, .missingRecord)
        }
        for invalid in ["../escape", "bad_id", String(repeating: "a", count: 65), ""] {
            let original = world.sourceBucket.appending(path: "local_one.json")
            try modifyJSON(original) { $0["cliSessionId"] = invalid }
            let badCapture = try XCTUnwrap(inspector.capture(profile: world.source))
            try AtomicFile.write(AtomicFile.read(original), to: file)
            XCTAssertThrowsError(try inspector.validateTarget(badCapture, profile: world.target, expectedIdentity: identity)) {
                XCTAssertEqual($0 as? ContinuityFailure, .invalidCLIIdentifier)
            }
        }
    }

    func testWorktreeTakesPrecedenceAndTranscriptAcceptsOnlyMatchingConversationRows() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let (inspector, capture, identity, file, transcript) = try prepare(world)
        let project = world.scratch.root.appending(path: "project")
        try modifyJSON(file) { $0["cwd"] = world.scratch.root.appending(path: "missing-project").path; $0["worktreePath"] = project.path }
        XCTAssertNoThrow(try inspector.validateTarget(capture, profile: world.target, expectedIdentity: identity))
        for invalid in [#"{"type":"user","sessionId":"different"}"#,
                        #"{"type":"system","sessionId":"cli-one"}"#, "malformed"] {
            try AtomicFile.write(Data(invalid.utf8), to: transcript)
            XCTAssertThrowsError(try inspector.validateTarget(capture, profile: world.target, expectedIdentity: identity)) {
                XCTAssertEqual($0 as? ContinuityFailure, .transcriptMissing)
            }
        }
        try AtomicFile.write(Data(("bad line\n" + #"{"type":"assistant","sessionId":"cli-one"}"#).utf8), to: transcript)
        XCTAssertNoThrow(try inspector.validateTarget(capture, profile: world.target, expectedIdentity: identity))
        try FileManager.default.removeItem(at: transcript)
        XCTAssertThrowsError(try inspector.validateTarget(capture, profile: world.target, expectedIdentity: identity)) {
            XCTAssertEqual($0 as? ContinuityFailure, .transcriptMissing)
        }
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: true)
        XCTAssertThrowsError(try inspector.validateTarget(capture, profile: world.target, expectedIdentity: identity)) {
            XCTAssertEqual($0 as? ContinuityFailure, .transcriptUnreadable)
        }
    }

    func testTranscriptLargeLinesAndHardLimit() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let (inspector, capture, identity, _, transcript) = try prepare(world)
        let prefix = Data(#"{"type":"user","sessionId":"cli-one","text":""#.utf8)
        let suffix = Data(#""}"#.utf8)
        for size in [70_000, ContinuityInspector.maximumTranscriptLine] {
            var line = prefix
            line.append(Data(repeating: 97, count: size - prefix.count - suffix.count))
            line.append(suffix)
            try AtomicFile.write(line, to: transcript)
            XCTAssertNoThrow(try inspector.validateTarget(capture, profile: world.target, expectedIdentity: identity))
        }
        try AtomicFile.write(Data(repeating: 97, count: ContinuityInspector.maximumTranscriptLine + 1), to: transcript)
        XCTAssertThrowsError(try inspector.validateTarget(capture, profile: world.target, expectedIdentity: identity)) {
            XCTAssertEqual($0 as? ContinuityFailure, .transcriptLineTooLong)
        }
    }

    func testConfirmationUsesValidatedTargetBaselineFreshnessIDsAndRunningIdentity() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let (inspector, capture, identity, file, _) = try prepare(world)
        try modifyJSON(file) { $0["lastFocusedAt"] = 500 }
        let target = try inspector.validateTarget(capture, profile: world.target, expectedIdentity: identity)
        func confirmed(_ record: ContinuityRecord?, running: Bool = true) -> Bool {
            ContinuityInspector.isConfirmed(current: record, captured: target, launchThreshold: 1000,
                                             targetRunningWithUnchangedIdentity: running)
        }
        var current = target.record
        XCTAssertFalse(confirmed(current))
        XCTAssertFalse(confirmed(nil))
        current.lastFocusedAt = 999
        XCTAssertFalse(confirmed(current))
        current.lastFocusedAt = 1000
        XCTAssertTrue(confirmed(current))
        XCTAssertFalse(confirmed(current, running: false))
        current.isArchived = true
        XCTAssertFalse(confirmed(current))
        current.isArchived = false
        current.cliSessionID = "different"
        XCTAssertFalse(confirmed(current))
        current.cliSessionID = target.record.cliSessionID
        current.sessionID = "local_different"
        XCTAssertFalse(confirmed(current))
        var baseline = target.record
        baseline.lastFocusedAt = 1000
        let sameFocus = ContinuityTarget(record: baseline, identity: identity)
        XCTAssertFalse(ContinuityInspector.isConfirmed(current: baseline, captured: sameFocus,
            launchThreshold: 1000, targetRunningWithUnchangedIdentity: true))
    }
}
