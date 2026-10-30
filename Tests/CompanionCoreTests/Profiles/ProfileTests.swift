import Darwin
import XCTest
@testable import CompanionCore

final class ProfileTests: XCTestCase {
    func testUnreadableCandidateDoesNotHideOtherProfiles() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let candidate = world.paths.claudeProfilesRoot.appending(path: "Claude_X")
        try FileManager.default.moveItem(at: world.source.url, to: candidate)
        defer { _ = chmod(candidate.path, 0o700) }
        XCTAssertEqual(chmod(candidate.path, 0), 0)
        let scan = try ProfileScanner(paths: world.paths).scan()
        XCTAssertEqual(scan.profiles.first { $0.folder.name == "Claude_X" }?.status, .unreadable(reason: .unreadableDirectory))
        XCTAssertEqual(scan.profiles.first { $0.folder == world.target.folder }?.status, world.target.status)
    }

    func testCandidateStatErrorsAreIsolatedAndNonCandidatesAreSkipped() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let sibling = world.paths.claudeProfilesRoot.appending(path: "Unrelated")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        for failurePath in [world.source.url.path, world.source.url.appending(path: "config.json").path] {
            var io = SessionFileIO()
            io.beforeInfo = { url in
                if url.path == failurePath || url.path == sibling.path { throw SessionDataError.filesystem(url, code: EIO) }
            }
            let scan = try ProfileScanner(paths: world.paths, io: io).scan()
            XCTAssertEqual(scan.profiles.count, 2)
            XCTAssertEqual(scan.profiles[0].status, .unreadable(reason: .unreadableDirectory))
            XCTAssertEqual(scan.profiles[1].status, world.target.status)
        }
    }

    func testBadInventoryKeepsSignedInIdentityButCannotClassifyAnAccountlessProfile() throws {
        for wrongType in [false, true] {
            let world = try SessionTestWorld()
            defer { world.cleanup() }
            var io = SessionFileIO()
            if wrongType {
                let tree = world.source.url.appending(path: "claude-code-sessions")
                try FileManager.default.removeItem(at: tree)
                try AtomicFile.write(Data(), to: tree)
            } else {
                let bucketPath = world.sourceBucket.path
                io.beforeList = { url in
                    if url.path == bucketPath { throw SessionDataError.filesystem(url, code: EACCES) }
                }
            }
            let scanner = ProfileScanner(paths: world.paths, io: io)
            var scan = try scanner.scan()
            XCTAssertEqual(scan.profiles[0].status, world.source.status)
            XCTAssertEqual(scan.profiles[0].readableBucket, world.source.readableBucket)
            XCTAssertNil(scan.inventory[world.source.folder])
            XCTAssertNil(scan.accountDirectories[world.source.folder])
            let config = world.source.url.appending(path: "config.json")
            try modifyJSON(config) { $0.removeValue(forKey: "lastKnownAccountUuid") }
            scan = try scanner.scan()
            XCTAssertEqual(scan.profiles[0].status, .unreadable(reason: .unreadableDirectory))
            try AtomicFile.write(Data("{".utf8), to: config)
            scan = try scanner.scan()
            XCTAssertEqual(scan.profiles[0].status, .unreadable(reason: .configUnparsable))
        }
    }

    func testConfigSelectionAndSecretValuesAreNotDecoded() throws {
        let data = Data(#"{"lastKnownAccountUuid":"account","updaterLastSeenVersion":"2.1","oauth:tokenCacheV2":{"anything":[1,true,{}]},"dxt:allowlistLastUpdated:z":"2026-10-24T10:00:00Z","dxt:allowlistLastUpdated:b":"2026-10-24T10:00:00.100Z","dxt:allowlistLastUpdated:a":"2026-10-24T10:00:00.100Z","dxt:allowlistLastUpdated:bad":"not-a-stamp","dxt:allowlistLastUpdated:typed":false,"dxt:allowlistLastUpdated:":"2026-10-25T00:00:00Z"}"#.utf8)
        let config = try ProfileConfigReader().parse(data)
        XCTAssertEqual(config.accountUUID, "account")
        XCTAssertEqual(config.updaterLastSeenVersion, "2.1")
        XCTAssertEqual(config.activeOrganizationUUID, "a")
        XCTAssertEqual(config.knownOrganizationUUIDs, ["a", "b", "bad", "typed", "z"])
        XCTAssertEqual(config.organizationStamps.count, 4)
        let none = try ProfileConfigReader().parse(Data(#"{"lastKnownAccountUuid":"","dxt:allowlistLastUpdated:a":"20261024"}"#.utf8))
        XCTAssertNil(none.accountUUID)
        XCTAssertNil(none.activeOrganizationUUID)
        XCTAssertThrowsError(try ProfileConfigReader().parse(Data("[]".utf8)))
    }

    func testPlainTimestampOffsetAndInvalidValueSelection() throws {
        let config = try ProfileConfigReader().parse(Data(#"{"dxt:allowlistLastUpdated:a":"2026-10-24T11:00:00+01:00","dxt:allowlistLastUpdated:b":"2026-10-24T10:00:00Z","dxt:allowlistLastUpdated:c":"2026-10-24T09:59:59.999Z","dxt:allowlistLastUpdated:d":"2026-10-24T10:00:00Zjunk"}"#.utf8))
        XCTAssertEqual(config.activeOrganizationUUID, "a")
    }

    func testSubMillisecondOrderingCalendarValidationAndEquivalentFractions() throws {
        let precise = try ProfileConfigReader().parse(Data(#"{"dxt:allowlistLastUpdated:a":"2026-10-24T10:00:00.123456700Z","dxt:allowlistLastUpdated:z":"2026-10-24T10:00:00.123456701Z","dxt:allowlistLastUpdated:bad":"2026-02-30T10:00:00Z","dxt:allowlistLastUpdated:overflow":"2026-10-24T24:00:00Z"}"#.utf8))
        XCTAssertEqual(precise.activeOrganizationUUID, "z")
        let tie = try ProfileConfigReader().parse(Data(#"{"dxt:allowlistLastUpdated:a":"2026-10-24T10:00:00.1200Z","dxt:allowlistLastUpdated:b":"2026-10-24T10:00:00.12Z"}"#.utf8))
        XCTAssertEqual(tie.activeOrganizationUUID, "a")
        let invalidOnly = try ProfileConfigReader().parse(Data(#"{"dxt:allowlistLastUpdated:bad":"2026-02-30T10:00:00Z"}"#.utf8))
        XCTAssertNil(invalidOnly.activeOrganizationUUID)
    }

    func testScannerStatesCandidatesDuplicatesAndInventory() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.cleanup() }
        let profiles: [ProfileSpec] = [
            .init(folder: "Claude", displayName: "Default", accountUUID: "shared", organizations: [
                .init(uuid: "org", allowlistUpdatedAt: "2026-10-24T10:00:00Z")], buckets: [
                    .init(accountUUID: "shared", organizationUUID: "org", sessions: [])]),
            .init(folder: "Claude_duplicate", displayName: "Duplicate", accountUUID: "shared"),
            .awaitingSignIn(folder: "Claude_", displayName: "Prefix"),
            .awaitingSignIn(folder: "Claude_awaiting", displayName: "Awaiting"),
            .init(folder: "Claude_out", displayName: "Out", buckets: [
                .init(accountUUID: "old", organizationUUID: "old-org", sessions: [])]),
            .init(folder: "Claude_bad", displayName: "Bad"),
            .init(folder: "Custom Login", displayName: "Imported", accountUUID: "custom"),
            .init(folder: "Claudeish", displayName: "Ignore"),
        ]
        let world = try SandboxFixture(profiles: profiles).materialize(at: scratch.root)
        let bucket = world.profileDirectory("Claude").appending(path: "claude-code-sessions/shared/org")
        try writeSession(bucket, "one", seconds: 200)
        try writeSession(bucket, "two", seconds: 300)
        try AtomicFile.write(Data("{".utf8), to: world.profileDirectory("Claude_bad").appending(path: "config.json"))
        let pending = try ProfileFolder("Pending Custom")
        try FileManager.default.createDirectory(at: world.profileDirectory(pending.name), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: world.profileDirectory("Claude_empty"), withIntermediateDirectories: true)
        try AtomicFile.write(Data("{}".utf8), to: world.paths.companionDataDirectory.appending(path: "config.json"))
        try FileManager.default.createSymbolicLink(at: world.profileDirectory("Claude_link"), withDestinationURL: world.profileDirectory("Claude"))
        let scan = try ProfileScanner(paths: world.paths).scan(managed: [try ProfileFolder("Custom Login"), try ProfileFolder("CC-Relay")], pending: [pending])
        XCTAssertEqual(scan.profiles.map(\.folder.name), ["Claude", "Claude_", "Claude_awaiting", "Claude_bad", "Claude_duplicate", "Claude_out", "Custom Login", "Pending Custom"])
        let keyed = Dictionary(uniqueKeysWithValues: scan.profiles.map { ($0.folder.name, $0) })
        XCTAssertEqual(keyed["Claude_awaiting"]?.status, .awaitingSignIn)
        XCTAssertEqual(keyed["Pending Custom"]?.status, .awaitingSignIn)
        XCTAssertEqual(keyed["Claude_out"]?.status, .signedOut(lastAccountUUID: "old"))
        XCTAssertEqual(keyed["Claude_bad"]?.status, .unreadable(reason: .configUnparsable))
        XCTAssertEqual(keyed["Claude"]?.duplicateOf?.name, "Claude_duplicate")
        XCTAssertEqual(keyed["Claude_duplicate"]?.duplicateOf?.name, "Claude")
        XCTAssertEqual(keyed["Claude"]?.readableBucket, try SessionBucket(accountUUID: "shared", organizationUUID: "org"))
        let inventory = try XCTUnwrap(scan.inventory[try ProfileFolder("Claude")]?.first)
        XCTAssertEqual(inventory.localRecordCount, 2)
        XCTAssertEqual(inventory.newestModification, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(scan.accountDirectories[try ProfileFolder("Claude_out")], ["old"])
    }

    func testSessionsWithoutConfigAndEmptyAccountDirectoryAreSignedOut() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        try FileManager.default.removeItem(at: world.source.url.appending(path: "config.json"))
        try FileManager.default.createDirectory(at: world.source.url.appending(path: "claude-code-sessions/empty-account"), withIntermediateDirectories: true)
        let scan = try ProfileScanner(paths: world.paths).scan()
        XCTAssertEqual(scan.profiles[0].status, .signedOut(lastAccountUUID: nil))
        XCTAssertNil(scan.profiles[0].readableBucket)
    }
}
