import Foundation
import XCTest
@testable import CompanionCore

@MainActor
final class SwitchCoordinatorTests: XCTestCase {
    func testSwitchSyncsBothWaysAndReopensBystanders() async throws {
        let h = try await EngineHarness(running: ["Claude", "Claude_Kxm8"])
        await h.start()
        let a = try h.profile("Claude"), b = try h.profile("Claude_204")
        h.process.onClose {
            let state = try? await h.store.load()
            XCTAssertEqual(state?.relaunchDebt.first, b.folder)
        }
        await h.engine.perform(.switchTo(folder: b.folder))
        let state = try await h.store.load()
        XCTAssertEqual(state.activeFolder, b.folder)
        XCTAssertTrue(state.relaunchDebt.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try h.sessionFile(b, id: "local_" + SandboxFixture.ID.liveSession).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try h.sessionFile(a, id: "local_" + SandboxFixture.ID.session204).path))
        XCTAssertEqual(Set(h.process.recordedLaunches().map { $0.profile.lastPathComponent }), ["Claude_204", "Claude_Kxm8"])
        await h.cleanup()
    }

    func testEverySwitchLeavesOneLineWithItsResultAndDuration() async throws {
        let h = try await EngineHarness(running: ["Claude"])
        await h.start()
        h.process.onClose { h.clock.advance(by: 7.5) }
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        // A click on the current account switches nothing and leaves no line.
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        var lines = try h.logLines(containing: " switch Switch ")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.hasSuffix("INFO switch Switch Claude -> Claude_204: switched in 7.5 s; tasks: none running") == true,
                      lines.first ?? "no line")
        await h.cleanup()

        // Separate worlds: a finished switch keeps confirming its conversation and moves the test clock.
        let failing = try await EngineHarness(running: ["Claude"])
        await failing.start()
        failing.process.failClose(.stillRunning(pids: [12, 13], names: ["Claude", "chrome_crashpad_handler"], stall: .reopened))
        await failing.engine.perform(.switchTo(folder: try failing.folder("Claude_Kxm8")))
        lines = try failing.logLines(containing: " switch Switch ")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.hasSuffix("WARNING switch Switch Claude -> Claude_Kxm8: failed after 0.0 s: couldNotCloseClaude "
            + "(2 processes still running: Claude, chrome_crashpad_handler; Claude opened again during the close); "
            + "tasks: none running") == true, lines.first ?? "no line")
        await failing.cleanup()
        // Each way a close stops says why, so a failure in real use can be told apart.
        let stalls: [(ClaudeProcessError.CloseStall, String)] = [
            (.reopened, "; Claude opened again during the close)"),
            (.notForced, "; not forced while a Code task ran)"),
            (.survivedForce, "; after a forced quit)"),
            (.outOfTime, "; the close ran out of time)"),
            (.unknown, ")"),
        ]
        for (stall, ending) in stalls {
            XCTAssertEqual(SwitchLog.closeDetail(ClaudeProcessError.stillRunning(pids: [12], names: ["Claude"], stall: stall)),
                           " (1 process still running: Claude" + ending)
        }

        let closed = try await EngineHarness(running: [])
        await closed.start()
        await closed.engine.perform(.switchTo(folder: try closed.folder("Claude_Kxm2")))
        lines = try closed.logLines(containing: " switch Switch ")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("INFO switch Switch Claude -> Claude_Kxm2: switched in 0.0 s; Claude was closed") == true,
                      lines.first ?? "no line")
        await closed.cleanup()
    }

    func testTheTaskCheckIsReportedApartFromTheSwitchItself() async throws {
        let busy = TaskActivity.busy([CodeTaskInfo(pid: 2, reason: .statusBusy)])
        var lines: [String] = []
        for choice in [TaskGuardChoice.waitThenSwitch, .switchNow, .cancel] {
            let h = try await EngineHarness(autoSync: false)
            await h.start()
            h.inspector.enqueue(busy)
            let target = try h.folder("Claude_204")
            let request = Task { await h.engine.perform(.switchTo(folder: target)) }
            let shown = await eventually { await h.snapshot().taskGuardPrompt != nil }
            XCTAssertTrue(shown)
            // Three seconds to decide; waiting then rechecks after five more.
            h.clock.advance(by: 3)
            await h.engine.perform(.taskGuard(choice))
            await request.value
            lines += try h.logLines(containing: " switch Switch ")
            await h.cleanup()
        }
        XCTAssertEqual(lines.count, 3)
        // Without sync the conversation has nowhere to reopen on the new account, hence the warning.
        XCTAssertTrue(lines[0].hasSuffix("Switch Claude -> Claude_204: switched in 0.0 s; tasks: waited 8.0 s; "
            + "warnings: conversationNotReopened"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("Switch Claude -> Claude_204: switched in 0.0 s; tasks: switched now after 3.0 s; "
            + "warnings: conversationNotReopened"), lines[1])
        XCTAssertTrue(lines[2].hasSuffix("INFO switch Switch Claude -> Claude_204: cancelled at the task check after 3.0 s"), lines[2])
    }

    func testSyncOffAndSameAccountNoOpAndColdLaunch() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        await h.engine.perform(.switchTo(folder: try h.folder("Claude")))
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.world.paths.companionDataDirectory.appending(path: "Backups").path))
        h.process.setInstances([])
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_Kxm8")))
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1)
        XCTAssertEqual(h.process.recordedLaunches().last?.profile.lastPathComponent, "Claude_Kxm8")
        await h.cleanup()
    }

    func testLeftoverHelpersAreCheckedForTasksAndClosedBeforeTheSwitch() async throws {
        let h = try await EngineHarness(running: [])
        await h.start()
        h.process.setLeftovers(true)
        let checksBefore = h.inspector.callCount()
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        XCTAssertGreaterThan(h.inspector.callCount(), checksBefore)
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1)
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude_204"])
        let running = try await h.process.runningInstances()
        XCTAssertEqual(running.map { $0.profileDirectory.lastPathComponent }, ["Claude_204"])
        let state = try await h.store.load()
        XCTAssertEqual(state.activeFolder?.name, "Claude_204")
        XCTAssertTrue(state.relaunchDebt.isEmpty)
        await h.cleanup()
    }

    func testBusyLeftoverTaskStopsTheSwitchWhenCancelled() async throws {
        let h = try await EngineHarness(running: [])
        await h.start()
        h.process.setLeftovers(true)
        h.inspector.enqueue(.busy([CodeTaskInfo(pid: 2, reason: .statusBusy)]))
        let target = try h.folder("Claude_204")
        let request = Task { await h.engine.perform(.switchTo(folder: target)) }
        let shown = await eventually { await h.snapshot().taskGuardPrompt != nil }
        XCTAssertTrue(shown)
        await h.engine.perform(.taskGuard(.cancel))
        await request.value
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        XCTAssertTrue(h.process.recordedLaunches().isEmpty)
        await h.cleanup()
    }

    func testSwitchWithClaudeClosedStillSyncsBothWays() async throws {
        let h = try await EngineHarness(running: [])
        await h.start()
        let a = try h.profile("Claude"), b = try h.profile("Claude_204")
        await h.engine.perform(.switchTo(folder: b.folder))
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try h.sessionFile(b, id: "local_" + SandboxFixture.ID.liveSession).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try h.sessionFile(a, id: "local_" + SandboxFixture.ID.session204).path))
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude_204"])
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .switched(to: b.folder, warnings: []))
        await h.cleanup()
    }

    func testReopeningTheClosedCurrentAccountDoesNotSyncItWithItself() async throws {
        let h = try await EngineHarness(running: [])
        await h.start()
        await h.engine.perform(.switchTo(folder: try h.folder("Claude")))
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.world.paths.companionDataDirectory.appending(path: "Backups").path))
        await h.cleanup()
    }

    func testInvalidTargetRefusesBeforeClose() async throws {
        let h = try await EngineHarness()
        await h.start()
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_missing")))
        var snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .switchTo(try h.folder("Claude_missing")), reason: .targetMissing))
        try AtomicFile.write(Data("broken".utf8), to: h.world.profileDirectory("Claude_204").appending(path: "config.json"))
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .switchTo(try h.folder("Claude_204")), reason: .targetUnreadable))
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        await h.cleanup()
    }

    func testPartialCloseRecoveryClearsDebtAndReopensExactlyClosedProfiles() async throws {
        let h = try await EngineHarness(running: ["Claude", "Claude_Kxm8", "Claude_Kxm2"])
        await h.start()
        let closed = [h.world.profileDirectory("Claude"), h.world.profileDirectory("Claude_Kxm8")]
        h.process.failClose(.stillRunning(pids: [12], closedProfiles: closed + [closed[0]]))
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude", "Claude_Kxm8"])
        XCTAssertTrue(h.process.recordedLaunches().allSatisfy { $0.deepLink == nil })
        let state = try await h.store.load()
        XCTAssertTrue(state.relaunchDebt.isEmpty)
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .switchTo(try h.folder("Claude_204")), reason: .couldNotCloseClaude))
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.world.paths.companionDataDirectory.appending(path: "Backups").path))
        await h.cleanup()
    }

    func testClosedProfileThatHasAlreadyReopenedIsNotLaunchedAgain() async throws {
        let h = try await EngineHarness(running: ["Claude", "Claude_Kxm8"])
        await h.start()
        let before = try await h.process.runningInstances()
        let reopened = try XCTUnwrap(before.last)
        h.process.simulateTransitions(false)
        h.process.failClose(.stillRunning(pids: [11], closedProfiles: before.map(\.profileDirectory)))
        h.process.onClose { h.process.setInstances([reopened]) }
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude"])
        await h.cleanup()
    }

    func testCloseWithoutEvidenceReopensNothingAndLaunchFailureIsTyped() async throws {
        for error in [ClaudeProcessError.stillRunning(pids: [10]), .processTableUnavailable] {
            let h = try await EngineHarness()
            await h.start()
            h.process.failClose(error)
            await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
            XCTAssertTrue(h.process.recordedLaunches().isEmpty)
            let afterClose = try await h.store.load()
            XCTAssertTrue(afterClose.relaunchDebt.isEmpty)
            await h.cleanup()
        }
        let h = try await EngineHarness(running: [])
        await h.start()
        h.process.enqueueLaunch(.failure(.failed("launch")))
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .switchTo(try h.folder("Claude_204")), reason: .couldNotOpenClaude))
        await h.cleanup()
    }

    func testBackupFailureStillSwitchesWithoutSync() async throws {
        let h = try await EngineHarness()
        await h.start()
        let backups = h.world.paths.companionDataDirectory.appending(path: "Backups")
        try AtomicFile.write(Data("blocked".utf8), to: backups)
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        let snapshot = await h.snapshot()
        guard case .switched(let to, let warnings) = snapshot.lastResult?.outcome else { return XCTFail("expected switch") }
        XCTAssertEqual(to.name, "Claude_204")
        XCTAssertTrue(warnings.contains(.backupFailed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try h.sessionFile(h.profile("Claude_204"), id: "local_" + SandboxFixture.ID.liveSession).path))
        await h.cleanup()
    }

    func testSyncPartialErrorsProduceWarning() async throws {
        let h = try await EngineHarness()
        await h.start()
        let b = try h.profile("Claude_204")
        let record = try h.sessionFile(b, id: "local_" + SandboxFixture.ID.session204)
        try AtomicFile.write(Data("invalid".utf8), to: record)
        await h.engine.perform(.switchTo(folder: b.folder))
        let snapshot = await h.snapshot()
        guard case .switched(_, let warnings) = snapshot.lastResult?.outcome else { return XCTFail("expected switch") }
        XCTAssertTrue(warnings.contains { if case .sessionsNotSynced = $0 { return true }; return false })
        await h.cleanup()
    }

    func testBusyWaitCancelOverrideUnknownAndForceRecheck() async throws {
        let busy = TaskActivity.busy([CodeTaskInfo(pid: 2, reason: .statusBusy)])
        for choice in [TaskGuardChoice.waitThenSwitch, .cancel, .switchNow] {
            let h = try await EngineHarness(autoSync: false)
            await h.start()
            h.inspector.enqueue(busy)
            let target = try h.folder("Claude_204")
            let request = Task { await h.engine.perform(.switchTo(folder: target)) }
            let shown = await eventually { await h.snapshot().taskGuardPrompt != nil }
            XCTAssertTrue(shown)
            await h.engine.perform(.switchTo(folder: try h.folder("Claude_Kxm8")))
            await h.engine.perform(.taskGuard(choice))
            await request.value
            XCTAssertEqual(h.process.recordedQuitTimeouts().count, choice == .cancel ? 0 : 1)
            // "Switch now" closes Claude at once: its own quit would ask about the tasks again.
            XCTAssertEqual(h.process.recordedImmediateQuits(), choice == .cancel ? [] : [choice == .switchNow])
            await h.cleanup()
        }
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        h.inspector.enqueue(.unknown("unavailable"))
        h.process.consultBeforeForce(closedProfilesWhenRefused: [])
        let target = try h.folder("Claude_204")
        let request = Task { await h.engine.perform(.switchTo(folder: target)) }
        let shown = await eventually { await h.snapshot().taskGuardPrompt?.unknown == true }
        XCTAssertTrue(shown)
        h.inspector.enqueue(busy)
        await h.engine.perform(.taskGuard(.switchNow))
        await request.value
        XCTAssertEqual(h.process.recordedBeforeForceAnswers(), [true])
        XCTAssertEqual(h.process.recordedImmediateQuits(), [true])
        await h.cleanup()

        let fresh = try await EngineHarness(autoSync: false)
        await fresh.start()
        fresh.inspector.enqueue(.idle)
        fresh.inspector.enqueue(busy)
        fresh.process.consultBeforeForce(closedProfilesWhenRefused: [])
        await fresh.engine.perform(.switchTo(folder: target))
        XCTAssertEqual(fresh.process.recordedBeforeForceAnswers(), [false])
        XCTAssertEqual(fresh.process.recordedImmediateQuits(), [false])
        XCTAssertTrue(fresh.process.recordedLaunches().isEmpty)
        await fresh.cleanup()
    }
}
