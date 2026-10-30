import XCTest
@testable import CompanionCore

final class CompanionLogTests: XCTestCase {
    private var scratch: ScratchDirectory!

    override func setUpWithError() throws {
        scratch = try ScratchDirectory()
    }

    override func tearDownWithError() throws {
        scratch.cleanup()
    }

    func testScrubsTheLineAndRotatesAtTheThreshold() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_792_832_402.345))
        let log = CompanionLog(paths: scratch.paths, clock: clock, rotationThreshold: 20)
        log.info(.`switch`, "FIRST-MARKER dan@example.com 12345678-1234-1234-1234-123456789abc")
        log.warning(.quota, "SECOND-MARKER")
        log.error(.backup, "THIRD-MARKER")

        let directory = scratch.paths.companionDataDirectory.appending(path: "Logs")
        let current = try String(contentsOf: directory.appending(path: "cc-relay.log"), encoding: .utf8)
        let first = try String(contentsOf: directory.appending(path: "cc-relay.log.1"), encoding: .utf8)
        let second = try String(contentsOf: directory.appending(path: "cc-relay.log.2"), encoding: .utf8)
        XCTAssertTrue(second.contains("FIRST-MARKER"))
        XCTAssertTrue(first.contains("SECOND-MARKER"))
        XCTAssertTrue(current.contains("THIRD-MARKER"))
        XCTAssertTrue(second.contains("2026-10-24T09:00:02.345Z INFO switch"))
        XCTAssertTrue(second.contains("d\u{2022}\u{2022}\u{2022}@example.com"))
        XCTAssertTrue(second.contains("12345678\u{2026}"))
        XCTAssertFalse(second.contains("dan@example.com"))
        XCTAssertFalse(second.contains("12345678-1234-1234-1234-123456789abc"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "cc-relay.log.3").path))
        XCTAssertEqual(try posixMode(of: directory.appending(path: "cc-relay.log")), 0o600)
    }
}
