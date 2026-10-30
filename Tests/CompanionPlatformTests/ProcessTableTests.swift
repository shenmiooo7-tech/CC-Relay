import Darwin
import Foundation
import XCTest
@testable import CompanionPlatform

final class ProcessTableTests: XCTestCase {
    func testFilteredWholeTableScanTakesUnder100Milliseconds() throws {
        let own = try XCTUnwrap(ProcessTable().record(pid: getpid())).executableURL
        let started = ContinuousClock.now
        let records = ProcessTable().processes(matching: { $0 == own })
        let elapsed = started.duration(to: .now)
        XCTAssertTrue(records.contains { $0.pid == getpid() })
        XCTAssertTrue(records.allSatisfy { $0.executableURL == own })
        XCTAssertLessThan(elapsed, .milliseconds(100))
        XCTAssertEqual(ProcessTable().processes(matching: { _ in false }), [])
    }

    func testFindsThisTestProcess() throws {
        let record = try XCTUnwrap(ProcessTable().processes().first { $0.pid == getpid() })
        XCTAssertEqual(record.ppid, getppid())
        XCTAssertEqual(record.argv, ProcessInfo.processInfo.arguments)
        XCTAssertTrue(record.executableURL.isFileURL)
        XCTAssertLessThanOrEqual(record.startedAt, Date())
        XCTAssertGreaterThan(record.startedAt.timeIntervalSince1970, 0)
    }

    func testCopiedSleepWithSpacedExecutableHasExactArgvAndStartTime() throws {
        let directory = try PlatformTestDirectory()
        defer { directory.remove() }
        let folder = directory.root.appendingPathComponent("with space", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let executable = folder.appendingPathComponent("sleep")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        let before = Date()
        try process.run()
        defer {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        let record = try XCTUnwrap(ProcessTable().record(pid: process.processIdentifier))
        XCTAssertEqual(record.pid, process.processIdentifier)
        XCTAssertEqual(record.ppid, getpid())
        XCTAssertEqual(record.argv, [executable.path, "30"])
        XCTAssertEqual(record.executableURL.resolvingSymlinksInPath(), executable.resolvingSymlinksInPath())
        XCTAssertGreaterThanOrEqual(record.startedAt, before.addingTimeInterval(-0.1))
        XCTAssertLessThanOrEqual(record.startedAt, Date())
    }

    func testInvalidPIDsAreSkipped() {
        XCTAssertNil(ProcessTable().record(pid: -1))
        XCTAssertNil(ProcessTable().record(pid: 0))
        XCTAssertNil(ProcessTable().record(pid: Int32.max))
    }

    func testArgumentDecoderStopsBeforeEnvironmentAndPreservesEmptyArguments() {
        let argv = ["/some path/program", "--user-data-dir=/profile with spaces", "", "last"]
        let data = procargs(argv: argv, environment: ["SECRET=not-an-argument", "--user-data-dir=/wrong"])
        XCTAssertEqual(ProcessTable.parseArguments(data), argv)
    }

    func testMalformedArgumentBuffersAreRejected() {
        XCTAssertNil(ProcessTable.parseArguments(Data()))
        XCTAssertNil(ProcessTable.parseArguments(procargs(argv: [], environment: [])))
        var negative: Int32 = -1
        var negativeData = withUnsafeBytes(of: &negative) { Data($0) }
        negativeData.append(contentsOf: [1, 0, 1, 0])
        XCTAssertNil(ProcessTable.parseArguments(negativeData))
        var missingTerminator = procargs(argv: ["program", "argument"], environment: [])
        missingTerminator.removeLast()
        XCTAssertNil(ProcessTable.parseArguments(missingTerminator))
        var argc: Int32 = 1
        var invalidUTF8 = withUnsafeBytes(of: &argc) { Data($0) }
        invalidUTF8.append(contentsOf: [47, 120, 0, 0, 0xff, 0])
        XCTAssertNil(ProcessTable.parseArguments(invalidUTF8))
        var missingExecutableEnd = withUnsafeBytes(of: &argc) { Data($0) }
        missingExecutableEnd.append(contentsOf: [47, 120])
        XCTAssertNil(ProcessTable.parseArguments(missingExecutableEnd))
    }

    private func procargs(argv: [String], environment: [String]) -> Data {
        var count = Int32(argv.count)
        var data = withUnsafeBytes(of: &count) { Data($0) }
        data.append(contentsOf: Array("/exec path".utf8) + [0, 0, 0, 0])
        for string in argv + environment {
            data.append(contentsOf: string.utf8)
            data.append(0)
        }
        return data
    }
}
