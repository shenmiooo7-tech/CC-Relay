import Foundation
import Darwin
import XCTest
@testable import CompanionCore

@MainActor
final class NativeRecoveryCoordinatorTests: XCTestCase {
    func testFinalInventoryRecognizesAlreadyPermittedDurableCommand() async throws {
        for extra in [nil, "alias", "agent"] as [String?] { try await checkDurableHostInventory(extra: extra) }
    }

    func testFinalInventoryStillDetectsNewWorkBesideDurableCommand() async throws {
        for extra in ["command", "expired", "missing"] { try await checkDurableHostInventory(extra: extra) }
    }

    private func checkDurableHostInventory(extra: String?) async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        await f.sourceRuntime(); try await f.installCommand()
        let first = try await f.prepare(); try await f.coordinator.activate(first)
        try await f.runtime(profile: f.target, pid: 202); _ = await f.coordinator.poll()
        try f.result(f.request(), status: "claimed")
        // Original native output-client completion does not finish its protected command body.
        // In-flight attachment in the intermediate runtime can commit ownership before its next report.
        try f.changeCommand { $0["owner"] = ["pid": 202, "start": f.clock.now().timeIntervalSince1970 * 1000] }
        try f.writeConversation(completed: true)
        try f.report(pid: 202, born: f.clock.now(), activeTasks: [])
        let prepared = try await f.coordinator.prepare(source: f.target, target: f.third, primary: nil, claudeWasOpen: true)
        let batch = try XCTUnwrap(prepared)
        XCTAssertEqual(batch.captureFailures, 0)
        XCTAssertNil(try XCTUnwrap(batch.requests.first).sourcePID)
        XCTAssertEqual(batch.requests.first?.sourceActiveTasks?.first?.jobID, "cmd-fixture")
        let file = f.directory.appending(path: "commands/cmd-fixture/handoff.json")
        var permit = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        XCTAssertEqual(permit["operationID"] as? String, batch.operation.operationID)
        XCTAssertEqual(permit["sourcePID"] as? Int, 202)
        XCTAssertGreaterThan(try XCTUnwrap(permit["expiresAt"] as? Double), f.clock.now().timeIntervalSince1970 * 1000)
        if extra == "expired" {
            permit["expiresAt"] = f.clock.now().timeIntervalSince1970 * 1000
            try AtomicFile.write(JSONSerialization.data(withJSONObject: permit), to: file)
        } else if extra == "missing" { try FileManager.default.removeItem(at: file) }
        let task = NativeRuntimeTask(id: extra == "alias" ? "new-client" : "previous-client", kind: .monitor,
            toolUseID: "original-monitor", jobID: "cmd-fixture", aliases: extra == "alias" ? ["previous-client"] : nil)
        var active = [task]
        var hostTasks = [NativeHostWorkInventory.Task(id: "previous-client", type: "monitor", status: "running")]
        if extra == "command" {
            active.append(.init(id: "new-client", kind: .bash, jobID: "cmd-new"))
            hostTasks.append(.init(id: "new-client", type: "shell", status: "running"))
        }
        // A subagent needs the model, which the spent account cannot give it anyway: no command ends.
        if extra == "agent" { hostTasks.append(.init(id: "helper", type: "subagent", status: "running")) }
        try f.report(pid: 202, born: f.clock.now(), activeTasks: active, hostWorkInventory: .init(backgroundTasks: hostTasks))
        let refreshed = await f.coordinator.refreshSourceStops(batch, source: f.target)
        if [nil, "alias", "agent"].contains(extra) {
            XCTAssertEqual(refreshed.captureFailures, 0, "A command already captured in this batch with a current permit is not unprotected")
        } else {
            XCTAssertGreaterThan(refreshed.captureFailures, 0, "A new command or a missing or expired exit permit must still be warned about")
        }
        XCTAssertEqual(refreshed.requests.first?.sourceActiveTasks?.first?.jobID, "cmd-fixture")
    }

    func testTargetLaunchWakesOnlyPreparedWorkAndStillRequiresTheRuntimeHandshake() async throws {
        // An idle conversation stopped by a rate limit is carried too: its continue link alone would
        // not start its CLI.
        for idleLimited in [false, true] {
            let f = try NativeRecoveryFixture(); defer { f.cleanup() }
            try f.writeConversation(completed: idleLimited)
            await f.sourceRuntime(busy: !idleLimited)
            if idleLimited {
                let now = f.clock.now().timeIntervalSince1970 * 1000
                try await f.inspector.setOwnership(pid: 101, profile: f.source.url, account: XCTUnwrap(f.source.identity), allowed: true)
                try f.report(pid: 101, activeTasks: [], quotaBlock: NativeQuotaBlock(reason: "rateLimit", observedAt: now, until: now + 600_000))
            }
            let batch = try await f.prepare()
            let sourceBucket = try XCTUnwrap(f.source.readableBucket)
            let sourceFile = f.source.url.appending(path: sourceBucket.relativePath).appending(path: "local_\(f.sessionID).json")
            let beforeSource = try AtomicFile.read(sourceFile)
            let failures = try await f.coordinator.prepareTargetLaunch(batch, profile: f.target)
            XCTAssertEqual(failures, 0)
            let targetBucket = try XCTUnwrap(f.target.readableBucket)
            let targetFile = f.target.url.appending(path: targetBucket.relativePath).appending(path: "local_\(f.sessionID).json")
            let target = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(targetFile)) as? [String: Any])
            XCTAssertEqual(SessionJSON.integer(target["interruptedByQuitAt"]), Int64(f.clock.now().timeIntervalSince1970 * 1_000))
            XCTAssertEqual(SessionJSON.boolean(target["interruptedAwaitingPerson"]), false)
            XCTAssertEqual(try AtomicFile.read(sourceFile), beforeSource)
            let operation = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(f.directory.appending(path: "active.json"))) as? [String: Any])
            XCTAssertEqual(SessionJSON.boolean(operation["ready"]), false)
            XCTAssertEqual(SessionJSON.boolean(operation["launchPrepared"]), true)
            _ = await f.coordinator.poll()
            XCTAssertEqual(try f.request().phase, "prepared")
            XCTAssertNil(try f.request().pid)
            let requestID = try f.request().requestID
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appending(path: "results/\(requestID).json").path))
            try await f.runtime(profile: f.target, pid: 202)
            try await f.coordinator.activate(batch)
            _ = await f.coordinator.poll()
            XCTAssertEqual(try f.request().phase, "armed")
        }
    }

    func testAnUnattendedTargetLaunchMarksEveryConversationOrNone() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        try f.writeConversation(completed: false, sessionID: "second-conversation")
        let birth = f.clock.now().addingTimeInterval(-20)
        await f.inspector.setSessions([
            NativeProcessSession(sessionID: f.sessionID, pid: 101, startedAt: birth, busy: true),
            NativeProcessSession(sessionID: "second-conversation", pid: 102, startedAt: birth, busy: true),
        ], profile: f.source.url)
        let batch = try await f.prepare(expectedCount: 2)
        let bucket = try XCTUnwrap(f.target.readableBucket)
        let records = [f.sessionID, "second-conversation"].map {
            f.target.url.appending(path: bucket.relativePath).appending(path: "local_\($0).json")
        }
        // The second one waits for the person: nothing may wake it.
        var held = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(records[1])) as? [String: Any])
        held["interruptedAwaitingPerson"] = true
        try AtomicFile.write(JSONSerialization.data(withJSONObject: held), to: records[1])
        let before = try records.map { try AtomicFile.read($0) }
        let failures = try await f.coordinator.prepareTargetLaunch(batch, profile: f.target, allOrNothing: true)
        XCTAssertGreaterThan(failures, 0)
        // Whichever came first, no marker is left on the target for a switch that goes back.
        XCTAssertEqual(try records.map { try AtomicFile.read($0) }, before)
    }

    func testTargetLaunchDoesNotWakeStoppedResolvedOrPersonHeldConversations() async throws {
        for change in ["stop", "resolved", "person"] {
            let f = try NativeRecoveryFixture(); defer { f.cleanup() }
            await f.sourceRuntime(); let batch = try await f.prepare()
            let file = f.directory.appending(path: "requests/\(f.sessionID).json")
            var request = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
            if change == "stop" { request["sourceUserStopped"] = true }
            if change == "resolved" { request["phase"] = "resolved" }
            try AtomicFile.write(JSONSerialization.data(withJSONObject: request), to: file)
            let bucket = try XCTUnwrap(f.target.readableBucket)
            let recordFile = f.target.url.appending(path: bucket.relativePath).appending(path: "local_\(f.sessionID).json")
            if change == "person" {
                var record = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(recordFile)) as? [String: Any])
                record["interruptedAwaitingPerson"] = true
                try AtomicFile.write(JSONSerialization.data(withJSONObject: record), to: recordFile)
            }
            let before = try AtomicFile.read(recordFile)
            let failures = try await f.coordinator.prepareTargetLaunch(batch, profile: f.target)
            XCTAssertEqual(failures, change == "person" ? 1 : 0)
            XCTAssertEqual(try AtomicFile.read(recordFile), before)
            XCTAssertEqual(try f.request().activationError != nil, change == "person")
        }
    }

    func testAttentionDetailsIdentifyTheSessionAndSafeFailureReason() async throws {
        for scenario in ["missing", "incompatible", "not-started", "failed"] {
            let f = try NativeRecoveryFixture(); defer { f.cleanup() }
            await f.sourceRuntime()
            let batch = try await f.prepare()
            try await f.coordinator.activate(batch)
            try await f.runtime(profile: f.target, pid: 202)
            _ = await f.coordinator.poll()
            var request = try f.request()
            let path = f.directory.appending(path: "requests/\(f.sessionID).json")
            let expected: NativeRecoveryIssue
            switch scenario {
            case "missing":
                try FileManager.default.removeItem(at: path)
                expected = NativeRecoveryIssue(sessionID: f.sessionID, reason: .missingRecord)
            case "incompatible":
                request.requiredCapability = "native-recovery-old"
                try AtomicFile.write(JSONEncoder().encode(request), to: path)
                expected = NativeRecoveryIssue(sessionID: request.desktopSessionID, reason: .incompatibleRuntime)
            case "not-started":
                try f.result(request, status: "needsAttention")
                expected = NativeRecoveryIssue(sessionID: request.desktopSessionID, reason: .recoveryIncomplete)
            default:
                try f.result(request, status: "turnFinished", evidence: [NativeRecoveryEvidence(tool: "Bash",
                    outcome: "blockedOrFailed", timestamp: f.clock.now().timeIntervalSince1970 * 1_000)])
                expected = NativeRecoveryIssue(sessionID: request.desktopSessionID, reason: .executionFailed)
            }
            let summary = await f.coordinator.poll()
            XCTAssertEqual(summary?.attention, 1, scenario)
            XCTAssertEqual(summary?.issues, [expected], scenario)
        }
    }

    func testARegisteredWebSocketIsNotLostBeforeItsNextRuntimeHeartbeatAndTerminalReportsStillWin() async throws {
        for terminal in [false, true] {
            let f = try NativeRecoveryFixture(); defer { f.cleanup() }
            await f.sourceRuntime(busy: false)
            try f.writeConversation(completed: false, laterQuestion: true)
            try await f.inspector.setOwnership(pid: 101, profile: f.source.url, account: XCTUnwrap(f.source.identity), allowed: true)
            try f.report(pid: 101, activeTasks: [NativeRuntimeTask(id: "original-task", kind: .monitor,
                toolUseID: "original-monitor", deadlineAt: f.clock.now().addingTimeInterval(300).timeIntervalSince1970 * 1000)])
            let first = try await f.prepare(); try await f.coordinator.activate(first)
            try await f.runtime(profile: f.target, pid: 202); _ = await f.coordinator.poll()
            try f.report(pid: 202, born: f.clock.now(), activeTasks: [])
            let old = try f.request(); try f.result(old, status: "executing")
            let file = f.directory.appending(path: "results/\(old.requestID).json")
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
            value["tasks"] = [["sourceTaskID": "original-task", "newTaskID": "second-client", "kind": "monitor",
                "status": "registered", "registeredAt": f.clock.now().timeIntervalSince1970 * 1000 + (terminal ? -1 : 1)]]
            try AtomicFile.write(JSONSerialization.data(withJSONObject: value), to: file)
            let next = try await f.coordinator.prepare(source: f.target, target: f.third, primary: nil, claudeWasOpen: true)
            let refreshed = await f.coordinator.refreshSourceStops(try XCTUnwrap(next), source: f.target)
            XCTAssertEqual(refreshed.requests.first?.sourceActiveTasks?.first?.id, terminal ? nil : "second-client")
            if !terminal { XCTAssertEqual(refreshed.requests.first?.sourceActiveTasks?.first?.aliases, ["original-task"]) }
        }
    }

    func testACompletedWorkerAlreadyAcknowledgedByTheSourceIsNotCarriedAsPendingAgain() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        await f.sourceRuntime(); try await f.installCommand()
        let first = try await f.prepare(); try await f.coordinator.activate(first)
        try await f.runtime(profile: f.target, pid: 202); _ = await f.coordinator.poll()
        try f.result(f.request(), status: "turnFinished")
        let file = f.directory.appending(path: "commands/cmd-fixture/state.json")
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        state["status"] = "completed"
        try AtomicFile.write(JSONSerialization.data(withJSONObject: state), to: file)
        try f.writeConversation(completed: true); try f.report(pid: 202, born: f.clock.now(), activeTasks: [])
        let next = try await f.coordinator.prepare(source: f.target, target: f.third, primary: nil, claudeWasOpen: true)
        XCTAssertTrue(next?.requests.isEmpty == true)
    }

    func testFinishedOutputAliasesDoNotReviveAfterAnEndedContinuationButUnconsumedWorkStillCarries() async throws {
        for (receiptStatus, workerStatus, receiptJob, expected) in [
            ("turnFinished", "completed", "cmd-fixture", 0),
            ("turnFinished", "failed", "cmd-fixture", 0),
            ("executing", "completed", "cmd-fixture", 1),
            ("turnFinished", "running", "cmd-fixture", 1),
            ("turnFinished", "completed", "cmd-unrelated", 1),
        ] {
            let f = try NativeRecoveryFixture(); defer { f.cleanup() }
            await f.sourceRuntime(); try await f.installCommand()
            let first = try await f.prepare(); try await f.coordinator.activate(first)
            try await f.runtime(profile: f.target, pid: 202); _ = await f.coordinator.poll()
            let request = try f.request(); try f.result(request, status: receiptStatus)
            let file = f.directory.appending(path: "results/\(request.requestID).json")
            var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
            receipt["tasks"] = [["sourceTaskID": "original-task", "newTaskID": "replacement-client", "jobID": receiptJob,
                                  "status": workerStatus]]
            try AtomicFile.write(JSONSerialization.data(withJSONObject: receipt), to: file)
            let stateFile = f.directory.appending(path: "commands/cmd-fixture/state.json")
            var state = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(stateFile)) as? [String: Any])
            state["status"] = workerStatus
            try AtomicFile.write(JSONSerialization.data(withJSONObject: state), to: stateFile)
            // The native transcript still names the old output client as pending. Its replacement's
            // final state is proven by the worker and ended continuation, not a fabricated notification.
            try f.report(pid: 202, born: f.clock.now(), activeTasks: [])
            let next = try await f.coordinator.prepare(source: f.target, target: f.third, primary: nil, claudeWasOpen: true)
            XCTAssertEqual(next?.requests.count ?? 0, expected, "\(receiptStatus), \(workerStatus), \(receiptJob)")
        }
    }

    func testFinishedOutputAliasRemainsTerminalWhenALaterHandoffRecapturesTheConversation() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        await f.sourceRuntime(); try await f.installCommand()
        let first = try await f.prepare(); try await f.coordinator.activate(first)
        try await f.runtime(profile: f.target, pid: 202); _ = await f.coordinator.poll()
        let request = try f.request(); try f.result(request, status: "turnFinished")
        let file = f.directory.appending(path: "results/\(request.requestID).json")
        var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        receipt["tasks"] = [["sourceTaskID": "original-task", "newTaskID": "replacement-client", "jobID": "cmd-fixture", "status": "completed"]]
        try AtomicFile.write(JSONSerialization.data(withJSONObject: receipt), to: file)
        let stateFile = f.directory.appending(path: "commands/cmd-fixture/state.json")
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(stateFile)) as? [String: Any])
        state["status"] = "completed"
        try AtomicFile.write(JSONSerialization.data(withJSONObject: state), to: stateFile)
        // The conversation is busy with something new; its finished command must stay finished.
        try f.writeConversation(completed: false)
        try f.report(pid: 202, born: f.clock.now(), activeTasks: [])
        await f.inspector.setSessions([NativeProcessSession(sessionID: f.sessionID, pid: 202, startedAt: f.clock.now(), busy: true)],
                                      profile: f.target.url)
        let prepared = try await f.coordinator.prepare(source: f.target, target: f.third, primary: nil, claudeWasOpen: true)
        let next = try XCTUnwrap(prepared)
        let reconciled = await f.coordinator.refreshSourceStops(next, source: f.target)
        XCTAssertEqual(reconciled.requests.first?.work.tasks.first?.state, .completed)
        XCTAssertEqual(reconciled.requests.first?.work.needsContinuation, false)
        XCTAssertTrue(reconciled.requests.first?.sourceActiveTasks?.isEmpty != false)

        // That generation has no command inventory or continuation receipt. Another real
        // handoff must not forget the command's already verified terminal state.
        try await f.runtime(profile: f.third, pid: 303)
        try f.report(pid: 303, born: f.clock.now(), activeTasks: [])
        await f.inspector.setSessions([NativeProcessSession(sessionID: f.sessionID, pid: 303, startedAt: f.clock.now(), busy: true)],
                                      profile: f.third.url)
        let again = try await f.coordinator.prepare(source: f.third, target: f.source, primary: nil, claudeWasOpen: true)
        XCTAssertEqual(again?.requests.first?.work.tasks.first?.state, .completed)
        XCTAssertEqual(again?.requests.first?.work.needsContinuation, false)
        XCTAssertTrue(again?.requests.first?.sourceActiveTasks?.isEmpty != false)
    }

    func testAnOlderCoordinatorRequestCannotBindACompatibleRuntimeOrDisappearSilently() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        await f.sourceRuntime(); let batch = try await f.prepare()
        let file = f.directory.appending(path: "requests/\(f.sessionID).json")
        var request = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        request.removeValue(forKey: "requiredCapability")
        try AtomicFile.write(JSONSerialization.data(withJSONObject: request), to: file)
        try await f.coordinator.activate(batch); try await f.runtime(profile: f.target, pid: 202)
        let summary = await f.coordinator.poll()
        XCTAssertEqual(summary?.attention, 1)
        XCTAssertNil(try f.request().pid)
        XCTAssertNotNil(try f.request().runtimeError)
    }

    func testASuccessfulTaskStopFlushedDuringCloseWinsOverAStillRunningWorkerRecord() async throws {
        for aliased in [false, true] {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        await f.sourceRuntime(); try await f.installCommand()
        let taskID = aliased ? "new-native-task" : "original-task"
        if aliased { try f.report(pid: 101, activeTasks: [NativeRuntimeTask(id: taskID, kind: .monitor,
            toolUseID: "original-monitor", jobID: "cmd-fixture", aliases: ["original-task"])]) }
        let batch = try await f.prepare()
        let file = f.paths.claudeCLIHome.appending(path: "projects/fixture/\(f.sessionID).jsonl")
        var data = try AtomicFile.read(file)
        let rows: [[String: Any]] = [
            ["uuid": "stop-call", "parentUuid": "native-tail", "type": "assistant", "message": ["stop_reason": "tool_use", "content": [
                ["type": "tool_use", "id": "stop-use", "name": "TaskStop", "input": ["task_id": taskID]]]]],
            ["uuid": "stop-result", "parentUuid": "stop-call", "type": "user", "toolUseResult": ["task_id": taskID], "message": ["content": [
                ["type": "tool_result", "tool_use_id": "stop-use", "content": "stopped"]]]],
            ["uuid": "stop-final", "parentUuid": "stop-result", "type": "assistant", "message": ["stop_reason": "end_turn", "content": "Stopped the original task."]],
        ]
        for var row in rows {
            row["sessionId"] = f.sessionID; row["timestamp"] = "2026-10-27T01:01:00Z"
            data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10)
        }
        try AtomicFile.write(data, to: file)
        let bucket = try XCTUnwrap(f.source.readableBucket)
        let metadata = f.source.url.appending(path: bucket.relativePath).appending(path: "local_\(f.sessionID).json")
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(metadata)) as? [String: Any])
        record["lastAssistantUuid"] = "stop-final"
        try AtomicFile.write(JSONSerialization.data(withJSONObject: record), to: metadata)
        let closed = await f.coordinator.reconcileAfterClose(batch, source: f.source)
        XCTAssertEqual(closed.requests.first?.sourceActiveTasks, [])
        XCTAssertEqual(closed.requests.first?.work.tasks.first(where: { $0.id == "original-task" })?.explicitlyStopped, true)
        XCTAssertEqual(closed.requests.first?.phase, "resolved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appending(path: "commands/cmd-fixture/handoff.json").path))
        }
    }

    func testTheNextExitPermitUsesTheOwnerAfterAnInFlightAdoptionCommits() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        await f.sourceRuntime(); try await f.installCommand()
        let first = try await f.prepare(); try await f.coordinator.activate(first)
        try await f.runtime(profile: f.target, pid: 202); _ = await f.coordinator.poll()
        try f.result(f.request(), status: "claimed")
        let job = f.directory.appending(path: "commands/cmd-fixture")
        let lease = try CompanionFileLease(file: job.appending(path: "ownership.lock"))
        defer { lease.release() }
        let next = Task { try await f.coordinator.prepare(source: f.target, target: f.third, primary: nil, claudeWasOpen: true) }
        let targetName = f.third.folder.name
        let committing = await eventually { await f.activeOperation()?.targetProfile == targetName }
        XCTAssertTrue(committing)
        try await Task.sleep(for: .milliseconds(20))
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(job.appending(path: "state.json"))) as? [String: Any])
        state["owner"] = ["pid": 202, "start": f.clock.now().timeIntervalSince1970 * 1000]
        try AtomicFile.write(JSONSerialization.data(withJSONObject: state), to: job.appending(path: "state.json"))
        lease.release()
        _ = try await next.value
        let permit = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(job.appending(path: "handoff.json"))) as? [String: Any])
        XCTAssertEqual(permit["sourcePID"] as? Int, 202)
        XCTAssertEqual(permit["sourceStartedAt"] as? Double, f.clock.now().timeIntervalSince1970 * 1000)
    }

    func testAnOlderPrepareCannotReplaceANewerInstancesCommittedGeneration() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        await f.sourceRuntime(); try await f.installCommand()
        await f.inspector.pauseValidation(pid: 101)
        let first = Task { () -> Result<NativeRecoveryBatch?, Error> in
            do { return .success(try await f.coordinator.prepare(source: f.source, target: f.target, primary: nil, claudeWasOpen: true)) }
            catch { return .failure(error) }
        }
        let paused = await eventually { await f.inspector.validationPaused }; XCTAssertTrue(paused)
        let second = NativeRecoveryCoordinator(paths: f.paths, inspector: f.inspector, clock: f.clock)
        let made = try await second.prepare(source: f.source, target: f.third, primary: nil, claudeWasOpen: true)
        let winner = try XCTUnwrap(made)
        await f.inspector.resumeValidation()
        let old = await first.value
        if case .success = old { XCTFail("A prepare captured before a competing generation must report a conflict") }
        XCTAssertEqual(f.activeOperation()?.operationID, winner.operation.operationID)
        XCTAssertEqual(try f.request().operationID, winner.operation.operationID)
        let handoff = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(f.directory.appending(path: "commands/cmd-fixture/handoff.json"))) as? [String: Any])
        XCTAssertEqual(handoff["operationID"] as? String, winner.operation.operationID)
    }

    func testAStaleEmptyCaptureCannotDeleteAnotherInstancesNewGeneration() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        await f.sourceRuntime(); try await f.installCommand()
        let pausedInspector = NativeCoordinatorTestInspector()
        await pausedInspector.pauseSessions(profile: f.source.url)
        let stale = NativeRecoveryCoordinator(paths: f.paths, inspector: pausedInspector, clock: f.clock)
        let first = Task { try? await stale.prepare(source: f.source, target: f.target, primary: nil, claudeWasOpen: true) }
        let paused = await eventually { await pausedInspector.sessionsPaused }; XCTAssertTrue(paused)
        let winner = try await f.prepare()
        await pausedInspector.resumeSessions(); _ = await first.value
        XCTAssertEqual(f.activeOperation()?.operationID, winner.operation.operationID)
        XCTAssertEqual(try f.request().operationID, winner.operation.operationID)
    }

    func testTheLastSourceSampleAuthorizesNewlyObservedCommandsBeforeClosing() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime()
        let prepared = try await fixture.prepare()
        try await fixture.installCommand()
        let file = fixture.directory.appending(path: "commands/cmd-fixture/handoff.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let refreshed = await fixture.coordinator.refreshSourceStops(prepared, source: fixture.source)
        XCTAssertEqual(refreshed.requests.first?.sourceActiveTasks?.first?.jobID, "cmd-fixture")
        let permit = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        XCTAssertEqual(permit["sourcePID"] as? Int, 101)
        XCTAssertEqual(permit["operationID"] as? String, refreshed.operation.operationID)
    }

    func testRapidSwitchKeepsAnUnadoptedCommandWhenTheIntermediateRuntimeReportsNoTasks() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime(); try await fixture.installCommand()
        let first = try await fixture.prepare(); try await fixture.coordinator.activate(first)
        try await fixture.runtime(profile: fixture.target, pid: 202); _ = await fixture.coordinator.poll()
        try fixture.result(fixture.request(), status: "claimed")
        try fixture.report(pid: 202, born: fixture.clock.now(), activeTasks: [])
        let pending = try await fixture.coordinator.prepare(source: fixture.target, target: fixture.third, primary: nil, claudeWasOpen: true)
        let refreshed = await fixture.coordinator.refreshSourceStops(try XCTUnwrap(pending), source: fixture.target)
        XCTAssertEqual(refreshed.requests.first?.sourceActiveTasks?.map(\.jobID), ["cmd-fixture"])
        XCTAssertEqual(refreshed.captureFailures, 0)
        try await fixture.coordinator.activate(refreshed)
        try await fixture.runtime(profile: fixture.third, pid: 303); _ = await fixture.coordinator.poll()
        let file = fixture.directory.appending(path: "commands/cmd-fixture/handoff.json")
        let permit = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        XCTAssertEqual(permit["sourcePID"] as? Int, 101)
        XCTAssertEqual(permit["targetPID"] as? Int, 303)
    }

    func testAnAlreadyAdoptedCommandKeepsItsOriginalAliasesAcrossTheNextSwitch() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime(); try await fixture.installCommand()
        let first = try await fixture.prepare(); try await fixture.coordinator.activate(first)
        try await fixture.runtime(profile: fixture.target, pid: 202); _ = await fixture.coordinator.poll()
        try fixture.result(fixture.request(), status: "executing")
        let file = fixture.directory.appending(path: "commands/cmd-fixture/state.json")
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        record["owner"] = ["pid": 202, "start": fixture.clock.now().timeIntervalSince1970 * 1000]
        try AtomicFile.write(JSONSerialization.data(withJSONObject: record), to: file)
        let current = NativeRuntimeTask(id: "second-client", kind: .monitor, toolUseID: "original-monitor", jobID: "cmd-fixture")
        try fixture.report(pid: 202, born: fixture.clock.now(), activeTasks: [current])
        let batch = try await fixture.coordinator.prepare(source: fixture.target, target: fixture.third, primary: nil, claudeWasOpen: true)
        let refreshed = await fixture.coordinator.refreshSourceStops(try XCTUnwrap(batch), source: fixture.target)
        XCTAssertEqual(refreshed.requests.first?.sourceActiveTasks?.first?.aliases, ["original-task"])
        XCTAssertEqual(refreshed.requests.first?.sourceActiveTasks?.first?.id, "second-client")
    }

    func testAClaimedSurvivingCommandCanCrossAnotherSwitchWithoutReplayingOldAgentActions() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime(); try await fixture.installCommand()
        let first = try await fixture.prepare()
        try await fixture.coordinator.activate(first); try await fixture.runtime(profile: fixture.target, pid: 202)
        _ = await fixture.coordinator.poll()
        let old = try fixture.request()
        try fixture.result(old, status: "claimed", evidence: [NativeRecoveryEvidence(tool: "SendMessage", agentID: "old-agent", outcome: "attempting", timestamp: 1)])
        let receipt = fixture.directory.appending(path: "results/\(old.requestID).json")
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(receipt)) as? [String: Any])
        value["tasks"] = [["sourceTaskID": "original-task", "jobID": "cmd-fixture", "newTaskID": "previous-client"]]
        try AtomicFile.write(JSONSerialization.data(withJSONObject: value), to: receipt)
        await fixture.inspector.setSessions([], profile: fixture.target.url)
        let captured = try await fixture.coordinator.prepare(source: fixture.target, target: fixture.third, primary: nil, claudeWasOpen: true)
        let batch = try XCTUnwrap(captured)
        XCTAssertEqual(batch.requests.count, 1)
        XCTAssertEqual(batch.requests.first?.sourceActiveTasks?.first?.jobID, "cmd-fixture")
        XCTAssertEqual(batch.requests.first?.sourceActiveTasks?.first?.aliases, ["previous-client"])
        XCTAssertEqual(batch.requests.first?.previousAgentResumeIDs, ["old-agent"])
        XCTAssertTrue(batch.requests.first?.work.tasks.allSatisfy { $0.kind != .agent } == true)
        XCTAssertEqual(batch.requests.first?.work.artifacts, [])
        try await fixture.coordinator.activate(batch); try await fixture.runtime(profile: fixture.third, pid: 303)
        _ = await fixture.coordinator.poll()
        let file = fixture.directory.appending(path: "commands/cmd-fixture/handoff.json")
        let permit = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        XCTAssertEqual(permit["targetPID"] as? Int, 303)
        XCTAssertEqual(permit["sourcePID"] as? Int, 101)
        XCTAssertNotEqual(try fixture.request().requestID, old.requestID)
    }

    func testCarriedCommandsStillRequireTheJustClosedProfilesOriginalConversation() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime(); try await fixture.installCommand()
        let first = try await fixture.prepare(); try await fixture.coordinator.activate(first)
        try await fixture.runtime(profile: fixture.target, pid: 202); _ = await fixture.coordinator.poll()
        try fixture.result(fixture.request(), status: "claimed")
        await fixture.inspector.setSessions([], profile: fixture.target.url)
        let captured = try await fixture.coordinator.prepare(source: fixture.target, target: fixture.third, primary: nil, claudeWasOpen: true)
        let batch = try XCTUnwrap(captured)
        let bucket = try XCTUnwrap(fixture.target.readableBucket)
        try FileManager.default.removeItem(at: fixture.target.url.appending(path: bucket.relativePath).appending(path: "local_\(fixture.sessionID).json"))
        let checked = await fixture.coordinator.reconcileAfterClose(batch, source: fixture.target)
        XCTAssertEqual(checked.requests.first?.phase, "blocked")
        XCTAssertEqual(checked.captureFailures, 1)
    }

    func testCommandAuthorizationFollowsOnlyAnOwnedTemporaryExecutionLocation() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime(); try await fixture.installCommand()
        let control = fixture.directory.appending(path: "commands/cmd-fixture")
        let physical = URL(fileURLWithPath: "/private/tmp/cc-relay-native-\(getuid())").standardizedFileURL
            .appending(path: UUID().uuidString).appending(path: "cmd-fixture")
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: physical.deletingLastPathComponent()) }
        try AtomicFile.write(AtomicFile.read(control.appending(path: "state.json")), to: physical.appending(path: "state.json"))
        try FileManager.default.removeItem(at: control.appending(path: "state.json"))
        try AtomicFile.write(JSONSerialization.data(withJSONObject: ["version": 1, "jobID": "cmd-fixture", "directory": physical.path]), to: control.appending(path: "location.json"))
        let batch = try await fixture.prepare()
        XCTAssertTrue(FileManager.default.fileExists(atPath: physical.appending(path: "handoff.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: control.appending(path: "handoff.json").path))
        await fixture.coordinator.cancel(batch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: physical.appending(path: "handoff.json").path))
    }

    func testCommandHandoffPreservesTheSourceAndAuthorizesOnlyTheBoundTargetLifetime() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime()
        try await fixture.installCommand()
        let batch = try await fixture.prepare()
        let file = fixture.directory.appending(path: "commands/cmd-fixture/handoff.json")
        var permit = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        XCTAssertEqual(permit["sourcePID"] as? Int, 101)
        XCTAssertNil(permit["targetPID"])
        try await fixture.coordinator.activate(batch)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        _ = await fixture.coordinator.poll()
        permit = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        XCTAssertEqual(permit["targetPID"] as? Int, 202)
        XCTAssertEqual(permit["targetInstanceID"] as? String, "runtime-202")
        XCTAssertEqual(permit["requestID"] as? String, try fixture.request().requestID)
        XCTAssertEqual(permit["targetStartedAt"] as? Double, try fixture.request().runtimeStartedAt)
    }

    func testClosingANativeOutputClientDoesNotLoseItsStillRunningCommand() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime(); try await fixture.installCommand()
        let batch = try await fixture.prepare()
        let transcript = fixture.paths.claudeCLIHome.appending(path: "projects/fixture/\(fixture.sessionID).jsonl")
        var data = try AtomicFile.read(transcript)
        let notice: [String: Any] = ["uuid": "exit-notice", "parentUuid": "native-tail", "type": "user", "sessionId": fixture.sessionID,
            "origin": ["kind": "task-notification"], "promptSource": "system", "message": ["content":
                "<task-notification><task-id>original-task</task-id><status>stopped</status><summary>native client exited</summary></task-notification>"]]
        data.append(try JSONSerialization.data(withJSONObject: notice)); data.append(10)
        try AtomicFile.write(data, to: transcript)
        let closed = await fixture.coordinator.reconcileAfterClose(batch, source: fixture.source)
        XCTAssertEqual(closed.requests.first?.sourceActiveTasks?.first?.jobID, "cmd-fixture")
        XCTAssertEqual(closed.requests.first?.phase, "prepared")
        XCTAssertEqual(closed.requests.first?.sourceWasBusy, true)
        try AtomicFile.write(Data("{\"stop\":true}".utf8), to: fixture.directory.appending(path: "commands/cmd-fixture/stop.json"))
        let stopped = await fixture.coordinator.reconcileAfterClose(batch, source: fixture.source)
        XCTAssertEqual(stopped.requests.first?.sourceActiveTasks, [])
        XCTAssertEqual(stopped.requests.first?.phase, "resolved")
    }

    func testACommandKeepsItsPermitWhileItsConversationWaitsButNotOnceAdoptedOrAfterTheWindow() async throws {
        for mode in ["waiting", "adopted", "late"] {
            let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
            await fixture.sourceRuntime(); try await fixture.installCommand()
            let batch = await fixture.coordinator.refreshSourceStops(try await fixture.prepare(), source: fixture.source)
            let file = fixture.directory.appending(path: "commands/cmd-fixture/handoff.json")
            func expiry() throws -> Double {
                try XCTUnwrap((JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])?["expiresAt"] as? Double)
            }
            func now() -> Double { fixture.clock.now().timeIntervalSince1970 * 1000 }
            fixture.clock.advance(by: 90) // Closing Desktop and syncing take time.
            let closed = await fixture.coordinator.reconcileAfterClose(batch, source: fixture.source)
            XCTAssertEqual(try expiry(), now() + 300_000, accuracy: 1, "the window starts once Desktop has closed")
            try await fixture.coordinator.activate(closed)
            if mode == "adopted" {
                // The target took the command over: its own exit must end the command again.
                let state = fixture.directory.appending(path: "commands/cmd-fixture/state.json")
                var record = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(state)) as? [String: Any])
                record["owner"] = ["pid": 202, "start": now()]
                try AtomicFile.write(JSONSerialization.data(withJSONObject: record), to: state)
            }
            fixture.clock.advance(by: 200) // The conversation is not open in the target yet.
            let before = try expiry()
            _ = await fixture.coordinator.poll()
            if mode == "adopted" { XCTAssertEqual(try expiry(), before, mode); continue }
            XCTAssertEqual(try expiry(), now() + 300_000, accuracy: 1, "a waiting conversation keeps its command")
            guard mode == "late" else { continue }
            fixture.clock.advance(by: 220) // Past the activation window and its grace.
            let renewed = try expiry()
            _ = await fixture.coordinator.poll()
            XCTAssertEqual(try expiry(), renewed, "nobody opened it in time: the command ends with its permit")
        }
    }

    func testCancellationAndASourceStopRevokeTheCommandExitPermit() async throws {
        for cancelled in [true, false] {
            let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
            await fixture.sourceRuntime(); try await fixture.installCommand()
            let batch = try await fixture.prepare()
            let file = fixture.directory.appending(path: "commands/cmd-fixture/handoff.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            if cancelled { await fixture.coordinator.cancel(batch) }
            else {
                try fixture.report(pid: 101, userStopped: true)
                _ = await fixture.coordinator.refreshSourceStops(batch, source: fixture.source)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testAnOlderLiveMonitorSurvivesALaterCompletedQuestionAndClose() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        try fixture.writeConversation(completed: false, laterQuestion: true)
        await fixture.sourceRuntime(busy: false)
        let inventory = [NativeRuntimeTask(id: "original-task", kind: .monitor, toolUseID: "original-monitor")]
        try await fixture.inspector.setOwnership(pid: 101, profile: fixture.source.url, account: XCTUnwrap(fixture.source.identity), allowed: true)
        try fixture.report(pid: 101, activeTasks: inventory)
        let batch = try await fixture.prepare()
        XCTAssertFalse(try XCTUnwrap(batch.requests.first).work.needsContinuation)
        XCTAssertEqual(batch.requests.first?.sourceActiveTasks, inventory)
        XCTAssertEqual(batch.requests.first?.sourceWasBusy, true)
        let closed = await fixture.coordinator.reconcileAfterClose(batch, source: fixture.source)
        XCTAssertEqual(closed.requests.first?.phase, "prepared")
        try await fixture.coordinator.activate(closed)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        let summary = await fixture.coordinator.poll()
        XCTAssertEqual(summary?.waiting, 1)
        XCTAssertEqual(try fixture.request().phase, "armed")
    }

    func testAnOlderActiveMonitorCompletedDuringCloseResolvesEvenWithoutANewerAssistantTurn() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        try fixture.writeConversation(completed: false, laterQuestion: true)
        await fixture.sourceRuntime(busy: false)
        try await fixture.inspector.setOwnership(pid: 101, profile: fixture.source.url, account: XCTUnwrap(fixture.source.identity), allowed: true)
        try fixture.report(pid: 101, activeTasks: [NativeRuntimeTask(id: "original-task", kind: .monitor)])
        let batch = try await fixture.prepare()
        try fixture.writeConversation(completed: true, laterQuestion: true)
        let closed = await fixture.coordinator.reconcileAfterClose(batch, source: fixture.source)
        XCTAssertEqual(closed.requests.first?.work.latestAssistant?.uuid, batch.requests.first?.work.latestAssistant?.uuid)
        XCTAssertEqual(closed.requests.first?.sourceActiveTasks, [])
        XCTAssertEqual(closed.requests.first?.sourceWasBusy, false)
        XCTAssertEqual(closed.requests.first?.phase, "resolved")
    }

    func testOlderPendingHistoryWithoutLiveInventoryNeitherWakesNorBlocksAnIdleConversation() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        try fixture.writeConversation(completed: false, laterQuestion: true)
        await fixture.sourceRuntime(busy: false)
        let batch = try await fixture.prepare(expectedCount: 0)
        XCTAssertEqual(batch.captureFailures, 0, "an old entry is not a failed switch")
    }

    func testABusyConversationWithoutLiveInventoryContinuesWithItsPendingHistoryListed() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        try fixture.writeConversation(completed: false, laterQuestion: true)
        await fixture.sourceRuntime(busy: true)
        let batch = try await fixture.prepare()
        XCTAssertEqual(batch.captureFailures, 0)
        XCTAssertEqual(batch.requests.first?.phase, "prepared")
        XCTAssertNil(batch.requests.first?.sourceActiveTasks, "nothing unverified is claimed as live")
        XCTAssertFalse(batch.requests.first?.work.tasksNeedingInspection.isEmpty ?? true, "the prompt still lists what to check")
    }

    func testFreshInventoryWithNoActiveTasksDoesNotReviveOlderPendingHistory() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        try fixture.writeConversation(completed: false, laterQuestion: true)
        await fixture.sourceRuntime(busy: false)
        try await fixture.inspector.setOwnership(pid: 101, profile: fixture.source.url, account: XCTUnwrap(fixture.source.identity), allowed: true)
        try fixture.report(pid: 101, activeTasks: [])
        _ = try await fixture.prepare(expectedCount: 0)
    }

    func testLargeProducedRequestAboveTheOldReaderLimitCanActuallyBeArmed() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        try fixture.writeMonitorHistory(count: 6000)
        await fixture.sourceRuntime()
        let batch = try await fixture.prepare()
        XCTAssertEqual(batch.requests.first?.work.tasks.count, 6000)
        XCTAssertEqual(batch.requests.first?.work.tasksNeedingInspection.count, 1)
        let file = fixture.directory.appending(path: "requests/\(fixture.sessionID).json")
        let bytes = try AtomicFile.read(file).count
        XCTAssertGreaterThan(bytes, 2_097_152)
        XCTAssertLessThan(bytes, 4_000_000)
        try await fixture.coordinator.activate(batch)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        let summary = await fixture.coordinator.poll()
        XCTAssertEqual(summary?.waiting, 1)
        XCTAssertEqual(try fixture.request().phase, "armed")
    }

    func testAnOversizedSnapshotGoesOnWithoutItsTasksAndCorruptMissingRequestsRemainVisible() async throws {
        let fixture = try NativeRecoveryFixture(requestByteLimit: 8_000); defer { fixture.cleanup() }
        try fixture.writeMonitorHistory(count: 40)
        await fixture.sourceRuntime()
        let primary = try ContinuityInspector(paths: fixture.paths).capture(profile: fixture.source)
        let value = try await fixture.coordinator.prepare(source: fixture.source, target: fixture.target, primary: primary, claudeWasOpen: true)
        let batch = try XCTUnwrap(value)
        // Too large to hand over: nothing is replayed from it, and the conversation still goes on.
        XCTAssertEqual(batch.captureFailures, 0)
        XCTAssertEqual(batch.requests.first?.phase, "prepared")
        XCTAssertTrue(try fixture.request().work.tasks.isEmpty)
        XCTAssertFalse(try fixture.request().work.branchComplete)
        XCTAssertTrue(try fixture.request().work.warnings.first?.contains("40 task records") == true)
        let closed = await fixture.coordinator.reconcileAfterClose(batch, source: fixture.source)
        XCTAssertTrue(try fixture.request().work.tasks.isEmpty, "Read again after the close, it is still too large")
        try await fixture.coordinator.activate(closed)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        _ = await fixture.coordinator.poll()
        XCTAssertEqual(try fixture.request().phase, "armed")
        let file = fixture.directory.appending(path: "requests/\(fixture.sessionID).json")
        try AtomicFile.write(Data("{broken".utf8), to: file)
        let corrupt = await fixture.coordinator.poll()
        XCTAssertEqual(corrupt?.attention, 1)
        try FileManager.default.removeItem(at: file)
        let missing = await fixture.coordinator.poll()
        XCTAssertEqual(missing?.attention, 1)
    }

    func testDeadClaimantOrStaleHeartbeatNeedsAttentionAndCannotBeStolenByAnotherRuntime() async throws {
        for status in ["claimed", "queued", "executing"] {
            let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
            await fixture.sourceRuntime()
            let batch = try await fixture.prepare()
            try await fixture.coordinator.activate(batch)
            try await fixture.runtime(profile: fixture.target, pid: 202)
            _ = await fixture.coordinator.poll()
            let bound = try fixture.request()
            try fixture.result(bound, status: status)
            fixture.clock.advance(by: 120)
            await fixture.inspector.setSessions([], profile: fixture.target.url)
            let dead = await fixture.coordinator.poll()
            XCTAssertEqual(dead?.attention, 1, status)
            XCTAssertEqual(dead?.submitted, 0)
            XCTAssertEqual(dead?.executing, 0)
            try await fixture.runtime(profile: fixture.target, pid: 303)
            let reopened = await fixture.coordinator.poll()
            XCTAssertEqual(reopened?.attention, 1)
            XCTAssertEqual(try fixture.request().requestID, bound.requestID)
            XCTAssertEqual(try fixture.request().pid, 202)
        }
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime(); let batch = try await fixture.prepare()
        try await fixture.coordinator.activate(batch); try await fixture.runtime(profile: fixture.target, pid: 202)
        _ = await fixture.coordinator.poll(); try fixture.result(fixture.request(), status: "queued")
        fixture.clock.advance(by: 20) // A sleeping Mac or a busy host: the same live process keeps its continuation.
        let stale = await fixture.coordinator.poll()
        XCTAssertEqual(stale?.attention, 0)
        XCTAssertEqual(stale?.submitted, 1)
        XCTAssertNil(try fixture.request().runtimeError)
        try fixture.report(pid: 202, born: fixture.clock.now().addingTimeInterval(-20))
        let refreshed = await fixture.coordinator.poll()
        XCTAssertEqual(refreshed?.submitted, 1)
        XCTAssertNil(try fixture.request().runtimeError)
    }

    func testTwoLiveInstancesCannotRebindWhileTheOriginalInstanceClaimsDuringValidation() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime(); let batch = try await fixture.prepare()
        try await fixture.coordinator.activate(batch); try await fixture.runtime(profile: fixture.target, pid: 202)
        _ = await fixture.coordinator.poll()
        let bound = try fixture.request(), born = fixture.clock.now()
        fixture.clock.advance(by: 1)
        try await fixture.runtime(profile: fixture.target, pid: 303)
        await fixture.inspector.setSessions([
            NativeProcessSession(sessionID: fixture.sessionID, pid: 202, startedAt: born, busy: false),
            NativeProcessSession(sessionID: fixture.sessionID, pid: 303, startedAt: fixture.clock.now(), busy: false)
        ], profile: fixture.target.url)
        await fixture.inspector.pauseValidation(pid: 202)
        let poll = Task { await fixture.coordinator.poll() }
        let paused = await eventually { await fixture.inspector.validationPaused }
        guard paused else { await fixture.inspector.resumeValidation(); _ = await poll.value; XCTFail("Validation was not reached"); return }
        try fixture.result(bound, status: "claimed")
        let concurrent = await fixture.coordinator.poll()
        XCTAssertNil(concurrent, "An overlapping coordinator poll must not create another arming transaction")
        await fixture.inspector.resumeValidation()
        let summary = await poll.value
        XCTAssertEqual(summary?.submitted, 1)
        XCTAssertEqual(summary?.attention, 0)
        XCTAssertEqual(try fixture.request().pid, 202)
        XCTAssertEqual(try fixture.request().instanceID, bound.instanceID)
        XCTAssertEqual(try fixture.request().requestID, bound.requestID)
    }

    func testIndependentCoordinatorsCannotCommitDifferentBindingsAfterConcurrentValidation() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime(); try await fixture.installCommand(); let batch = try await fixture.prepare()
        try await fixture.coordinator.activate(batch)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        let born = fixture.clock.now()
        await fixture.inspector.pauseValidation(pid: 202)
        let firstPoll = Task { await fixture.coordinator.poll() }
        let firstPaused = await eventually { await fixture.inspector.validationPaused }
        guard firstPaused else { await fixture.inspector.resumeValidation(); _ = await firstPoll.value; XCTFail("First validation was not reached"); return }

        // A second process arrives after the first coordinator has selected PID 202, but
        // before it commits. Both are real candidates, with the same account and valid lifetime.
        fixture.clock.advance(by: 1)
        try await fixture.runtime(profile: fixture.target, pid: 303)
        let sessions = [
            NativeProcessSession(sessionID: fixture.sessionID, pid: 202, startedAt: born, busy: false),
            NativeProcessSession(sessionID: fixture.sessionID, pid: 303, startedAt: fixture.clock.now(), busy: false)
        ]
        await fixture.inspector.setSessions(sessions, profile: fixture.target.url)
        let secondInspector = NativeCoordinatorTestInspector()
        await secondInspector.setSessions(sessions, profile: fixture.target.url)
        for pid: Int32 in [202, 303] {
            try await secondInspector.setOwnership(pid: pid, profile: fixture.target.url, account: XCTUnwrap(fixture.target.identity), allowed: true)
        }
        let second = NativeRecoveryCoordinator(paths: fixture.paths, inspector: secondInspector, clock: fixture.clock)
        await secondInspector.pauseValidation(pid: 303)
        let secondPoll = Task { await second.poll() }
        let secondPaused = await eventually { await secondInspector.validationPaused }
        guard secondPaused else {
            await fixture.inspector.resumeValidation(); await secondInspector.resumeValidation()
            _ = await firstPoll.value; _ = await secondPoll.value
            XCTFail("Both independent coordinators must have read the prepared request"); return
        }
        await fixture.inspector.resumeValidation(); _ = await firstPoll.value
        let bound = try fixture.request()
        XCTAssertEqual(bound.pid, 202)
        // No receipt exists yet: a second prepared snapshot still cannot overwrite the binding.
        await secondInspector.resumeValidation()
        let secondSummary = await secondPoll.value
        XCTAssertEqual(secondSummary?.waiting, 1)
        XCTAssertEqual(secondSummary?.attention, 0)
        XCTAssertEqual(try fixture.request().pid, 202)
        XCTAssertEqual(try fixture.request().instanceID, bound.instanceID)
        XCTAssertEqual(try fixture.request().requestID, bound.requestID)
        let permitFile = fixture.directory.appending(path: "commands/cmd-fixture/handoff.json")
        let permit = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(permitFile)) as? [String: Any])
        XCTAssertEqual(permit["targetPID"] as? Int, 202, "The second coordinator must not overwrite the concrete worker's target permit")
        try fixture.result(bound, status: "claimed")
        let claimed = await fixture.coordinator.poll()
        XCTAssertEqual(claimed?.submitted, 1)
        XCTAssertEqual(claimed?.attention, 0)
    }

    func testClaimedWorkCannotLookAliveWhenItsAccountOrganizationOrConversationDisappears() async throws {
        for unavailable in ["account", "organization", "conversation"] {
            let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
            await fixture.sourceRuntime(); let batch = try await fixture.prepare()
            try await fixture.coordinator.activate(batch); try await fixture.runtime(profile: fixture.target, pid: 202)
            _ = await fixture.coordinator.poll(); try fixture.result(fixture.request(), status: "queued")
            if unavailable == "conversation" {
                let bucket = try XCTUnwrap(fixture.target.readableBucket)
                try FileManager.default.removeItem(at: fixture.target.url.appending(path: bucket.relativePath).appending(path: "local_\(fixture.sessionID).json"))
            } else {
                let config: [String: String] = ["lastKnownAccountUuid": unavailable == "account" ? "another-account" : "account-target",
                    "dxt:allowlistLastUpdated:another-org": "2026-10-27T00:00:00Z"]
                try AtomicFile.write(JSONSerialization.data(withJSONObject: config), to: fixture.target.url.appending(path: "config.json"))
            }
            let summary = await fixture.coordinator.poll()
            XCTAssertEqual(summary?.attention, 1, unavailable)
            XCTAssertEqual(summary?.submitted, 0, unavailable)
            XCTAssertEqual(try fixture.request().pid, 202)
        }
    }

    func testAContendedFileLockCannotHideAnUnavailableClaimantOrBlockThePoll() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime(); let batch = try await fixture.prepare()
        try await fixture.coordinator.activate(batch); try await fixture.runtime(profile: fixture.target, pid: 202)
        _ = await fixture.coordinator.poll(); try fixture.result(fixture.request(), status: "queued")
        let lockFile = fixture.directory.appending(path: "locks/\(fixture.sessionID).lock")
        let fd = Darwin.open(lockFile.path, O_RDWR)
        guard fd >= 0 else { XCTFail("Request lock file was not created"); return }
        defer { _ = Darwin.close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer { _ = flock(fd, LOCK_UN) }
        await fixture.inspector.setSessions([], profile: fixture.target.url)
        let unavailable = await fixture.coordinator.poll()
        XCTAssertEqual(unavailable?.attention, 1, "Observed liveness failure must be visible even if its error cannot be written")
        XCTAssertEqual(unavailable?.submitted, 0)
        XCTAssertNil(try fixture.request().runtimeError, "The external lock must really have refused the write")
        XCTAssertEqual(try fixture.request().pid, 202)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        let persisted = await fixture.coordinator.poll()
        XCTAssertEqual(persisted?.attention, 1)
        XCTAssertNotNil(try fixture.request().runtimeError)
    }

    func testEquivalentRegistryBirthWhitespaceDoesNotMarkAValidClaimantAsDead() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime(); let batch = try await fixture.prepare()
        try await fixture.coordinator.activate(batch); try await fixture.runtime(profile: fixture.target, pid: 202)
        let file = fixture.directory.appending(path: "runtimes/\(fixture.sessionID)/runtime-202.json")
        var report = try JSONDecoder().decode(NativeRuntimeReport.self, from: AtomicFile.read(file))
        report.procStart = report.procStart.replacingOccurrences(of: " ", with: "  ")
        try AtomicFile.write(JSONEncoder().encode(report), to: file)
        _ = await fixture.coordinator.poll(); try fixture.result(fixture.request(), status: "claimed")
        let summary = await fixture.coordinator.poll()
        XCTAssertEqual(summary?.submitted, 1)
        XCTAssertEqual(summary?.attention, 0)
        XCTAssertNil(try fixture.request().runtimeError)
    }

    func testLegacyQueuedReceiptWithActualChildExecutionIsPresentedAsExecution() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime(); let batch = try await fixture.prepare()
        try await fixture.coordinator.activate(batch); try await fixture.runtime(profile: fixture.target, pid: 202)
        _ = await fixture.coordinator.poll()
        try fixture.result(fixture.request(), status: "queued", evidence: [NativeRecoveryEvidence(tool: "Bash", agentID: "original-agent", outcome: "toolResultReturned", timestamp: 1)])
        let summary = await fixture.coordinator.poll()
        XCTAssertEqual(summary?.executing, 1)
        XCTAssertEqual(summary?.submitted, 0)
    }

    func testOtherOriginalConversationOpensOnceThenReturnsToThePrimaryAfterHandshake() async throws {
        let opener = NativeCoordinatorTestOpener()
        let fixture = try NativeRecoveryFixture(opener: opener); defer { fixture.cleanup() }
        let other = "session-background"
        try fixture.writeConversation(completed: false, sessionID: other)
        await fixture.inspector.setSessions([
            NativeProcessSession(sessionID: fixture.sessionID, pid: 101, startedAt: fixture.clock.now().addingTimeInterval(-20), busy: true),
            NativeProcessSession(sessionID: other, pid: 102, startedAt: fixture.clock.now().addingTimeInterval(-20), busy: true)
        ], profile: fixture.source.url)
        var batch = try await fixture.prepare(expectedCount: 2)
        batch.operation.primaryDesktopSessionID = "local_" + fixture.sessionID
        try await fixture.coordinator.activate(batch)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        _ = await fixture.coordinator.poll()
        let opened = await opener.calls()
        XCTAssertEqual(opened, ["local_" + other])
        _ = await fixture.coordinator.poll()
        let stillWaiting = await opener.calls()
        XCTAssertEqual(stillWaiting, opened, "A delivered link is not a runtime handshake and must not be retried")
        try await fixture.runtime(profile: fixture.target, pid: 203, sessionID: other)
        _ = await fixture.coordinator.poll()
        let restored = await opener.calls()
        XCTAssertEqual(restored, ["local_" + other, "local_" + fixture.sessionID])
        _ = await fixture.coordinator.poll()
        let final = await opener.calls()
        XCTAssertEqual(final, restored, "Returning to the original chat is also one-shot")
    }

    func testDeniedOpeningIsVisibleWithoutRetryAndManualHandshakeCanStillContinue() async throws {
        let opener = NativeCoordinatorTestOpener(deny: true)
        let fixture = try NativeRecoveryFixture(opener: opener); defer { fixture.cleanup() }
        await fixture.sourceRuntime()
        let batch = try await fixture.prepare()
        try await fixture.coordinator.activate(batch)
        let denied = await fixture.coordinator.poll()
        XCTAssertEqual(denied?.attention, 1)
        XCTAssertNotNil(try fixture.request().activationError)
        _ = await fixture.coordinator.poll()
        let calls = await opener.calls()
        XCTAssertEqual(calls.count, 1)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        let connected = await fixture.coordinator.poll()
        XCTAssertEqual(connected?.waiting, 1)
        XCTAssertNil(try fixture.request().activationError)
        XCTAssertEqual(try fixture.request().phase, "armed")
    }

    func testOpenedConversationWithoutPluginTimesOutWithoutReopening() async throws {
        let opener = NativeCoordinatorTestOpener()
        let fixture = try NativeRecoveryFixture(opener: opener); defer { fixture.cleanup() }
        await fixture.sourceRuntime()
        let batch = try await fixture.prepare()
        try await fixture.coordinator.activate(batch)
        _ = await fixture.coordinator.poll()
        fixture.clock.advance(by: 31)
        let timedOut = await fixture.coordinator.poll()
        XCTAssertEqual(timedOut?.attention, 1)
        _ = await fixture.coordinator.poll()
        let calls = await opener.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertNotEqual(try fixture.request().phase, "armed")
    }

    func testPreparedWorkWaitsUntilTheSwitchActivatesTheOperation() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime()
        let batch = try await fixture.prepare()
        try await fixture.runtime(profile: fixture.target, pid: 202)
        let before = await fixture.coordinator.poll()
        XCTAssertNil(before)
        XCTAssertEqual(try fixture.request().phase, "prepared")
        try await fixture.coordinator.activate(batch)
        let after = await fixture.coordinator.poll()
        XCTAssertEqual(after?.waiting, 1, "Arming is not evidence of executing the work")
        let armed = try fixture.request()
        XCTAssertEqual(armed.phase, "armed")
        XCTAssertEqual(armed.pid, 202)
        XCTAssertEqual(armed.instanceID, "runtime-202")
    }

    func testColdLaunchWithoutLiveSourceDoesNotReviveHistoricalWork() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        let primary = try ContinuityInspector(paths: fixture.paths).capture(profile: fixture.source)
        let batch = try await fixture.coordinator.prepare(source: fixture.source, target: fixture.target,
                                                          primary: primary, claudeWasOpen: false)
        XCTAssertNil(batch)
        XCTAssertNil(fixture.activeOperation())
        XCTAssertNil(fixture.optionalRequest())
    }

    func testOldPluginCapabilityCannotArmARequestThatRequiresTheRecoveryFixes() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime()
        let batch = try await fixture.prepare()
        try await fixture.coordinator.activate(batch)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        let oldReport = NativeRuntimeReport(sessionID: fixture.sessionID, instanceID: "runtime-202", pid: 202,
            procStart: TaskGuardEvaluator.registryStartTime(fixture.clock.now()),
            reportedAt: fixture.clock.now().timeIntervalSince1970 * 1000, capabilities: ["native-recovery-v1", "native-recovery-v2", "native-recovery-v3"])
        try AtomicFile.write(JSONEncoder().encode(oldReport),
            to: fixture.directory.appending(path: "runtimes/\(fixture.sessionID)/runtime-202.json"))
        _ = await fixture.coordinator.poll()
        XCTAssertEqual(try fixture.request().phase, "prepared")
        XCTAssertNil(try fixture.request().instanceID)
        fixture.clock.advance(by: 1)
        try await fixture.runtime(profile: fixture.target, pid: 303)
        _ = await fixture.coordinator.poll()
        XCTAssertEqual(try fixture.request().phase, "armed")
        XCTAssertEqual(try fixture.request().pid, 303)
    }

    func testOldRuntimeOrFailedOwnershipValidationCannotArmWork() async throws {
        for invalidOwnership in [false, true] {
            let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
            await fixture.sourceRuntime()
            let batch = try await fixture.prepare()
            try await fixture.coordinator.activate(batch)
            try await fixture.runtime(profile: fixture.target, pid: 202,
                born: invalidOwnership ? fixture.clock.now() : fixture.clock.now().addingTimeInterval(-1),
                ownershipValid: !invalidOwnership)
            let summary = await fixture.coordinator.poll()
            XCTAssertEqual(summary?.waiting, 1)
            XCTAssertEqual(try fixture.request().phase, "prepared")
            XCTAssertNil(try fixture.request().instanceID)
        }
    }

    func testUnopenedConversationRemainsWaitingUntilItsOwnRuntimeActivates() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime(busy: false)
        let batch = try await fixture.prepare()
        try await fixture.coordinator.activate(batch)
        let waiting = await fixture.coordinator.poll()
        XCTAssertEqual(waiting?.waiting, 1)
        XCTAssertEqual(waiting?.ended, 0)
        XCTAssertEqual(try fixture.request().phase, "prepared")
        fixture.clock.advance(by: 5)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        _ = await fixture.coordinator.poll()
        XCTAssertEqual(try fixture.request().phase, "armed")
    }

    func testRapidSecondSwitchInvalidatesTheFirstGenerationAndOldCancel() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime()
        let first = try await fixture.prepare()
        try await fixture.coordinator.activate(first)
        fixture.clock.advance(by: 1)
        let secondOptional = try await fixture.coordinator.prepare(source: fixture.target, target: fixture.third,
                                                                   primary: nil, claudeWasOpen: true)
        let second = try XCTUnwrap(secondOptional)
        XCTAssertNotEqual(first.operation.operationID, second.operation.operationID)
        XCTAssertEqual(second.requests.count, 1, "Unconsumed work follows the next switch")
        try await fixture.coordinator.activate(first)
        await fixture.coordinator.cancel(first)
        XCTAssertEqual(fixture.activeOperation()?.operationID, second.operation.operationID)
        XCTAssertEqual(fixture.activeOperation()?.ready, false)
        try await fixture.coordinator.activate(second)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        _ = await fixture.coordinator.poll()
        XCTAssertEqual(try fixture.request().phase, "prepared", "The intermediate account cannot consume the new generation")
        fixture.clock.advance(by: 1)
        try await fixture.runtime(profile: fixture.third, pid: 303)
        _ = await fixture.coordinator.poll()
        let request = try fixture.request()
        XCTAssertEqual(request.operationID, second.operation.operationID)
        XCTAssertEqual(request.targetProfile, fixture.third.folder.name)
        XCTAssertEqual(request.pid, 303)
        XCTAssertEqual(request.phase, "armed")
    }

    func testRollbackCanBindTheNewSourceRuntimeLaunchedBeforeRedirectWasRecorded() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime()
        let original = try await fixture.prepare()
        fixture.clock.advance(by: 1)
        // Existing rollback launches the fallback before redirect() is called.
        try await fixture.runtime(profile: fixture.source, pid: 404)
        fixture.clock.advance(by: 1)
        let redirectedOptional = try await fixture.coordinator.redirect(original, to: fixture.source)
        let redirected = try XCTUnwrap(redirectedOptional)
        XCTAssertNotEqual(redirected.operation.operationID, original.operation.operationID)
        _ = await fixture.coordinator.poll()
        let request = try fixture.request()
        XCTAssertEqual(request.targetProfile, fixture.source.folder.name)
        XCTAssertEqual(request.phase, "armed")
        XCTAssertEqual(request.pid, 404)
    }

    func testUserStoppedSourceIsNeverArmedInTheTargetAccount() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        try await fixture.runtime(profile: fixture.source, pid: 101,
                                  born: fixture.clock.now().addingTimeInterval(-20), userStopped: true)
        let batch = try await fixture.prepare()
        XCTAssertTrue(try XCTUnwrap(batch.requests.first).sourceUserStopped)
        try await fixture.coordinator.activate(batch)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        // The person's own stop is no problem to report: nothing is shown, and the operation ends.
        let summary = await fixture.coordinator.poll()
        XCTAssertNil(summary)
        XCTAssertNotNil(fixture.activeOperation()?.finishedAt)
        XCTAssertNotEqual(try fixture.request().phase, "armed")
    }

    func testAContinuationThatGaveWayToThePersonIsFinalAndNotReported() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime(); let batch = try await fixture.prepare()
        try await fixture.coordinator.activate(batch); try await fixture.runtime(profile: fixture.target, pid: 202)
        _ = await fixture.coordinator.poll()
        try fixture.result(fixture.request(), status: "yielded")
        // The runtime reports the person's stop too; a settled receipt is not held against it.
        try fixture.report(pid: 202, userStopped: true)
        let summary = await fixture.coordinator.poll()
        XCTAssertNil(summary)
        XCTAssertNil(try fixture.request().runtimeError)
        XCTAssertNotNil(fixture.activeOperation()?.finishedAt)
    }

    func testOnlyACommandTheHostListsAndThePluginDoesNotProtectHoldsTheSwitch() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        try await f.runtime(profile: f.source, pid: 101)
        // Work that needs the model cannot go on in a spent account anyway, and an empty or missing
        // list adds nothing: only a command that closing Claude would end holds the switch.
        let cases: [(NativeHostWorkInventory?, AutoSwitchPauseReason?)] = [
            (nil, nil),
            (.init(), nil),
            (.init(backgroundTasks: [.init(id: "shell-before-plugin", type: "shell", status: "running")]), .commandRunning),
            (.init(backgroundTasks: [.init(id: "helper", type: "subagent", status: "running")]), nil),
            (.init(backgroundTasks: [.init(id: "watcher", type: "monitor", status: "running")]), nil),
            (.init(backgroundTasks: [.init(id: "unknown", type: "workflow", status: "running")]), nil),
        ]
        var baseline: Int?
        for (inventory, expected) in cases {
            try f.report(pid: 101, activeTasks: [], hostWorkInventory: inventory)
            let readiness = await f.coordinator.automaticSwitchReadiness(source: f.source)
            XCTAssertEqual(readiness.pause, expected, "\(String(describing: inventory))")
            // A manual switch goes on, and warns only about the command it ends.
            let primary = try ContinuityInspector(paths: f.paths).capture(profile: f.source)
            let prepared = try await f.coordinator.prepare(source: f.source, target: f.target, primary: primary, claudeWasOpen: true)
            let failures = try XCTUnwrap(prepared).captureFailures
            baseline = baseline ?? failures
            XCTAssertEqual(failures, (baseline ?? 0) + (expected == nil ? 0 : 1), "\(String(describing: inventory))")
        }
    }

    func testHostInventoryMatchesProtectedTasksWithoutReplacingLiveTracking() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        try await f.runtime(profile: f.source, pid: 101)
        let host = NativeHostWorkInventory(backgroundTasks: [
            .init(id: "shell-alias", type: "shell", status: "running"),
            .init(id: "agent", type: "subagent", status: "waiting"),
            .init(id: "monitor", type: "monitor", status: "running"),
        ])
        let tracked: [NativeRuntimeTask] = [
            .init(id: "shell", kind: .bash, jobID: "cmd-protected", aliases: ["shell-alias"]),
            .init(id: "agent", kind: .agent), .init(id: "monitor", kind: .monitor),
        ]
        try f.report(pid: 101, activeTasks: tracked, hostWorkInventory: host)
        let matched = await f.coordinator.automaticSwitchReadiness(source: f.source)
        XCTAssertNil(matched.pause, "Known identities retain the existing handoff and worker checks")
        try f.report(pid: 101, activeTasks: [.init(id: "shell-alias", kind: .agent)], hostWorkInventory: host)
        let wrongKind = await f.coordinator.automaticSwitchReadiness(source: f.source)
        XCTAssertEqual(wrongKind.pause, .commandRunning, "An ID alone cannot turn a shell into a recoverable agent")
        try f.report(pid: 101, activeTasks: [.init(id: "unprotected", kind: .bash)], hostWorkInventory: .init())
        let empty = await f.coordinator.automaticSwitchReadiness(source: f.source)
        XCTAssertEqual(empty.pause, .commandRunning, "Empty host data must not erase a live unprotected command")
        try f.report(pid: 101, activeTasks: [], hostWorkInventory: .init(
            backgroundTasks: [.init(id: "watch", type: "artifact-comment-monitor", status: "running")]))
        let watch = await f.coordinator.automaticSwitchReadiness(source: f.source)
        XCTAssertNil(watch.pause, "Comment watches keep their existing leave-on-source policy")
    }

    func testFinalHostInventoryIncludesStoppedBystandersWithoutRecoveryRequests() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        try f.writeConversation(completed: true, sessionID: "idle-bystander")
        try await f.runtime(profile: f.source, pid: 101)
        let birth = f.clock.now()
        await f.inspector.setSessions([
            .init(sessionID: f.sessionID, pid: 101, startedAt: birth, busy: false),
            .init(sessionID: "idle-bystander", pid: 102, startedAt: birth, busy: false),
        ], profile: f.source.url)
        try await f.inspector.setOwnership(pid: 102, profile: f.source.url, account: XCTUnwrap(f.source.identity), allowed: true)
        try f.report(pid: 101, born: birth, activeTasks: [])
        try f.report(pid: 102, userStopped: true, born: birth, sessionID: "idle-bystander", activeTasks: [])
        let primary = try ContinuityInspector(paths: f.paths).capture(profile: f.source)
        let prepared = try await f.coordinator.prepare(source: f.source, target: f.target, primary: primary, claudeWasOpen: true)
        let batch = try XCTUnwrap(prepared)
        XCTAssertEqual(batch.requests.map(\.sessionID), [f.sessionID])
        XCTAssertEqual(batch.captureFailures, 0)
        try f.report(pid: 102, userStopped: true, born: birth, sessionID: "idle-bystander", activeTasks: [],
            hostWorkInventory: .init(backgroundTasks: [.init(id: "bystander-shell", type: "shell", status: "running")]))
        let refreshed = await f.coordinator.refreshSourceStops(batch, source: f.source)
        XCTAssertGreaterThan(refreshed.captureFailures, batch.captureFailures,
                             "Stopping the bystander's reply does not end the command it started")
        XCTAssertEqual(refreshed.requests.map(\.sessionID), [f.sessionID], "The bystander must not become a continuation request")
        XCTAssertFalse(try XCTUnwrap(refreshed.requests.first).sourceUserStopped)
    }

    func testAStoppedBystandersUnprotectedHostCommandStillHoldsAutomaticClosing() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        try f.writeConversation(completed: true, sessionID: "bystander")
        try await f.runtime(profile: f.source, pid: 101)
        let birth = f.clock.now()
        await f.inspector.setSessions([
            .init(sessionID: f.sessionID, pid: 101, startedAt: birth, busy: false),
            .init(sessionID: "bystander", pid: 102, startedAt: birth, busy: false),
        ], profile: f.source.url)
        try await f.inspector.setOwnership(pid: 102, profile: f.source.url, account: XCTUnwrap(f.source.identity), allowed: true)
        try f.report(pid: 101, born: birth, activeTasks: [])
        try f.report(pid: 102, userStopped: true, born: birth, sessionID: "bystander", activeTasks: [],
            hostWorkInventory: .init(backgroundTasks: [.init(id: "bystander-shell", type: "shell", status: "running")]))
        let readiness = await f.coordinator.automaticSwitchReadiness(source: f.source, sessionID: f.sessionID)
        XCTAssertEqual(readiness.pause, .commandRunning, "Stopping a reply does not end the command it started")
    }

    func testAnAccountTheServiceStoppedHoldsAutomaticSwitchingFromAnyOfItsConversations() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        try f.writeConversation(completed: true, sessionID: "bystander")
        try await f.runtime(profile: f.source, pid: 101)
        let birth = f.clock.now(), ms = birth.timeIntervalSince1970 * 1_000
        await f.inspector.setSessions([
            .init(sessionID: f.sessionID, pid: 101, startedAt: birth, busy: false),
            .init(sessionID: "bystander", pid: 102, startedAt: birth, busy: false),
        ], profile: f.source.url)
        try await f.inspector.setOwnership(pid: 102, profile: f.source.url, account: XCTUnwrap(f.source.identity), allowed: true)
        let stopped = NativeQuotaBlock(reason: "accountRestricted", observedAt: ms, until: ms + 86_400_000)
        // A limit in one conversation and a running command change nothing, and neither does its reply being stopped.
        try f.report(pid: 101, born: birth, activeTasks: [NativeRuntimeTask(id: "once-approved-bash", kind: .bash)],
                     quotaBlock: NativeQuotaBlock(reason: "rateLimit", observedAt: ms, until: ms + 600_000))
        try f.report(pid: 102, userStopped: true, born: birth, sessionID: "bystander", activeTasks: [], quotaBlock: stopped)
        var readiness = await f.coordinator.automaticSwitchReadiness(source: f.source)
        XCTAssertEqual(readiness.pause, .accountRestricted)
        var hold = await f.coordinator.automaticSwitchHold(source: f.source)
        XCTAssertEqual(hold, .accountRestricted)
        // The automatic check gets this far with nothing else having run out.
        try f.report(pid: 101, born: birth, activeTasks: [])
        var reported = await f.coordinator.anyReportedQuotaBlock()
        XCTAssertTrue(reported)
        // A reply got through, or its window ended: nothing holds it any more.
        try f.report(pid: 102, born: birth, sessionID: "bystander", activeTasks: [])
        readiness = await f.coordinator.automaticSwitchReadiness(source: f.source)
        XCTAssertNil(readiness.pause)
        reported = await f.coordinator.anyReportedQuotaBlock()
        XCTAssertFalse(reported)
        try f.report(pid: 102, born: birth, sessionID: "bystander", activeTasks: [],
                     quotaBlock: NativeQuotaBlock(reason: "accountRestricted", observedAt: ms - 60_000, until: ms - 1))
        hold = await f.coordinator.automaticSwitchHold(source: f.source)
        XCTAssertNil(hold)
    }

    func testAutomaticCloseAlsoWaitsForAVerifiedBystandersUnprotectedBash() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        try fixture.writeConversation(completed: true, sessionID: "other-conversation")
        try await fixture.runtime(profile: fixture.source, pid: 101)
        let birth = fixture.clock.now()
        await fixture.inspector.setSessions([
            NativeProcessSession(sessionID: fixture.sessionID, pid: 101, startedAt: birth, busy: false),
            NativeProcessSession(sessionID: "other-conversation", pid: 102, startedAt: birth, busy: false),
        ], profile: fixture.source.url)
        try await fixture.inspector.setOwnership(pid: 102, profile: fixture.source.url,
                                                account: XCTUnwrap(fixture.source.identity), allowed: true)
        try fixture.report(pid: 101, born: birth, activeTasks: [NativeRuntimeTask(id: "protected-bash", kind: .bash, jobID: "cmd-existing")])
        try fixture.report(pid: 102, userStopped: true, born: birth, sessionID: "other-conversation",
                           activeTasks: [NativeRuntimeTask(id: "once-approved-bash", kind: .bash)])
        let blocked = await fixture.coordinator.automaticSwitchHold(source: fixture.source)
        XCTAssertEqual(blocked, .commandRunning, "Stopping a model turn does not stop its background Bash, and closing affects both conversations")
        try fixture.report(pid: 102, born: birth, sessionID: "other-conversation", activeTasks: [])
        let finished = await fixture.coordinator.automaticSwitchHold(source: fixture.source)
        XCTAssertNil(finished)
        try fixture.report(pid: 102, born: birth, sessionID: "other-conversation",
                           activeTasks: [NativeRuntimeTask(id: "unverified-bash", kind: .bash)])
        try await fixture.inspector.setOwnership(pid: 102, profile: fixture.source.url,
                                                account: XCTUnwrap(fixture.source.identity), allowed: false)
        let unverified = await fixture.coordinator.automaticSwitchHold(source: fixture.source)
        XCTAssertNil(unverified, "An unrelated or unverifiable report cannot block the selected account")
    }

    func testWorkInAConversationWithoutAPluginReportDoesNotHoldTheAutomaticSwitch() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        // The main conversation has work left in its history and sends no report; the other is idle and reports.
        try fixture.writeConversation(completed: true, sessionID: "reporting-conversation")
        let birth = fixture.clock.now()
        await fixture.inspector.setSessions([
            NativeProcessSession(sessionID: fixture.sessionID, pid: 101, startedAt: birth, busy: false),
            NativeProcessSession(sessionID: "reporting-conversation", pid: 102, startedAt: birth, busy: false),
        ], profile: fixture.source.url)
        for pid: Int32 in [101, 102] {
            try await fixture.inspector.setOwnership(pid: pid, profile: fixture.source.url,
                                                    account: XCTUnwrap(fixture.source.identity), allowed: true)
        }
        try fixture.report(pid: 102, born: birth, sessionID: "reporting-conversation")
        let unreported = await fixture.coordinator.automaticSwitchReadiness(source: fixture.source)
        XCTAssertNil(unreported.pause, "It goes on in the next account from its own history")
    }

    func testAHistoryThatCannotBeFollowedAfterTheCloseStillGoesOnWithoutReplayingWork() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        await f.sourceRuntime(busy: true)
        let captured = try await f.prepare()
        // Desktop's last write on closing names a parent the history does not hold.
        try f.writeConversation(completed: true, orphanTail: true)
        await f.inspector.setSessions([], profile: f.source.url)
        let reconciled = await f.coordinator.reconcileAfterClose(captured, source: f.source)
        let request = try XCTUnwrap(reconciled.requests.first)
        XCTAssertEqual(request.phase, "prepared", "The conversation still goes on")
        XCTAssertNil(request.activationError)
        XCTAssertTrue(request.sourceWasBusy)
        XCTAssertFalse(request.work.branchComplete, "Nothing is replayed from work that cannot be followed")
        XCTAssertEqual(reconciled.captureFailures, 0)
        let saved: NativeRecoveryRequest = try JSONDecoder().decode(NativeRecoveryRequest.self,
            from: AtomicFile.read(f.directory.appending(path: "requests/\(f.sessionID).json")))
        XCTAssertEqual(saved.phase, "prepared")
        XCTAssertFalse(saved.work.branchComplete)
    }

    func testAConversationWhoseHistoryCannotBeReadStillGoesOnAfterASwitch() async throws {
        guard geteuid() != 0 else { throw XCTSkip("POSIX read permissions do not constrain root") }
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        await f.sourceRuntime(busy: true)
        let transcript = f.paths.claudeCLIHome.appending(path: "projects/fixture/\(f.sessionID).jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: transcript.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcript.path) }
        let prepared = try await f.coordinator.prepare(source: f.source, target: f.target, primary: nil, claudeWasOpen: true)
        let batch = try XCTUnwrap(prepared)
        XCTAssertEqual(batch.captureFailures, 0)
        XCTAssertEqual(batch.requests.count, 1)
        let request = try XCTUnwrap(batch.requests.first)
        XCTAssertEqual(request.phase, "prepared")
        XCTAssertTrue(request.sourceWasBusy)
        XCTAssertFalse(request.work.branchComplete)
        XCTAssertTrue(request.work.tasks.isEmpty, "Nothing is guessed from a history that was not read")
        XCTAssertEqual(request.desktopSessionID, "local_\(f.sessionID)")
    }

    func testAHandoffThatCannotBeSavedTakesBackTheExitPermitsItWrote() async throws {
        guard geteuid() != 0 else { throw XCTSkip("POSIX write permissions do not constrain root") }
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        try await f.installCommand()
        await f.sourceRuntime(busy: true)
        let requests = f.directory.appending(path: "requests")
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: requests.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: requests.path) }
        let primary = try ContinuityInspector(paths: f.paths).capture(profile: f.source)
        do {
            _ = try await f.coordinator.prepare(source: f.source, target: f.target, primary: primary, claudeWasOpen: true)
            XCTFail("The request could not be written")
        } catch {}
        // Nobody holds this batch to cancel it: the command must not outlive its conversation on its permit.
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appending(path: "commands/cmd-fixture/handoff.json").path))
        XCTAssertNil(f.activeOperation())
    }

    func testASecondHandoffThatCannotBeSavedLeavesTheFirstOneWaiting() async throws {
        guard geteuid() != 0 else { throw XCTSkip("POSIX write permissions do not constrain root") }
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        try await f.installCommand()
        await f.sourceRuntime(busy: true)
        let first = try await f.prepare()
        try await f.coordinator.activate(first)
        let permitFile = f.directory.appending(path: "commands/cmd-fixture/handoff.json")
        let request = try AtomicFile.read(f.directory.appending(path: "requests/\(f.sessionID).json"))
        let permit = try AtomicFile.read(permitFile)
        // Before the target took it up, the next switch carries it on, and its requests cannot be written.
        let requests = f.directory.appending(path: "requests")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: requests.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: requests.path) }
        do {
            _ = try await f.coordinator.prepare(source: f.target, target: f.third, primary: nil, claudeWasOpen: false)
            XCTFail("The request could not be written")
        } catch {}
        // The first handoff is still there to be taken up, with the permit that keeps its command.
        XCTAssertEqual(f.activeOperation()?.operationID, first.operation.operationID)
        XCTAssertEqual(f.activeOperation()?.ready, true)
        XCTAssertEqual(try AtomicFile.read(f.directory.appending(path: "requests/\(f.sessionID).json")), request)
        XCTAssertEqual(try AtomicFile.read(permitFile), permit)
    }

    func testASecondHandoffCalledOffBeforeClosingLeavesTheFirstOneWaiting() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        try await f.installCommand()
        await f.sourceRuntime(busy: true)
        let first = try await f.prepare()
        try await f.coordinator.activate(first)
        let requestFile = f.directory.appending(path: "requests/\(f.sessionID).json")
        let permitFile = f.directory.appending(path: "commands/cmd-fixture/handoff.json")
        let request = try AtomicFile.read(requestFile), permit = try AtomicFile.read(permitFile)
        // Before the target took it up, the next switch carries it on, then stops short of closing Claude.
        let second = try await f.coordinator.prepare(source: f.target, target: f.third, primary: nil, claudeWasOpen: true)
        XCTAssertEqual(f.activeOperation()?.operationID, second?.operation.operationID)
        XCTAssertNotEqual(try AtomicFile.read(permitFile), permit)
        await f.coordinator.cancel(second)
        // The first handoff is still there to be taken up, with the permit that keeps its command.
        XCTAssertEqual(f.activeOperation()?.operationID, first.operation.operationID)
        XCTAssertEqual(f.activeOperation()?.ready, true)
        XCTAssertEqual(try AtomicFile.read(requestFile), request)
        XCTAssertEqual(try AtomicFile.read(permitFile), permit)
    }

    func testAHandoffCalledOffOnceClaudeClosedBringsNothingBack() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        try await f.installCommand()
        await f.sourceRuntime(busy: true)
        let first = try await f.prepare()
        try await f.coordinator.activate(first)
        let prepared = try await f.coordinator.prepare(source: f.target, target: f.third, primary: nil, claudeWasOpen: true)
        let closed = await f.coordinator.reconcileAfterClose(try XCTUnwrap(prepared), source: f.target)
        await f.coordinator.cancel(closed)
        // The runtime the first handoff waited for is gone with that Claude.
        XCTAssertNil(f.activeOperation())
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appending(path: "commands/cmd-fixture/handoff.json").path))
    }

    func testANoteForAnAccountThatDidNotOpenAfterAllIsTakenBack() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        try f.writeConversation(completed: true, armedWatch: true)
        let born = f.clock.now().addingTimeInterval(-20)
        try await f.runtime(profile: f.source, pid: 101, born: born)
        try f.report(pid: 101, born: born, activeTasks: [], watchReopen: true)
        let batch = try await f.prepare(expectedCount: 0)
        await f.coordinator.recordLeftWatches(batch.leftWatches, account: f.source.folder)
        let started = await f.coordinator.prepareLeftWatchReopen(profile: f.source, excluding: [])
        XCTAssertEqual(started.map(\.sessionID), [f.sessionID])
        let noteFile = f.directory.appending(path: "watch-reopen/\(f.sessionID).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteFile.path))
        // That Claude never came up. The conversation waits for its account again, and no note is
        // left that a start somewhere else could take for its own.
        await f.coordinator.recordLeftWatches(started, account: f.source.folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: noteFile.path))
        let kept = await f.coordinator.leftWatches()
        XCTAssertEqual(kept[f.source.folder]?.map(\.sessionID), [f.sessionID])
        // A note for a start on another account is that account's.
        let other = NativeWatchReopen(sessionID: f.sessionID, until: f.clock.now().timeIntervalSince1970 * 1_000 + 60_000,
                                      account: f.third.folder.name)
        try AtomicFile.write(JSONEncoder().encode(other), to: noteFile)
        await f.coordinator.recordLeftWatches(started, account: f.source.folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteFile.path))
    }

    func testAnEarlierRequestThatCannotBeReadStopsTheNextHandoffBeforeItWritesAnything() async throws {
        guard geteuid() != 0 else { throw XCTSkip("POSIX permissions do not constrain root") }
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        try f.writeConversation(completed: false, sessionID: "second-conversation")
        let birth = f.clock.now().addingTimeInterval(-20)
        await f.inspector.setSessions([
            NativeProcessSession(sessionID: f.sessionID, pid: 101, startedAt: birth, busy: true),
            NativeProcessSession(sessionID: "second-conversation", pid: 102, startedAt: birth, busy: true),
        ], profile: f.source.url)
        let first = try await f.prepare(expectedCount: 2)
        try await f.coordinator.activate(first)
        let files = ["active.json", "requests/second-conversation.json", "requests/\(f.sessionID).json"].map { f.directory.appending(path: $0) }
        let before = files.map { try? AtomicFile.read($0) }
        // The next switch captures both again: the first one's earlier request cannot be read, and the
        // second one's cannot be saved, its lock being held elsewhere.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: files[1].path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files[1].path) }
        let lock = Darwin.open(f.directory.appending(path: "locks/\(f.sessionID).lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        defer { _ = flock(lock, LOCK_UN); _ = Darwin.close(lock) }
        do {
            _ = try await f.coordinator.prepare(source: f.source, target: f.third, primary: nil, claudeWasOpen: true)
            XCTFail("The handoff could not be prepared")
        } catch {}
        // What could not be read could not be put back, so nothing was written over.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files[1].path)
        XCTAssertEqual(files.map { try? AtomicFile.read($0) }, before)
    }

    func testNothingLeftToCarryOnDoesNotHoldTheAutomaticSwitch() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        // One reply was stopped by hand, the other conversation is done: the next account is still of use.
        try fixture.writeConversation(completed: true, sessionID: "finished-conversation")
        let birth = fixture.clock.now()
        await fixture.inspector.setSessions([
            NativeProcessSession(sessionID: fixture.sessionID, pid: 101, startedAt: birth, busy: false),
            NativeProcessSession(sessionID: "finished-conversation", pid: 102, startedAt: birth, busy: false),
        ], profile: fixture.source.url)
        for pid: Int32 in [101, 102] {
            try await fixture.inspector.setOwnership(pid: pid, profile: fixture.source.url,
                                                    account: XCTUnwrap(fixture.source.identity), allowed: true)
        }
        try fixture.report(pid: 101, userStopped: true, born: birth)
        try fixture.report(pid: 102, born: birth, sessionID: "finished-conversation")
        let stopped = await fixture.coordinator.automaticSwitchReadiness(source: fixture.source)
        XCTAssertNil(stopped.pause)
    }

    func testAWatchAloneDoesNotCarryAConversationAcrossASwitch() async throws {
        // The page belongs to the account that published it; the target account cannot open it.
        let idle = try NativeRecoveryFixture(); defer { idle.cleanup() }
        try idle.writeConversation(completed: true, armedWatch: true)
        await idle.sourceRuntime(busy: false); try idle.report(pid: 101, activeTasks: [])
        _ = try await idle.prepare(expectedCount: 0)

        // Work carries a conversation and its recorded watch; once that work ends during the
        // close, the watch alone does not keep it.
        let busy = try NativeRecoveryFixture(); defer { busy.cleanup() }
        try busy.writeConversation(completed: false, armedWatch: true)
        await busy.sourceRuntime(busy: true)
        let captured = try await busy.prepare()
        XCTAssertEqual(captured.requests.first?.work.artifacts.first?.state, "armed")
        try busy.writeConversation(completed: true, armedWatch: true)
        await busy.inspector.setSessions([], profile: busy.source.url)
        let reconciled = await busy.coordinator.reconcileAfterClose(captured, source: busy.source)
        XCTAssertEqual(reconciled.requests.first?.phase, "resolved")
    }

    func testTheAutomaticCheckDoesNotWaitOnHistories() async throws {
        guard geteuid() != 0 else { throw XCTSkip("POSIX read permissions do not constrain root") }
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        try f.writeConversation(completed: true, armedWatch: true)
        // Its turn is under way and its plugin reports it.
        await f.sourceRuntime(busy: true); try f.report(pid: 101, activeTasks: [])
        try await f.inspector.setOwnership(pid: 101, profile: f.source.url, account: XCTUnwrap(f.source.identity), allowed: true)
        let transcript = f.paths.claudeCLIHome.appending(path: "projects/fixture/\(f.sessionID).jsonl")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcript.path) }
        // A comment watch does not hold the switch back; it stays with this account.
        var readiness = await f.coordinator.automaticSwitchReadiness(source: f.source)
        XCTAssertNil(readiness.pause)
        XCTAssertEqual(readiness.runtime?.sessionID, f.sessionID)
        // Only the reports are read: a history that cannot be read holds nothing back.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: transcript.path)
        readiness = await f.coordinator.automaticSwitchReadiness(source: f.source)
        XCTAssertNil(readiness.pause)
    }

    func testAConversationKeptForItsWatchStartsAgainOnceWhenItsAccountOpens() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        try f.writeConversation(completed: true, armedWatch: true)
        let bucket = try XCTUnwrap(f.source.readableBucket)
        let file = f.source.url.appending(path: bucket.relativePath).appending(path: "local_\(f.sessionID).json")
        var object = try SessionJSON.object(AtomicFile.read(file), at: file)
        object["title"] = "Review the page"
        try AtomicFile.write(JSONSerialization.data(withJSONObject: object), to: file)
        let born = f.clock.now().addingTimeInterval(-20)
        try await f.runtime(profile: f.source, pid: 101, born: born)
        // Without a plugin that keeps that start from a model turn, nothing is kept for later.
        try f.report(pid: 101, born: born, activeTasks: [])
        var batch = try await f.prepare(expectedCount: 0)
        XCTAssertEqual(batch.leftWatches, [])
        try f.report(pid: 101, born: born, activeTasks: [], watchReopen: true)
        batch = try await f.prepare(expectedCount: 0)
        XCTAssertEqual(batch.leftWatches.map(\.sessionID), [f.sessionID])
        XCTAssertEqual(batch.leftWatches.first?.title, "Review the page")
        await f.coordinator.recordLeftWatches(batch.leftWatches, account: f.source.folder)
        var kept = await f.coordinator.leftWatches()
        XCTAssertEqual(kept[f.source.folder]?.map(\.desktopSessionID), ["local_\(f.sessionID)"])
        // A conversation the opening carries on is left to it.
        var started = await f.coordinator.prepareLeftWatchReopen(profile: f.source, excluding: [f.sessionID])
        XCTAssertEqual(started, [])
        await f.coordinator.recordLeftWatches(batch.leftWatches, account: f.source.folder)
        started = await f.coordinator.prepareLeftWatchReopen(profile: f.source, excluding: [])
        XCTAssertEqual(started.map(\.sessionID), [f.sessionID])
        object = try SessionJSON.object(AtomicFile.read(file), at: file)
        XCTAssertNotNil(object["interruptedByQuitAt"])
        XCTAssertEqual(object["interruptedAwaitingPerson"] as? Bool, false)
        let noteFile = f.directory.appending(path: "watch-reopen/\(f.sessionID).json")
        let note = try JSONDecoder().decode(NativeWatchReopen.self, from: AtomicFile.read(noteFile))
        XCTAssertEqual(note.sessionID, f.sessionID)
        XCTAssertNil(note.used)
        // It names the account, for the plugin to tell that account's own watch from another's.
        XCTAssertEqual(note.account, f.source.folder.name)
        kept = await f.coordinator.leftWatches()
        XCTAssertNil(kept[f.source.folder])
        // The record stays, marked, to tell the other accounts whose page it is.
        let record = f.directory.appending(path: "left-watches/\(f.source.folder.name).json")
        XCTAssertEqual(try JSONDecoder().decode([NativeLeftWatch].self, from: AtomicFile.read(record)).map(\.opened), [true])
        started = await f.coordinator.prepareLeftWatchReopen(profile: f.source, excluding: [])
        XCTAssertEqual(started, [], "Once only")
        // The note goes once the plugin used it.
        await f.coordinator.prune()
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteFile.path))
        try AtomicFile.write(JSONEncoder().encode(NativeWatchReopen(sessionID: f.sessionID, until: note.until, used: true)), to: noteFile)
        await f.coordinator.prune()
        XCTAssertFalse(FileManager.default.fileExists(atPath: noteFile.path))
    }

    func testAWatchStaysWithTheAccountThatPublishedItsPageAlsoWhenItsConversationGoesOn() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        try f.writeConversation(completed: false, armedWatch: true)
        let born = f.clock.now().addingTimeInterval(-20)
        try await f.runtime(profile: f.source, pid: 101, born: born)
        try f.report(pid: 101, born: born, activeTasks: [], watchReopen: true)
        // The work goes on in the target account, which cannot open the page: the watch is kept
        // for this account, by the page's plain link.
        var batch = try await f.prepare()
        XCTAssertEqual(batch.leftWatches.map(\.sessionID), [f.sessionID])
        XCTAssertEqual(batch.leftWatches.first?.pages, ["https://claude.ai/artifact/artifact-1"])
        // A page already waiting for another account stays with that one, whether its
        // conversation goes on or stays.
        let kept = try XCTUnwrap(batch.leftWatches.first)
        await f.coordinator.recordLeftWatches([kept], account: f.third.folder)
        batch = try await f.prepare()
        XCTAssertEqual(batch.leftWatches, [])
        try f.writeConversation(completed: true, armedWatch: true)
        batch = try await f.prepare(expectedCount: 0)
        XCTAssertEqual(batch.leftWatches, [])
        // An older record, without pages, holds every watch of its conversation.
        let older = NativeLeftWatch(desktopSessionID: kept.desktopSessionID, sessionID: f.sessionID, title: nil, leftAt: kept.leftAt)
        await f.coordinator.recordLeftWatches([older], account: f.third.folder)
        batch = try await f.prepare(expectedCount: 0)
        XCTAssertEqual(batch.leftWatches, [])
        // Once that account has opened, by CC-Relay or not, the page is still its own: nothing
        // waits for it any more, but no other account takes the page for its own.
        _ = await f.coordinator.prepareLeftWatchReopen(profile: f.third, excluding: [f.sessionID])
        batch = try await f.prepare(expectedCount: 0)
        XCTAssertEqual(batch.leftWatches, [])
        await f.coordinator.recordLeftWatches([kept], account: f.third.folder)
        var opened = await f.coordinator.markLeftWatchesOpened(account: f.third.folder)
        XCTAssertTrue(opened)
        opened = await f.coordinator.markLeftWatchesOpened(account: f.third.folder)
        XCTAssertFalse(opened, "Nothing waits any more")
        let waiting = await f.coordinator.leftWatches()
        XCTAssertNil(waiting[f.third.folder])
        let started = await f.coordinator.prepareLeftWatchReopen(profile: f.third, excluding: [])
        XCTAssertEqual(started, [])
        batch = try await f.prepare(expectedCount: 0)
        XCTAssertEqual(batch.leftWatches, [])
    }

    func testEachOpenClaudeIsListedWithItsAccountOnlyWhenThatChanges() async throws {
        let f = try NativeRecoveryFixture(); defer { f.cleanup() }
        let file = f.directory.appending(path: "open-accounts.json")
        let born = Date(timeIntervalSince1970: 1_793_000_000.75)
        let instance = ClaudeInstance(pid: 501, profileDirectory: f.source.url, hasExplicitProfileFlag: true,
                                      startedAt: born, executableURL: URL(fileURLWithPath: "/Applications/Claude.app/Contents/MacOS/Claude"))
        await f.coordinator.recordOpenAccounts([NativeOpenAccount(instance, account: f.source.folder)])
        let listed = try JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [[String: Any]]
        // The start as the process list shows it, to the second and in UTC, so the plugin finds the
        // Claude it runs under among its own parent processes.
        XCTAssertEqual(listed?.first?["pid"] as? Int, 501)
        XCTAssertEqual(listed?.first?["procStart"] as? String, "Mon Oct 26 07:33:20 2026")
        XCTAssertEqual(listed?.first?["account"] as? String, f.source.folder.name)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)
        await f.coordinator.recordOpenAccounts([NativeOpenAccount(instance, account: f.source.folder)])
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(modified, Date(timeIntervalSince1970: 0), "Unchanged, it is not written again")
        await f.coordinator.recordOpenAccounts([])
        XCTAssertEqual(try JSONDecoder().decode([NativeOpenAccount].self, from: AtomicFile.read(file)), [])
    }

    func testIdleConversationsWithoutArmedWatchesRemainClosed() async throws {
        for stopped in [false, true] {
            let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
            try fixture.writeConversation(completed: true, armedWatch: stopped, watchState: "stopped")
            await fixture.sourceRuntime(busy: false); try fixture.report(pid: 101, activeTasks: [])
            _ = try await fixture.prepare(expectedCount: 0)
        }
    }

    func testStopArrivingAfterCaptureIsHonoredBeforeDesktopExits() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        try await fixture.runtime(profile: fixture.source, pid: 101,
                                  born: fixture.clock.now().addingTimeInterval(-20), userStopped: false)
        let prepared = try await fixture.prepare()
        fixture.clock.advance(by: 0.5)
        try fixture.report(pid: 101, userStopped: true)
        let stopped = await fixture.coordinator.refreshSourceStops(prepared, source: fixture.source)
        await fixture.inspector.setSessions([], profile: fixture.source.url)
        let reconciled = await fixture.coordinator.reconcileAfterClose(stopped, source: fixture.source)
        try await fixture.coordinator.activate(reconciled)
        fixture.clock.advance(by: 0.5)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        _ = await fixture.coordinator.poll()
        XCTAssertTrue(try fixture.request().sourceUserStopped)
        XCTAssertNotEqual(try fixture.request().phase, "armed")
    }

    func testWorkCompletedDuringCloseIsNotRevived() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime(busy: true)
        let prepared = try await fixture.prepare()
        XCTAssertTrue(try XCTUnwrap(prepared.requests.first).sourceWasBusy)
        try fixture.writeConversation(completed: true, profiles: [fixture.source])
        await fixture.inspector.setSessions([], profile: fixture.source.url)
        let reconciled = await fixture.coordinator.reconcileAfterClose(prepared, source: fixture.source)
        try await fixture.coordinator.activate(reconciled)
        fixture.clock.advance(by: 1)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        let summary = await fixture.coordinator.poll()
        XCTAssertNotEqual(fixture.optionalRequest()?.phase, "armed")
        XCTAssertEqual(summary?.submitted ?? 0, 0)
        XCTAssertEqual(summary?.executing ?? 0, 0)
    }

    func testFailedPostCloseCaptureBlocksThatSessionInsteadOfArmingStaleWork() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime()
        let prepared = try await fixture.prepare()
        let path = try XCTUnwrap(prepared.requests.first).work.transcriptPath
        try FileManager.default.removeItem(atPath: path)
        let reconciled = await fixture.coordinator.reconcileAfterClose(prepared, source: fixture.source)
        XCTAssertEqual(reconciled.captureFailures, 1)
        try await fixture.coordinator.activate(reconciled)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        let summary = await fixture.coordinator.poll()
        XCTAssertEqual(summary?.attention, 1)
        XCTAssertEqual(try fixture.request().phase, "blocked")
    }

    func testRollbackPreservesBlockedAndResolvedWorkWithoutOpeningOrArmingIt() async throws {
        for expectedPhase in ["blocked", "resolved"] {
            let opener = NativeCoordinatorTestOpener()
            let fixture = try NativeRecoveryFixture(opener: opener); defer { fixture.cleanup() }
            await fixture.sourceRuntime()
            let prepared = try await fixture.prepare()
            if expectedPhase == "blocked" {
                try FileManager.default.removeItem(atPath: try XCTUnwrap(prepared.requests.first).work.transcriptPath)
            } else {
                try fixture.writeConversation(completed: true, profiles: [fixture.source])
            }
            let reconciled = await fixture.coordinator.reconcileAfterClose(prepared, source: fixture.source)
            XCTAssertEqual(try fixture.request().phase, expectedPhase)
            let verificationError = try fixture.request().activationError
            fixture.clock.advance(by: 1)
            let redirected = try await fixture.coordinator.redirect(reconciled, to: fixture.source)
            XCTAssertNotNil(redirected)
            try await fixture.runtime(profile: fixture.source, pid: 404)
            let summary = await fixture.coordinator.poll()
            XCTAssertEqual(try fixture.request().phase, expectedPhase)
            XCTAssertEqual(try fixture.request().activationError, verificationError)
            XCTAssertNil(try fixture.request().instanceID)
            XCTAssertEqual(summary?.attention, expectedPhase == "blocked" ? 1 : 0)
            XCTAssertEqual(summary?.inspected, expectedPhase == "resolved" ? 1 : 0)
            let calls = await opener.calls()
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testMissingArchivedOrReplacedSourceRecordFailsPostCloseVerification() async throws {
        for change in ["missing", "archived", "replaced"] {
            let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
            await fixture.sourceRuntime()
            let prepared = try await fixture.prepare()
            let bucket = try XCTUnwrap(fixture.source.readableBucket)
            let file = fixture.source.url.appending(path: bucket.relativePath).appending(path: "local_\(fixture.sessionID).json")
            if change == "missing" { try FileManager.default.removeItem(at: file) }
            else {
                var row = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
                if change == "archived" { row["isArchived"] = true }
                else { row["cliSessionId"] = "another-session" }
                try AtomicFile.write(JSONSerialization.data(withJSONObject: row), to: file)
            }
            let reconciled = await fixture.coordinator.reconcileAfterClose(prepared, source: fixture.source)
            XCTAssertEqual(reconciled.captureFailures, 1, change)
            try await fixture.coordinator.activate(reconciled)
            try await fixture.runtime(profile: fixture.target, pid: 202)
            let summary = await fixture.coordinator.poll()
            XCTAssertEqual(try fixture.request().phase, "blocked", change)
            XCTAssertEqual(summary?.attention, 1, change)
        }
    }

    func testAnOperationIsPolledOftenWhileFreshRarelyLaterAndNotAtAllOnceFinal() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        let nothing = await fixture.coordinator.pace()
        XCTAssertEqual(nothing, .idle)
        await fixture.sourceRuntime()
        let prepared = try await fixture.prepare()
        let unready = await fixture.coordinator.pace()
        XCTAssertEqual(unready, .idle, "nothing can be armed before the target is open")
        try await fixture.coordinator.activate(prepared)
        let fresh = await fixture.coordinator.pace()
        XCTAssertEqual(fresh, .fast)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        let running = await fixture.coordinator.poll()
        XCTAssertEqual(running?.finished, false)
        fixture.clock.advance(by: 16 * 60)
        let later = await fixture.coordinator.pace()
        XCTAssertEqual(later, .slow, "a conversation may still be opened by hand")
        let evidence = NativeRecoveryEvidence(tool: "Read", toolUseID: "verified-tool", agentID: nil, taskID: nil,
                                              outcome: "toolResultReturned", timestamp: fixture.clock.now().timeIntervalSince1970 * 1000)
        try fixture.result(fixture.request(), status: "turnFinished", evidence: [evidence])
        let last = await fixture.coordinator.poll()
        XCTAssertEqual(last?.finished, true)
        XCTAssertEqual(last?.ended, 1)
        let done = await fixture.coordinator.pace()
        XCTAssertEqual(done, .idle)
    }

    func testTheSummaryNamesBothAccountsAndKeepsItsLastWordUntilTheConversationsHadTimeToReport() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime()
        let prepared = try await fixture.prepare()
        try await fixture.coordinator.activate(prepared)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        _ = await fixture.coordinator.poll()
        let evidence = NativeRecoveryEvidence(tool: "Read", toolUseID: "verified-tool", agentID: nil, taskID: nil,
                                              outcome: "toolResultReturned", timestamp: fixture.clock.now().timeIntervalSince1970 * 1000)
        try fixture.result(fixture.request(), status: "turnFinished", evidence: [evidence])
        let early = await fixture.coordinator.poll()
        XCTAssertEqual(early?.from, fixture.source.folder)
        XCTAssertEqual(early?.to, fixture.target.folder)
        XCTAssertEqual(early?.ended, 1)
        XCTAssertEqual(early?.settling, true)
        XCTAssertEqual(early?.finished, false, "a problem held back meanwhile must still be shown")
        let watched = await fixture.coordinator.pace()
        XCTAssertEqual(watched, .fast)
        fixture.clock.advance(by: NativeRecoverySummary.settlingTime)
        let settled = await fixture.coordinator.poll()
        XCTAssertEqual(settled?.settling, false)
        XCTAssertEqual(settled?.finished, true)
        let done = await fixture.coordinator.pace()
        XCTAssertEqual(done, .idle)
    }

    func testPruningKeepsWhatIsLiveOrRecentAndRemovesWhatNothingReads() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        let now = fixture.clock.now().timeIntervalSince1970 * 1000, day = 86_400_000.0
        func write(_ object: [String: Any], _ path: String) throws {
            try AtomicFile.write(JSONSerialization.data(withJSONObject: object), to: fixture.directory.appending(path: path))
        }
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: fixture.directory.appending(path: path).path) }
        let report: (Double) -> [String: Any] = { ["version": 1, "sessionID": "s", "instanceID": "i", "pid": 5, "procStart": "x",
                                                   "reportedAt": $0, "busy": false, "userStopped": false, "capabilities": []] }
        try write(report(now - 2 * day), "runtimes/old-session/old-instance.json")
        try write(report(now - 60_000), "runtimes/live-session/live-instance.json")
        var info = proc_bsdinfo()
        _ = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        let born = (Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000) * 1000
        func command(_ job: String, status: String, worker: (Int32, Double), updated: Double) throws {
            try write(["version": 1, "jobID": job, "sessionID": "s", "status": status, "owner": ["pid": 5, "start": 1],
                       "worker": ["pid": worker.0, "start": worker.1], "updatedAt": updated], "commands/\(job)/state.json")
        }
        try command("cmd-ended", status: "completed", worker: (999_999, 1), updated: now - 4 * day)
        try command("cmd-recent", status: "failed", worker: (999_999, 1), updated: now - day)
        try command("cmd-long-running", status: "running", worker: (getpid(), born), updated: now - 9 * day)
        try write(["version": 1, "operationID": "old-op", "requestID": "r", "sessionID": "s", "instanceID": "i", "pid": 5,
                   "status": "turnFinished", "updatedAt": now - day, "evidence": []], "results/old.json")
        await fixture.coordinator.prune()
        XCTAssertFalse(exists("runtimes/old-session"), "a runtime silent for a day is gone, folder included")
        XCTAssertTrue(exists("runtimes/live-session/live-instance.json"))
        XCTAssertFalse(exists("commands/cmd-ended"), "an ended command goes after three days")
        XCTAssertTrue(exists("commands/cmd-recent/state.json"))
        XCTAssertTrue(exists("commands/cmd-long-running/state.json"), "a live worker is never touched, however old its record")
        XCTAssertTrue(exists("results/old.json"), "receipts stay for a week")
        fixture.clock.advance(by: 8 * 86_400)
        await fixture.coordinator.prune()
        XCTAssertFalse(exists("results/old.json"))
        XCTAssertTrue(exists("commands/cmd-long-running/state.json"))
    }

    func testSuccessfulFinalReceiptsSurviveRequestExpiry() async throws {
        for status in ["inspected", "turnFinished"] {
            let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
            await fixture.sourceRuntime()
            let prepared = try await fixture.prepare()
            try await fixture.coordinator.activate(prepared)
            try await fixture.runtime(profile: fixture.target, pid: 202)
            _ = await fixture.coordinator.poll()
            let evidence = NativeRecoveryEvidence(tool: "Read", toolUseID: "verified-tool", agentID: nil,
                taskID: nil, outcome: "toolResultReturned", timestamp: fixture.clock.now().timeIntervalSince1970 * 1000)
            try fixture.result(fixture.request(), status: status, evidence: [evidence])
            fixture.clock.advance(by: NativeRecoverySummary.settlingTime)
            let before = await fixture.coordinator.poll()
            fixture.clock.advance(by: 86_401)
            let after = await fixture.coordinator.poll()
            XCTAssertEqual(after, before, status)
            XCTAssertEqual(after?.attention, 0, status)
            XCTAssertEqual(after?.inspected, status == "inspected" ? 1 : 0)
            XCTAssertEqual(after?.ended, status == "turnFinished" ? 1 : 0)
        }
    }

    func testExpiredUnfinishedOrInvalidReceiptsStillNeedAttention() async throws {
        for status in ["claimed", "queued", "executing", "turnFinished", "corrupt", "none"] {
            let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
            await fixture.sourceRuntime()
            let prepared = try await fixture.prepare()
            try await fixture.coordinator.activate(prepared)
            try await fixture.runtime(profile: fixture.target, pid: 202)
            _ = await fixture.coordinator.poll()
            let request = try fixture.request()
            if status == "corrupt" {
                try AtomicFile.write(Data("partial receipt".utf8), to: fixture.directory.appending(path: "results/\(request.requestID).json"))
            } else if status == "turnFinished" {
                // A turn over is final; one whose every step failed still needs the person.
                try fixture.result(request, status: status, evidence: [NativeRecoveryEvidence(tool: "Bash", toolUseID: "failed-step",
                    agentID: nil, taskID: nil, outcome: "blockedOrFailed", timestamp: fixture.clock.now().timeIntervalSince1970 * 1000)])
            } else if status != "none" { try fixture.result(request, status: status) }
            fixture.clock.advance(by: 86_401)
            let summary = await fixture.coordinator.poll()
            XCTAssertEqual(summary?.attention, 1, status)
            XCTAssertEqual(summary?.ended, 0, status)
            XCTAssertEqual(summary?.inspected, 0, status)
        }
    }

    func testClaimedWorkIsNotCarriedFromStaleSnapshotWhenNoRuntimeCanBeRecaptured() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime()
        let prepared = try await fixture.prepare()
        try await fixture.coordinator.activate(prepared)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        _ = await fixture.coordinator.poll()
        let request = try fixture.request()
        // Even a partial receipt means an effect may already have happened.
        try AtomicFile.write(Data("partial receipt".utf8),
                             to: fixture.directory.appending(path: "results/\(request.requestID).json"))
        await fixture.inspector.setSessions([], profile: fixture.target.url)
        let next = try await fixture.coordinator.prepare(source: fixture.target, target: fixture.third,
                                                         primary: nil, claudeWasOpen: true)
        XCTAssertNil(next)
        XCTAssertNil(fixture.activeOperation())
    }

    func testASubmissionIsNotAnEndAndAnEndedTurnRanUnlessEveryStepItTookFailed() async throws {
        let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
        await fixture.sourceRuntime()
        let batch = try await fixture.prepare()
        try await fixture.coordinator.activate(batch)
        try await fixture.runtime(profile: fixture.target, pid: 202)
        _ = await fixture.coordinator.poll()
        let request = try fixture.request()
        try fixture.result(request, status: "submitted")
        let submitted = await fixture.coordinator.poll()
        XCTAssertEqual(submitted?.submitted, 1)
        XCTAssertEqual(submitted?.ended, 0)
        func evidence(_ outcome: String) -> NativeRecoveryEvidence {
            NativeRecoveryEvidence(tool: "Bash", toolUseID: "step-\(outcome)", agentID: nil, taskID: nil, outcome: outcome,
                                   timestamp: fixture.clock.now().timeIntervalSince1970 * 1000)
        }
        // Finished in words alone: it ran.
        try fixture.result(request, status: "turnFinished",
                           evidence: [evidence("parentPromptQueued"), evidence("continuationTurnStarted"), evidence("continuationTurnEnded")])
        let words = await fixture.coordinator.poll()
        XCTAssertEqual(words?.ended, 1)
        XCTAssertEqual(words?.attention, 0)
        // Every step it took failed: that needs the person.
        try fixture.result(request, status: "turnFinished", evidence: [evidence("blockedOrFailed")])
        let failed = await fixture.coordinator.poll()
        XCTAssertEqual(failed?.attention, 1)
        XCTAssertEqual(failed?.ended, 0)
        try fixture.result(request, status: "turnFinished", evidence: [evidence("blockedOrFailed"), evidence("toolResultReturned")])
        let worked = await fixture.coordinator.poll()
        XCTAssertEqual(worked?.ended, 1)
        XCTAssertEqual(worked?.attention, 0)
    }

    func testCommandsOfAReplyStoppedByHandThatTheSwitchEndedAreToldWithoutAWarning() async throws {
        // (status the worker records, how long after the switch began, counted)
        for (status, after, counted) in [("stopped", 1.0, 1), ("running", -20.0, 1), ("completed", 1.0, 0), ("stopped", -5.0, 0)] {
            let fixture = try NativeRecoveryFixture(); defer { fixture.cleanup() }
            await fixture.sourceRuntime(); try await fixture.installCommand()
            let prepared = try await fixture.prepare()
            try fixture.report(pid: 101, userStopped: true)
            let stopped = await fixture.coordinator.refreshSourceStops(prepared, source: fixture.source)
            let request = try XCTUnwrap(stopped.requests.first)
            XCTAssertTrue(request.sourceUserStopped)
            try await fixture.coordinator.activate(stopped)
            try await fixture.runtime(profile: fixture.target, pid: 202)
            let file = fixture.directory.appending(path: "commands/cmd-fixture/state.json")
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
            record["status"] = status; record["updatedAt"] = request.createdAt + after * 1000
            try AtomicFile.write(JSONSerialization.data(withJSONObject: record), to: file)
            let summary = await fixture.coordinator.poll()
            XCTAssertEqual(summary?.endedWithSwitch ?? 0, counted, "\(status) \(after)")
            XCTAssertEqual(summary?.attention ?? 0, 0, "\(status) \(after)")
            XCTAssertEqual(summary?.total ?? 0, counted, "\(status) \(after)")
        }
    }
}

@MainActor
private final class NativeRecoveryFixture {
    let scratch: ScratchDirectory
    let paths: AppPaths
    let clock = TestClock()
    let inspector = NativeCoordinatorTestInspector()
    let coordinator: NativeRecoveryCoordinator
    let source: ProfileSnapshot
    let target: ProfileSnapshot
    let third: ProfileSnapshot
    let sessionID = "session-main"
    var directory: URL { paths.companionDataDirectory.appending(path: "NativeRecovery") }

    init(opener: (any NativeConversationOpening)? = nil, requestByteLimit: Int = 4_000_000) throws {
        scratch = try ScratchDirectory(); paths = scratch.paths
        source = try Self.profile(paths: paths, name: "Claude_source", account: "account-source", organization: "org-source")
        target = try Self.profile(paths: paths, name: "Claude_target", account: "account-target", organization: "org-target")
        third = try Self.profile(paths: paths, name: "Claude_third", account: "account-third", organization: "org-third")
        coordinator = NativeRecoveryCoordinator(paths: paths, inspector: inspector, opener: opener, clock: clock, requestByteLimit: requestByteLimit)
        try writeConversation(completed: false)
    }

    func installCommand() async throws {
        let task = NativeRuntimeTask(id: "original-task", kind: .monitor, toolUseID: "original-monitor", jobID: "cmd-fixture",
                                     deadlineAt: clock.now().addingTimeInterval(300).timeIntervalSince1970 * 1000)
        let record: [String: Any] = ["version": 1, "executionProtocol": 3, "jobID": "cmd-fixture", "sessionID": sessionID, "status": "running",
            "owner": ["pid": 101, "start": clock.now().addingTimeInterval(-20).timeIntervalSince1970 * 1000]]
        try AtomicFile.write(JSONSerialization.data(withJSONObject: record), to: directory.appending(path: "commands/cmd-fixture/state.json"))
        try await inspector.setOwnership(pid: 101, profile: source.url, account: XCTUnwrap(source.identity), allowed: true)
        try report(pid: 101, activeTasks: [task])
    }

    func changeCommand(_ update: (inout [String: Any]) -> Void) throws {
        let file = directory.appending(path: "commands/cmd-fixture/state.json")
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        update(&state)
        try AtomicFile.write(JSONSerialization.data(withJSONObject: state), to: file)
    }

    func cleanup() { scratch.cleanup() }

    func sourceRuntime(busy: Bool = true) async {
        await inspector.setSessions([NativeProcessSession(sessionID: sessionID, pid: 101,
            startedAt: clock.now().addingTimeInterval(-20), busy: busy)], profile: source.url)
    }

    func prepare(expectedCount: Int = 1) async throws -> NativeRecoveryBatch {
        let primary = try ContinuityInspector(paths: paths).capture(profile: source)
        let batch = try await coordinator.prepare(source: source, target: target, primary: primary, claudeWasOpen: true)
        let value = try XCTUnwrap(batch)
        XCTAssertEqual(value.captureFailures, 0)
        XCTAssertEqual(value.requests.count, expectedCount)
        return value
    }

    func runtime(profile: ProfileSnapshot, pid: Int32, born: Date? = nil,
                 userStopped: Bool = false, ownershipValid: Bool = true, sessionID: String? = nil) async throws {
        let sessionID = sessionID ?? self.sessionID
        let birth = born ?? clock.now()
        await inspector.setSessions([NativeProcessSession(sessionID: sessionID, pid: pid, startedAt: birth, busy: false)], profile: profile.url)
        await inspector.setOwnership(pid: pid, profile: profile.url,
                                     account: try XCTUnwrap(profile.identity), allowed: ownershipValid)
        try report(pid: pid, userStopped: userStopped, born: birth, sessionID: sessionID)
    }

    func report(pid: Int32, userStopped: Bool = false, born: Date? = nil, sessionID: String? = nil,
                activeTasks: [NativeRuntimeTask]? = nil, quotaBlock: NativeQuotaBlock? = nil, watchReopen: Bool = false,
                hostWorkInventory: NativeHostWorkInventory? = nil) throws {
        let sessionID = sessionID ?? self.sessionID
        var report = NativeRuntimeReport(sessionID: sessionID, instanceID: "runtime-\(pid)", pid: pid,
            procStart: TaskGuardEvaluator.registryStartTime(born ?? clock.now().addingTimeInterval(-20)),
            reportedAt: clock.now().timeIntervalSince1970 * 1000, userStopped: userStopped, activeTasks: activeTasks,
            quotaBlock: quotaBlock, hostWorkInventory: hostWorkInventory)
        if watchReopen { report.capabilities.append(NativeRecoveryCoordinator.watchReopenCapability) }
        try write(report, to: directory.appending(path: "runtimes/\(sessionID)/runtime-\(pid).json"))
    }

    func request() throws -> NativeRecoveryRequest {
        try JSONDecoder().decode(NativeRecoveryRequest.self,
                                from: AtomicFile.read(directory.appending(path: "requests/\(sessionID).json")))
    }
    func optionalRequest() -> NativeRecoveryRequest? { try? request() }
    func activeOperation() -> NativeRecoveryOperation? {
        guard let data = try? AtomicFile.read(directory.appending(path: "active.json")) else { return nil }
        return try? JSONDecoder().decode(NativeRecoveryOperation.self, from: data)
    }

    func result(_ request: NativeRecoveryRequest, status: String, evidence: [NativeRecoveryEvidence] = []) throws {
        let result = NativeRecoveryResult(version: 1, operationID: request.operationID, requestID: request.requestID,
            sessionID: request.sessionID, instanceID: try XCTUnwrap(request.instanceID), pid: try XCTUnwrap(request.pid),
            status: status, updatedAt: clock.now().timeIntervalSince1970 * 1000,
            turnID: "continuation-turn", error: nil, evidence: evidence)
        try write(result, to: directory.appending(path: "results/\(request.requestID).json"))
    }

    func writeConversation(completed: Bool, profiles: [ProfileSnapshot]? = nil, sessionID: String? = nil,
                           laterQuestion: Bool = false, armedWatch: Bool = false, watchState: String = "armed",
                           orphanTail: Bool = false) throws {
        let sessionID = sessionID ?? self.sessionID
        let user = "native-user", call = "native-call", result = "native-result", tail = "native-tail"
        var rows: [[String: Any]] = [
            ["uuid": user, "parentUuid": NSNull(), "type": "user", "origin": ["kind": "human"],
             "message": ["content": "Continue the existing test work"]],
            ["uuid": call, "parentUuid": user, "type": "assistant", "message": ["stop_reason": "tool_use",
                "content": [["type": "tool_use", "id": "original-monitor", "name": "Monitor",
                             "input": ["command": "DO_NOT_EXECUTE", "description": "Observe fixture progress"]]]]],
            ["uuid": result, "parentUuid": call, "type": "user", "toolUseResult": ["taskId": "original-task"],
             "message": ["content": [["type": "tool_result", "tool_use_id": "original-monitor", "content": "registered"]]]],
            ["uuid": tail, "parentUuid": result, "type": "assistant", "message": ["stop_reason": "end_turn",
                "content": [["type": "text", "text": "Watching the task"]]]],
        ]
        var head = tail
        if completed {
            rows.append(["uuid": "native-done", "parentUuid": tail, "type": "user", "origin": ["kind": "task-notification"],
                "promptSource": "system", "message": ["content": "<task-notification><task-id>original-task</task-id><status>completed</status><summary>finished</summary></task-notification>"]])
            head = "native-final"
            rows.append(["uuid": head, "parentUuid": "native-done", "type": "assistant", "message": ["stop_reason": "end_turn",
                "content": [["type": "text", "text": "The requested work is complete"]]]])
        }
        if laterQuestion {
            rows.append(["uuid": "later-user", "parentUuid": head, "type": "user", "origin": ["kind": "human"],
                         "message": ["content": "Another question"]])
            head = "later-answer"
            rows.append(["uuid": head, "parentUuid": "later-user", "type": "assistant", "message": ["stop_reason": "end_turn",
                         "content": [["type": "text", "text": "Another answer"]]]])
        }
        if orphanTail {
            head = "native-orphan"
            rows.append(["uuid": head, "parentUuid": "native-missing", "type": "assistant", "message": ["stop_reason": "end_turn",
                         "content": [["type": "text", "text": "Written while closing"]]]])
        }
        if armedWatch {
            rows.append(["type": "artifact-comment-monitor", "v": 1,
                         "artifacts": ["artifact-1": ["state": watchState, "writtenAtMs": 1]]])
        }
        var transcript = Data()
        for var row in rows {
            row["sessionId"] = sessionID; row["timestamp"] = "2026-10-27T01:00:00Z"
            transcript.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); transcript.append(10)
        }
        try AtomicFile.write(transcript, to: paths.claudeCLIHome.appending(path: "projects/fixture/\(sessionID).jsonl"))
        for profile in profiles ?? [source, target, third] {
            let bucket = try XCTUnwrap(profile.readableBucket)
            let object: [String: Any] = ["sessionId": "local_" + sessionID, "cliSessionId": sessionID,
                "cwd": scratch.root.path, "lastFocusedAt": 100, "lastActivityAt": 100, "lastAssistantUuid": head]
            try AtomicFile.write(JSONSerialization.data(withJSONObject: object),
                to: profile.url.appending(path: bucket.relativePath).appending(path: "local_\(sessionID).json"))
        }
    }

    func writeMonitorHistory(count: Int) throws {
        var transcript = Data(), parent = "native-user"
        func row(_ object: [String: Any]) throws {
            var value = object; value["sessionId"] = sessionID; value["timestamp"] = "2026-10-27T01:00:00.000Z"
            transcript.append(try JSONSerialization.data(withJSONObject: value)); transcript.append(10)
        }
        try row(["uuid": "native-user", "parentUuid": NSNull(), "type": "user", "message": ["content": "Observe original work"]])
        for i in 0..<count {
            let call = "call-\(i)", result = "result-\(i)"
            try row(["uuid": call, "parentUuid": parent, "type": "assistant", "message": ["stop_reason": "tool_use", "content": [
                ["type": "tool_use", "id": "use-\(i)", "name": "Monitor", "input": ["command": "DO_NOT_RUN", "description": String(repeating: "x", count: 240)]]]]])
            try row(["uuid": result, "parentUuid": call, "type": "user", "toolUseResult": ["taskId": "task-\(i)"], "message": ["content": [
                ["type": "tool_result", "tool_use_id": "use-\(i)", "content": "registered"]]]])
            parent = result
            if i < count - 1 {
                let notice = "done-\(i)"
                try row(["uuid": notice, "parentUuid": parent, "type": "user", "origin": ["kind": "task-notification"], "promptSource": "system", "message": ["content":
                    "<task-notification><task-id>task-\(i)</task-id><status>completed</status></task-notification>"]])
                parent = notice
            }
        }
        try row(["uuid": "native-tail", "parentUuid": parent, "type": "assistant", "message": ["stop_reason": "end_turn", "content": "Watching"]])
        try AtomicFile.write(transcript, to: paths.claudeCLIHome.appending(path: "projects/fixture/\(sessionID).jsonl"))
    }

    private func write<T: Encodable>(_ value: T, to file: URL) throws {
        try AtomicFile.write(JSONEncoder().encode(value), to: file)
    }

    private static func profile(paths: AppPaths, name: String, account: String, organization: String) throws -> ProfileSnapshot {
        let folder = try ProfileFolder(name), url = paths.claudeProfilesRoot.appending(path: name)
        let identity = AccountIdentity(accountUUID: account, activeOrganizationUUID: organization)
        let bucket = try SessionBucket(accountUUID: account, organizationUUID: organization)
        try AtomicFile.write(JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": account,
            "dxt:allowlistLastUpdated:\(organization)": "2026-10-27T00:00:00Z"]), to: url.appending(path: "config.json"))
        return ProfileSnapshot(folder: folder, url: url, status: .signedIn(identity), sessionBuckets: [bucket], readableBucket: bucket)
    }
}

private actor NativeCoordinatorTestInspector: NativeRuntimeInspecting {
    private var processLists: [String: [NativeProcessSession]] = [:]
    private var ownership: [Int32: (profile: String, account: AccountIdentity, allowed: Bool)] = [:]
    private var pausePID: Int32?
    private var validationWaiter: CheckedContinuation<Void, Never>?
    private var pausedSessionsProfile: String?
    private var sessionsWaiter: CheckedContinuation<Void, Never>?
    var sessionsPaused: Bool { sessionsWaiter != nil }
    func pauseSessions(profile: URL) { pausedSessionsProfile = profile.path }
    func resumeSessions() { sessionsWaiter?.resume(); sessionsWaiter = nil }
    var validationPaused: Bool { validationWaiter != nil }
    func pauseValidation(pid: Int32) { pausePID = pid }
    func resumeValidation() { validationWaiter?.resume(); validationWaiter = nil }
    func setSessions(_ sessions: [NativeProcessSession], profile: URL) { processLists[profile.path] = sessions }
    func setOwnership(pid: Int32, profile: URL, account: AccountIdentity, allowed: Bool) {
        ownership[pid] = (profile.path, account, allowed)
    }
    func sessions(profile: URL) async -> [NativeProcessSession] {
        if pausedSessionsProfile == profile.path {
            pausedSessionsProfile = nil
            await withCheckedContinuation { sessionsWaiter = $0 }
        }
        return processLists[profile.path] ?? []
    }
    func validate(_ report: NativeRuntimeReport, profile: URL, account: AccountIdentity) async -> Bool {
        if pausePID == report.pid {
            pausePID = nil
            await withCheckedContinuation { validationWaiter = $0 }
        }
        guard let owned = ownership[report.pid] else { return false }
        return owned.allowed && owned.profile == profile.path && owned.account.accountUUID == account.accountUUID &&
            owned.account.activeOrganizationUUID == account.activeOrganizationUUID
    }
}

private actor NativeCoordinatorTestOpener: NativeConversationOpening {
    private var recorded: [String] = []
    private let deny: Bool
    init(deny: Bool = false) { self.deny = deny }
    func open(profile: URL, account: AccountIdentity, desktopSessionID: String) throws {
        recorded.append(desktopSessionID)
        if deny { throw CocoaError(.fileReadNoPermission) }
    }
    func calls() -> [String] { recorded }
}
