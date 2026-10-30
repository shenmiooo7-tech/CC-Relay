import XCTest
import CompanionPlatform
import Darwin
import Foundation

final class FakeClaudeEndToEndTests: XCTestCase {
    func testPlatformModuleLoads() {
        _ = CompanionPlatformModule.self
    }

    func testLaunchWithSpacedProfileRecordsDeepLinksAndQuitsOnTerm() throws {
        let harness = try FakeClaudeHarness.launch(
            extraArguments: ["--ignore-gpu-blocklist", "claude://focus/1", "claude://focus/2"],
            environment: [:]
        )
        defer { harness.stopIfNeeded() }

        let instance = try harness.waitForInstance()
        XCTAssertEqual(instance.pid, harness.process.processIdentifier)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: instance.startedAt))
        XCTAssertTrue(instance.argv.contains("--user-data-dir=\(harness.profile.path)"))
        XCTAssertTrue(instance.argv.contains("--ignore-gpu-blocklist"))
        XCTAssertEqual(
            try String(contentsOf: harness.deeplinks, encoding: .utf8),
            "claude://focus/1\nclaude://focus/2\n"
        )

        harness.process.terminate()
        try harness.waitUntilExited(timeout: 5)

        XCTAssertEqual(harness.process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.instance.path))
        let events = try String(contentsOf: harness.events, encoding: .utf8)
        let line = try XCTUnwrap(events.split(separator: "\n").first)
        XCTAssertTrue(line.hasPrefix("quit "))
        let stamp = line.dropFirst("quit ".count)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: String(stamp)))
    }

    func testQuitDelayHoldsTheProcessOpen() throws {
        let harness = try FakeClaudeHarness.launch(
            extraArguments: ["claude://focus/delayed"],
            environment: ["FAKE_CLAUDE_QUIT_DELAY_MS": "1000"]
        )
        defer { harness.stopIfNeeded() }
        _ = try harness.waitForInstance()

        let signaled = Date()
        harness.process.terminate()
        try harness.waitUntilExited(timeout: 5)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(signaled), 0.7)
        XCTAssertEqual(harness.process.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.events.path))
    }

    func testIgnoreTermKeepsTheProcessAliveUntilKilled() throws {
        let harness = try FakeClaudeHarness.launch(
            extraArguments: [],
            environment: ["FAKE_CLAUDE_IGNORE_TERM": "1"]
        )
        defer { harness.stopIfNeeded() }
        _ = try harness.waitForInstance()

        harness.process.terminate()
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(harness.process.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.instance.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.events.path))
    }
}

private struct InstanceRecord: Decodable {
    var pid: Int32
    var startedAt: String
    var argv: [String]
}

private final class FakeClaudeHarness {
    let process: Process
    let profile: URL
    let root: URL
    private let output: FileHandle

    var instance: URL { stateDirectory.appending(path: "instance.json") }
    var events: URL { stateDirectory.appending(path: "events.log") }
    var deeplinks: URL { stateDirectory.appending(path: "deeplinks.log") }

    private var stateDirectory: URL {
        profile.appending(path: ".fake-claude", directoryHint: .isDirectory)
    }

    static func launch(extraArguments: [String], environment: [String: String]) throws -> FakeClaudeHarness {
        let binary = try fakeClaudeBinary()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-relay-\(UUID().uuidString)", isDirectory: true)
        let profile = root.appendingPathComponent("profile dir", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let outputURL = root.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--user-data-dir=\(profile.path)"] + extraArguments
        process.currentDirectoryURL = root
        var childEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            childEnvironment[key] = value
        }
        process.environment = childEnvironment
        process.standardOutput = output
        process.standardError = output

        let harness = FakeClaudeHarness(process: process, profile: profile, root: root, output: output)
        do {
            try process.run()
        } catch {
            harness.stopIfNeeded()
            throw error
        }
        return harness
    }

    private init(process: Process, profile: URL, root: URL, output: FileHandle) {
        self.process = process
        self.profile = profile
        self.root = root
        self.output = output
    }

    func waitForInstance(timeout: TimeInterval = 30) throws -> InstanceRecord {
        var record: InstanceRecord?
        let appeared = waitUntil(timeout: timeout) {
            guard let data = try? Data(contentsOf: instance),
                  let decoded = try? JSONDecoder().decode(InstanceRecord.self, from: data),
                  decoded.pid == process.processIdentifier else { return false }
            record = decoded
            return true
        }
        guard appeared, let record else {
            stopIfNeeded()
            XCTFail("instance.json did not appear at \(instance.path). \(outputText())")
            throw CocoaError(.fileReadNoSuchFile)
        }
        return record
    }

    func waitUntilExited(timeout: TimeInterval) throws {
        let exited = waitUntil(timeout: timeout) { !process.isRunning }
        if !exited {
            let captured = outputText()
            stopIfNeeded()
            XCTFail("FakeClaude did not exit. \(captured)")
            throw CocoaError(.fileReadUnknown)
        }
        process.waitUntilExit()
    }

    func stopIfNeeded() {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        try? output.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    private func outputText() -> String {
        (try? String(contentsOf: root.appendingPathComponent("output.log"), encoding: .utf8)) ?? ""
    }
}

private func fakeClaudeBinary() throws -> URL {
    let products = Bundle(for: FakeClaudeEndToEndTests.self).bundleURL.deletingLastPathComponent()
    let binary = products.appending(path: "FakeClaude")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
        XCTFail("FakeClaude is missing at \(binary.path). scripts/test.sh builds it next to the test bundle.")
        throw CocoaError(.fileReadNoSuchFile)
    }
    return binary
}
