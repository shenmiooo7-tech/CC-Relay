import XCTest
@testable import CompanionCore

final class ClaudeAppLocationTests: XCTestCase {
    private var scratch: ScratchDirectory!

    override func setUpWithError() throws {
        scratch = try ScratchDirectory()
    }

    override func tearDown() {
        scratch?.cleanup()
    }

    func testTheUsualPlaceComesFirst() throws {
        let usual = try bundle("Applications/Claude.app", identifier: ClaudeAppLocation.bundleIdentifier)
        let elsewhere = try bundle("home/Applications/Claude.app", identifier: ClaudeAppLocation.bundleIdentifier)
        XCTAssertEqual(ClaudeAppLocation.resolve([usual, elsewhere]), usual)
    }

    func testAClaudeInAnotherFolderOrUnderAnotherNameIsFound() throws {
        let usual = scratch.root.appending(path: "Applications/Claude.app")
        let renamed = try bundle("home/Applications/Claude 2.app", identifier: ClaudeAppLocation.bundleIdentifier)
        XCTAssertEqual(ClaudeAppLocation.resolve([usual, renamed]), renamed)
    }

    func testAnotherAppInTheUsualPlaceIsNotTakenForClaude() throws {
        let impostor = try bundle("Applications/Claude.app", identifier: "com.example.notes")
        let real = try bundle("home/Applications/Claude.app", identifier: ClaudeAppLocation.bundleIdentifier)
        XCTAssertEqual(ClaudeAppLocation.resolve([impostor, real]), real)
        XCTAssertNil(ClaudeAppLocation.resolve([impostor, nil]))
    }

    func testNothingFoundIsNil() throws {
        let unreadable = scratch.root.appending(path: "Applications/Claude.app/Contents")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try Data("not a property list".utf8).write(to: unreadable.appending(path: "Info.plist"))
        XCTAssertNil(ClaudeAppLocation.resolve([scratch.root.appending(path: "Applications/Claude.app"), nil]))
        XCTAssertNil(ClaudeAppLocation.resolve([]))
    }

    private func bundle(_ path: String, identifier: String) throws -> URL {
        let app = scratch.root.appending(path: path, directoryHint: .isDirectory)
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier],
                                                      format: .xml, options: 0)
        try info.write(to: contents.appending(path: "Info.plist"))
        return app
    }
}
