import XCTest
@testable import CompanionCore

final class ArchiveIndexTests: XCTestCase {
    func testNullArchiveFlagPreservesMembershipAndAllowsOtherUpdates() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let index = world.targetBucket.appending(path: "archived-sessions.idx")
        try AtomicFile.write(Data(#"{"v":1,"archived":["local_keep"]}"#.utf8), to: index)
        for id in ["keep", "unlisted"] { try writeSession(world.targetBucket, id, fields: ["isArchived": NSNull()]) }
        try writeSession(world.targetBucket, "new", fields: ["isArchived": true])
        XCTAssertEqual(try ArchiveIndexRebuilder().rebuild(bucket: world.targetBucket), .rewritten)
        XCTAssertEqual(try AtomicFile.read(index), Data(#"{"v":1,"archived":["local_keep","local_new"]}"#.utf8))
    }

    func testTrueFalseAbsentAndByteExactSortedOutputWithUnknownFields() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let bucket = world.targetBucket
        let index = bucket.appending(path: "archived-sessions.idx")
        try AtomicFile.write(Data(#"{"v":1,"archived":["local_old","local_false","local_keep"],"z":{"k":1},"a":true}"#.utf8), to: index, permissions: 0o640)
        try writeSession(bucket, "z", fields: ["isArchived": true])
        try writeSession(bucket, "a", fields: ["isArchived": true])
        try writeSession(bucket, "false", fields: ["isArchived": false])
        let keep = try writeSession(bucket, "keep")
        try modifyJSON(keep) { $0.removeValue(forKey: "isArchived") }
        XCTAssertEqual(try ArchiveIndexRebuilder().rebuild(bucket: bucket), .rewritten)
        XCTAssertEqual(try AtomicFile.read(index), Data(#"{"v":1,"archived":["local_a","local_keep","local_z"],"a":true,"z":{"k":1}}"#.utf8))
        XCTAssertEqual(try posixMode(of: index), 0o640)
        try setFileTime(index, seconds: 123)
        XCTAssertEqual(try ArchiveIndexRebuilder().rebuild(bucket: bucket), .unchanged)
        XCTAssertEqual(try SessionFileIO().info(index)?.st_mtimespec.tv_sec, 123)
        try assertNoStages(world.scratch.root)
    }

    func testUnsupportedMalformedAndNonRegularInputsNeverRewrite() throws {
        for broken in [#"{"v":2,"archived":[]}"#, #"{"v":true,"archived":[]}"#, #"{"v":1,"archived":[1]}"#, "{"] {
            let world = try SessionTestWorld()
            defer { world.cleanup() }
            let index = world.targetBucket.appending(path: "archived-sessions.idx")
            try AtomicFile.write(Data(broken.utf8), to: index)
            try writeSession(world.targetBucket, "archived", fields: ["isArchived": true])
            XCTAssertThrowsError(try ArchiveIndexRebuilder().rebuild(bucket: world.targetBucket))
            XCTAssertEqual(try AtomicFile.read(index), Data(broken.utf8))
        }
        for kind in 0..<4 {
            let world = try SessionTestWorld()
            defer { world.cleanup() }
            let file = try writeSession(world.targetBucket, "bad")
            if kind == 0 { try AtomicFile.write(Data("{".utf8), to: file) }
            if kind == 1 { try modifyJSON(file) { $0["sessionId"] = "wrong" } }
            if kind == 2 { try modifyJSON(file) { $0["isArchived"] = 1 } }
            if kind == 3 {
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            }
            let index = world.targetBucket.appending(path: "archived-sessions.idx")
            let original = try AtomicFile.read(index)
            XCTAssertThrowsError(try ArchiveIndexRebuilder().rebuild(bucket: world.targetBucket))
            XCTAssertEqual(try AtomicFile.read(index), original)
        }
    }

    func testEmptyLegacyAndNewIndexDefaultPermissions() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let index = world.targetBucket.appending(path: "archived-sessions.idx")
        try FileManager.default.removeItem(at: index)
        XCTAssertEqual(try ArchiveIndexRebuilder().rebuild(bucket: world.targetBucket), .unchanged)
        let legacy = try writeSession(world.targetBucket, "legacy")
        try modifyJSON(legacy) { $0.removeValue(forKey: "isArchived") }
        XCTAssertEqual(try ArchiveIndexRebuilder().rebuild(bucket: world.targetBucket), .unchanged)
        try writeSession(world.targetBucket, "new", fields: ["isArchived": true])
        XCTAssertEqual(try ArchiveIndexRebuilder().rebuild(bucket: world.targetBucket), .rewritten)
        XCTAssertEqual(try AtomicFile.read(index), Data(#"{"v":1,"archived":["local_new"]}"#.utf8))
        XCTAssertEqual(try posixMode(of: index), 0o600)
    }

    func testSupportedNoncanonicalIndexIsNormalizedOnce() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let index = world.targetBucket.appending(path: "archived-sessions.idx")
        try writeSession(world.targetBucket, "a", fields: ["isArchived": true])
        try writeSession(world.targetBucket, "z", fields: ["isArchived": true])
        try AtomicFile.write(Data("{ \"archived\":[\"local_z\",\"local_a\",\"local_a\"],\"v\":1 }\n".utf8), to: index)
        XCTAssertEqual(try ArchiveIndexRebuilder().rebuild(bucket: world.targetBucket), .rewritten)
        XCTAssertEqual(try AtomicFile.read(index), Data(#"{"v":1,"archived":["local_a","local_z"]}"#.utf8))
        XCTAssertEqual(try ArchiveIndexRebuilder().rebuild(bucket: world.targetBucket), .unchanged)
    }
}
