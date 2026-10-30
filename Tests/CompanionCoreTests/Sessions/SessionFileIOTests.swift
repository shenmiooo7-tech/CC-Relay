import Darwin
import XCTest
@testable import CompanionCore

final class SessionFileIOTests: XCTestCase {
    func testCreatedDirectoriesGetOwnerAccessDespiteUmask() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.cleanup() }
        for mask: mode_t in [0o177, 0o777] {
            let previous = umask(mask)
            defer { _ = umask(previous) }
            let parent = scratch.root.appending(path: "mask-\(mask)")
            let child = parent.appending(path: "nested")
            try SessionFileIO().makeDirectory(child)
            XCTAssertEqual(try posixMode(of: parent), 0o700)
            XCTAssertEqual(try posixMode(of: child), 0o700)
        }
        let existing = scratch.root.appending(path: "existing")
        try SessionFileIO().makeDirectory(existing)
        defer { _ = chmod(existing.path, 0o700) }
        XCTAssertEqual(chmod(existing.path, 0o500), 0)
        try SessionFileIO().makeDirectory(existing)
        XCTAssertEqual(try posixMode(of: existing), 0o500)
    }
}
