import XCTest
@testable import CompanionCore

final class AtomicFileTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appending(path: "cc-relay-atomic-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testWriteCreatesParentsWithOwnerOnlyPermissionsAndReplacesAtomically() throws {
        let file = scratch
            .appending(path: "nested", directoryHint: .isDirectory)
            .appending(path: "state.json")
        let payload = Data(repeating: 0x61, count: 200_000)
        try AtomicFile.write(payload, to: file)
        XCTAssertEqual(try AtomicFile.read(file), payload)
        XCTAssertEqual(try posixMode(of: file), 0o600)
        XCTAssertEqual(try posixMode(of: file.deletingLastPathComponent()), 0o700)

        try AtomicFile.write(Data("next".utf8), to: file, permissions: 0o640)
        XCTAssertEqual(try AtomicFile.read(file), Data("next".utf8))
        XCTAssertEqual(try posixMode(of: file), 0o640)

        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["state.json"])
        XCTAssertFalse(names.contains { $0.contains(".tmp") })
    }

    func testFailedReplaceLeavesNoTemporaryFile() throws {
        let parent = scratch.appending(path: "parent", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appending(path: "blocked")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        XCTAssertThrowsError(try AtomicFile.write(Data("nope".utf8), to: destination))
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        XCTAssertEqual(names, ["blocked"])
    }

    func testReadErrors() throws {
        let missing = scratch.appending(path: "missing.json")
        XCTAssertThrowsError(try AtomicFile.read(missing)) { error in
            guard case AtomicFileError.notFound = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertThrowsError(try AtomicFile.read(scratch)) { error in
            guard case AtomicFileError.notRegularFile = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testRefusesConfigJSONUnderTheAppDataDirectory() throws {
        let appData = scratch.appending(path: "CC-Relay", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
        let forbidden = appData.appending(path: "nested").appending(path: "Config.JSON")
        XCTAssertThrowsError(try AtomicFile.write(Data("{}".utf8), to: forbidden, protectedRoot: appData)) { error in
            guard case AtomicFileError.refusedConfigJSON = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: forbidden.path))
        let nested = appData.appending(path: "nested")
        if FileManager.default.fileExists(atPath: nested.path) {
            let names = try FileManager.default.contentsOfDirectory(atPath: nested.path)
            XCTAssertFalse(names.contains { $0.contains(".tmp") || $0.lowercased() == "config.json" })
        }

        let otherRoot = scratch.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let protected = otherRoot.appending(path: "config.json")
        XCTAssertThrowsError(try AtomicFile.write(Data("{}".utf8), to: protected, protectedRoot: otherRoot))

        let allowed = scratch.appending(path: "config.json")
        try AtomicFile.write(Data("{}".utf8), to: allowed)
        XCTAssertEqual(try AtomicFile.read(allowed), Data("{}".utf8))
    }

    func testConfigJSONOutsideAppDataDirectoryIsWritable() throws {
        let root = scratch
            .appending(path: "CC-Relay", directoryHint: .isDirectory)
            .appending(path: "sandbox", directoryHint: .isDirectory)
            .appending(path: "home", directoryHint: .isDirectory)
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Claude_204", directoryHint: .isDirectory)
        let destination = root.appending(path: "config.json")
        XCTAssertNoThrow(try AtomicFile.write(Data("{}".utf8), to: destination))
        XCTAssertEqual(try AtomicFile.read(destination), Data("{}".utf8))
    }
}
