import CompanionCore
import Foundation
import XCTest

final class TaskGuardEvaluatorTests: XCTestCase {
    private let main = URL(fileURLWithPath: "/fixture/Claude.app/Contents/MacOS/Claude")
    private let start = Date(timeIntervalSince1970: 1_735_819_445.999)

    private func entry(_ pid: Int32, _ parent: Int32, _ path: String = "/bin/claude") -> ProcessEntry {
        ProcessEntry(pid: pid, ppid: parent, executableURL: URL(fileURLWithPath: path), startedAt: start)
    }

    private var tree: [ProcessEntry] { [entry(1, 0, "/sbin/launchd"), entry(10, 1, main.path), entry(20, 10)] }

    private func record(_ pid: Int32 = 20, status: String = "idle", procStart: String? = nil,
                        entrypoint: String = "claude-desktop") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["pid": pid, "status": status,
            "procStart": procStart ?? TaskGuardEvaluator.registryStartTime(start), "entrypoint": entrypoint,
            "sessionId": "fixture-session", "cwd": "/fixture/project"])
    }

    private func evaluate(_ processes: [ProcessEntry], _ loader: (Int32) throws -> Data?) -> TaskActivity {
        TaskGuardEvaluator.evaluate(processes: processes, claudeMainExecutable: main, registryLoader: loader)
    }

    func testBusyOrphanedHelperTasksRemainGuardedAfterTheMainExits() throws {
        let helperPath = main.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Frameworks/TaskFixture.app/Contents/MacOS/TaskFixture").path
        let helper = entry(11, 1, helperPath)
        let cli = entry(20, 11)
        for status in ["busy", "shell", "waiting"] {
            XCTAssertEqual(evaluate([helper, cli]) { try record($0, status: status) },
                .busy([CodeTaskInfo(pid: 20, sessionID: "fixture-session", workingDirectory: "/fixture/project", reason: .statusBusy)]))
        }
        XCTAssertEqual(evaluate([helper, cli]) { _ in nil }, .unknown(TaskUnknownReason.registryUnreadable))
        XCTAssertEqual(evaluate([entry(20, 1, "/fixture/Claude.app/Contents/Resources/claude")]) {
            try record($0, status: "busy")
        }, .busy([CodeTaskInfo(pid: 20, sessionID: "fixture-session", workingDirectory: "/fixture/project", reason: .statusBusy)]))
    }

    func testEmptyAndUnrelatedProcessesNeverReadRegistry() {
        for processes in [[], [entry(20, 1)], [entry(20, 99)], [entry(10, 1, main.path), entry(20, 1)]] {
            XCTAssertEqual(evaluate(processes) { _ in XCTFail("Unrelated registry lookup"); return nil }, .idle)
        }
    }

    func testIndirectAncestryAndPIDOneStop() throws {
        let processes = tree.filter { $0.pid != 20 } + [entry(11, 10, "/bin/node"), entry(20, 11)]
        XCTAssertEqual(evaluate(processes) { try record($0) }, .idle)
        let beyondInit = [entry(1, 10, "/sbin/launchd"), entry(10, 1, main.path), entry(20, 1)]
        XCTAssertEqual(evaluate(beyondInit) { _ in XCTFail(); return nil }, .idle)
        XCTAssertEqual(evaluate([entry(1, 0, main.path), entry(20, 1)]) { try record($0) }, .idle)
    }

    func testCyclesMissingParentsAndWrongMainNamesAreNotHosted() {
        for processes in [[entry(20, 21), entry(21, 20, "/bin/node")], [entry(20, 20)],
                          [entry(20, 11), entry(11, 99, "/bin/node")],
                          [entry(10, 1, "/fixture/Claude.app-other/helper"), entry(20, 10)],
                          [entry(10, 1, "/other/Claude.app/Contents/MacOS/Claude"), entry(20, 10)],
                          [entry(10, 1, main.path), entry(20, 10, "/bin/claude-other")]] {
            XCTAssertEqual(evaluate(processes) { _ in XCTFail(); return nil }, .idle)
        }
    }

    func testBusyRecordIncludesTaskMetadata() throws {
        XCTAssertEqual(evaluate(tree) { try record($0, status: "busy") },
            .busy([CodeTaskInfo(pid: 20, sessionID: "fixture-session", workingDirectory: "/fixture/project", reason: .statusBusy)]))
    }

    func testEachDirectShellMakesIdleBusyAndOtherChildrenDoNot() throws {
        for shell in ["sh", "bash", "zsh", "fish"] {
            XCTAssertEqual(evaluate(tree + [entry(30, 20, "/bin/\(shell)")]) { try record($0) },
                .busy([CodeTaskInfo(pid: 20, sessionID: "fixture-session", workingDirectory: "/fixture/project", reason: .shellChild(pid: 30))]))
        }
        for child in ["node", "python", "bash-other", "sdk", "mcp"] {
            XCTAssertEqual(evaluate(tree + [entry(30, 20, "/bin/\(child)")]) { try record($0) }, .idle)
        }
        XCTAssertEqual(evaluate(tree + [entry(30, 20, "/bin/node"), entry(31, 30, "/bin/sh")]) { try record($0) }, .idle)
    }

    func testUnreadableAbsentAndMalformedRegistriesFailClosed() {
        XCTAssertEqual(evaluate(tree) { _ in nil }, .unknown(TaskUnknownReason.registryUnreadable))
        XCTAssertEqual(evaluate(tree) { _ in throw CocoaError(.fileReadNoPermission) }, .unknown(TaskUnknownReason.registryUnreadable))
        for bytes in [Data(), Data("{}".utf8), Data("[]".utf8), Data("not-json".utf8)] {
            XCTAssertEqual(evaluate(tree) { _ in bytes }, .unknown(TaskUnknownReason.registryMismatch))
        }
    }

    func testPIDStartEntrypointAndStatusMatrix() throws {
        for data in [try record(21), try record(procStart: "Wed Jan 1 12:04:05 2025"),
                     try record(entrypoint: "terminal"), try record(status: "unrecognized"), try record(status: "BUSY")] {
            XCTAssertEqual(evaluate(tree) { _ in data }, .unknown(TaskUnknownReason.registryMismatch))
        }
        let fields: [String: Any] = ["pid": 20, "procStart": TaskGuardEvaluator.registryStartTime(start),
                                     "entrypoint": "claude-desktop", "status": "idle"]
        for missing in fields.keys {
            var value = fields
            value[missing] = nil
            let data = try JSONSerialization.data(withJSONObject: value)
            XCTAssertEqual(evaluate(tree) { _ in data }, .unknown(TaskUnknownReason.registryMismatch))
        }
    }

    func testUTCDateFormatAndWhitespaceNormalization() throws {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(TaskGuardEvaluator.registryStartTime(date), "Thu Jan 1 00:00:00 1970")
        let proc = TaskGuardEvaluator.registryStartTime(start).split(separator: " ").joined(separator: "  \t") + "\n"
        XCTAssertEqual(evaluate(tree) { try record($0, procStart: proc) }, .idle)
    }

    func testBusyWinsOverUnknownInEitherOrderAndCollectsAllBusy() throws {
        for pids: [Int32] in [[20, 21, 22], [22, 21, 20]] {
            let processes = Array(tree.prefix(2)) + pids.map { entry($0, 10) }
            let result = evaluate(processes) { $0 == 21 ? nil : try record($0, status: "busy") }
            guard case .busy(let tasks) = result else { return XCTFail("Expected busy") }
            XCTAssertEqual(Set(tasks.map(\.pid)), [20, 22])
        }
    }
}
