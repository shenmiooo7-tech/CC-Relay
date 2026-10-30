import Foundation
import XCTest
@testable import CompanionCore

@MainActor
final class RelaunchDebtTests: XCTestCase {
    func testFailedRelaunchStaysOwedAndTheNextPickupRetriesIt() async throws {
        let h = try await EngineHarness(running: [])
        let (debt, lifecycle) = makeLifecycle(h)
        let folders = try [h.folder("Claude"), h.folder("Claude_204")]
        try await debt.record(folders)
        h.process.enqueueLaunch(.failure(.failed("first launch")))
        try await lifecycle.relaunchOwed()
        var state = try await h.store.load()
        XCTAssertEqual(state.relaunchDebt, [folders[0]])
        try await lifecycle.relaunchOwed()
        state = try await h.store.load()
        XCTAssertTrue(state.relaunchDebt.isEmpty)
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude", "Claude_204", "Claude"])
        await h.cleanup()
    }

    func testAnUnwrittenSwitchRecordStillEndsTheClaims() async throws {
        let h = try await EngineHarness(running: [])
        let (debt, _) = makeLifecycle(h)
        let target = try h.folder("Claude_204"), previous = try h.folder("Claude")
        try await debt.record([target])
        _ = try await debt.claimSwitchTarget(target, fallback: previous)
        let directory = h.world.paths.companionDataDirectory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory)
        do {
            try await debt.finishSwitchTarget(target, fallback: previous, restorePrevious: true)
            XCTFail("expected the record write to fail")
        } catch {}
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
        let claimed = try await debt.claim(target)
        XCTAssertTrue(claimed)
        await h.cleanup()
    }

    func testProfileThatIsAlreadyOpenIsSettledWithoutASecondLaunch() async throws {
        let h = try await EngineHarness(running: ["Claude"])
        let (debt, lifecycle) = makeLifecycle(h)
        try await debt.record([h.folder("Claude"), h.folder("Claude_204")])
        try await lifecycle.relaunchOwed()
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude_204"])
        let state = try await h.store.load()
        XCTAssertTrue(state.relaunchDebt.isEmpty)
        await h.cleanup()
    }

    func testFailedTargetIsReportedAndStaysOwed() async throws {
        let h = try await EngineHarness(running: [])
        let (debt, lifecycle) = makeLifecycle(h)
        let target = try h.folder("Claude_204")
        try await debt.record([target])
        h.process.enqueueLaunch(.failure(.failed("target")))
        do {
            try await lifecycle.relaunchOwed(target: target)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? ClaudeProcessError, .launchFailed) }
        let state = try await h.store.load()
        XCTAssertEqual(state.relaunchDebt, [target])
        await h.cleanup()
    }

    func testReservedProfileIsNotTakenTwiceUntilSettled() async throws {
        let h = try await EngineHarness(running: [])
        let (debt, _) = makeLifecycle(h)
        let a = try h.folder("Claude"), b = try h.folder("Claude_204")
        try await debt.record([a, b])
        let first = try await debt.claim(a)
        let second = try await debt.claim(a)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        let rest = try await debt.claim()
        XCTAssertEqual(rest, [b])
        let target = try await debt.claimSwitchTarget(a, fallback: nil)
        XCTAssertNil(target)
        await debt.settle(a, opened: false)
        let again = try await debt.claim(a)
        XCTAssertTrue(again)
        await debt.settle(a, opened: true)
        await debt.settle(b, opened: true)
        let state = try await h.store.load()
        XCTAssertTrue(state.relaunchDebt.isEmpty)
        let missing = try await debt.claim(a)
        XCTAssertFalse(missing)
        await h.cleanup()
    }

    func testBystanderThatFailsToReopenDuringASwitchStaysOwed() async throws {
        let h = try await EngineHarness(running: ["Claude", "Claude_Kxm8"])
        await h.start()
        let bystander = h.world.profileDirectory("Claude_Kxm8")
        h.process.onLaunch { profile, _ in
            if ProfilePaths.same(profile, bystander) { throw FakeScriptError.failed("bystander") }
        }
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        let snapshot = await h.snapshot()
        guard case .switched(let to, _) = snapshot.lastResult?.outcome else { return XCTFail("expected a switch") }
        XCTAssertEqual(to.name, "Claude_204")
        let state = try await h.store.load()
        XCTAssertEqual(state.relaunchDebt, [try h.folder("Claude_Kxm8")])
        await h.cleanup()
    }

    func testABystanderThatFailedToReopenIsTriedAgainByTheNextSwitch() async throws {
        let h = try await EngineHarness(running: ["Claude", "Claude_Kxm8"])
        await h.start()
        let bystander = h.world.profileDirectory("Claude_Kxm8")
        h.process.onLaunch { profile, _ in
            if ProfilePaths.same(profile, bystander) { throw FakeScriptError.failed("bystander") }
        }
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        let before = h.process.recordedLaunches().count
        // The next switch closes only the account it leaves; the older record is not its to drop.
        await h.engine.perform(.switchTo(folder: try h.folder("Claude")))
        let launched = h.process.recordedLaunches().dropFirst(before).map { $0.profile.lastPathComponent }
        XCTAssertEqual(launched, ["Claude", "Claude_Kxm8"])
        let state = try await h.store.load()
        XCTAssertEqual(state.relaunchDebt, [try h.folder("Claude_Kxm8")])
        await h.cleanup()
    }

    func testAnOlderRecordWhoseProfileIsOpenAgainIsSettledByTheNextClose() async throws {
        let h = try await EngineHarness(running: ["Claude"])
        let (debt, lifecycle) = makeLifecycle(h)
        let reopened = try h.folder("Claude"), next = try h.folder("Claude_204")
        // Owed by an earlier operation, then opened again by hand: this close decides about it.
        try await debt.record([reopened])
        try await lifecycle.close(owing: [next])
        let state = try await h.store.load()
        XCTAssertEqual(state.relaunchDebt, [next])
        await h.cleanup()
    }

    func testAFailedCloseForgetsOnlyWhatItRecorded() async throws {
        let h = try await EngineHarness(running: ["Claude_204"])
        let (debt, lifecycle) = makeLifecycle(h)
        let earlier = try h.folder("Claude_Kxm8")
        try await debt.record([earlier])
        h.process.failClose(.stillRunning(pids: [10], closedProfiles: [], names: ["Claude"]))
        do {
            try await lifecycle.close(owing: [h.folder("Claude_204"), h.folder("Claude")])
            XCTFail("expected the close to fail")
        } catch {}
        let state = try await h.store.load()
        XCTAssertEqual(state.relaunchDebt, [earlier])
        await h.cleanup()
    }

    func testAProfileThatFailsToReopenAfterAFailedCloseStaysOwed() async throws {
        let h = try await EngineHarness(running: ["Claude", "Claude_204"])
        let (_, lifecycle) = makeLifecycle(h)
        let closed = h.world.profileDirectory("Claude_204")
        h.process.failClose(.stillRunning(pids: [10], closedProfiles: [closed], names: ["Claude"]))
        h.process.onLaunch { profile, _ in
            if ProfilePaths.same(profile, closed) { throw FakeScriptError.failed("reopen") }
        }
        do {
            try await lifecycle.close(owing: [h.folder("Claude_Kxm8")])
            XCTFail("expected the close to fail")
        } catch {}
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude_204"])
        let state = try await h.store.load()
        XCTAssertEqual(state.relaunchDebt, [try h.folder("Claude_204")])
        await h.cleanup()
    }

    func testClosedProfilesStayOwedWhenWhatRunsCannotBeReadAfterAFailedClose() async throws {
        let h = try await EngineHarness(running: ["Claude", "Claude_204"])
        let (_, lifecycle) = makeLifecycle(h)
        let closed = h.world.profileDirectory("Claude_204")
        h.process.failClose(.stillRunning(pids: [10], closedProfiles: [closed], names: ["Claude"]))
        h.process.onClose { [process = h.process] in process.failInstances(.failed("table")) }
        do {
            try await lifecycle.close(owing: [])
            XCTFail("expected the close to fail")
        } catch {}
        XCTAssertTrue(h.process.recordedLaunches().isEmpty)
        let state = try await h.store.load()
        XCTAssertEqual(state.relaunchDebt, [try h.folder("Claude_204")])
        await h.cleanup()
    }

    func testStartupReopensOwedAccountsBesideAClaudeThatIsOpen() async throws {
        let h = try await EngineHarness(running: ["Claude"])
        let owed = try h.folder("Claude_204")
        try await h.store.update { @Sendable state in state.relaunchDebt = [owed] }
        await h.start()
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude_204"])
        let state = try await h.store.load()
        XCTAssertTrue(state.relaunchDebt.isEmpty)
        await h.cleanup()
    }

    func testAProfileFolderThatIsGoneIsNotLaunched() async throws {
        let h = try await EngineHarness(running: [])
        let (debt, lifecycle) = makeLifecycle(h)
        let gone = try ProfileFolder("Claude_gone01")
        try await debt.record([gone, h.folder("Claude_204")])
        try await lifecycle.relaunchOwed()
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude_204"])
        let state = try await h.store.load()
        XCTAssertEqual(state.relaunchDebt, [gone])
        await h.cleanup()
    }

    private func makeLifecycle(_ h: EngineHarness) -> (RelaunchDebt, ClaudeLifecycle) {
        let debt = RelaunchDebt(store: h.store)
        let log = CompanionLog(paths: h.world.paths, clock: h.clock)
        return (debt, ClaudeLifecycle(processes: h.process, tasks: h.inspector, debt: debt,
                                      paths: h.world.paths, log: log))
    }
}
