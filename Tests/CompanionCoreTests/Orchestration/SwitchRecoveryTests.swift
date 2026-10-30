import Foundation
import XCTest
@testable import CompanionCore

@MainActor
final class SwitchRecoveryTests: XCTestCase {
    func testQuitDoesNotOpenThePreviousAccountDuringASuccessfulTargetAttempt() async throws {
        let h = try await EngineHarness(autoSync: false, running: ["Claude", "Claude_Kxm8"])
        await h.start()
        let pause = AsyncLaunchPause()
        h.process.onLaunchAsync { profile, _ in
            if profile.lastPathComponent == "Claude_204" { await pause.wait() }
        }
        let target = try h.folder("Claude_204")
        let request = Task { await h.engine.perform(.switchTo(folder: target)) }
        let started = await eventually { await pause.started }
        XCTAssertTrue(started)
        await h.engine.perform(.quitApp)
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude_204", "Claude_Kxm8"])
        await pause.release()
        await request.value
        let running = try await h.process.runningInstances()
        XCTAssertEqual(Set(running.map { $0.profileDirectory.lastPathComponent }), ["Claude_204", "Claude_Kxm8"])
        let state = try await h.store.load()
        XCTAssertTrue(state.relaunchDebt.isEmpty)
        await h.cleanup()
    }

    func testQuitWaitsForAnOperationThatOutlastsThirtySecondsBeforeOpeningAnything() async throws {
        let h = try await EngineHarness(running: ["Claude"])
        await h.start()
        let close = CloseObservation()
        h.process.onClose { [clock = h.clock, process = h.process] in
            // A close slower than 30 s, then the sync writes into the target: nothing may open it
            // meanwhile. Only quit's own waiting moves the test clock, and it stops at 45 s until
            // the close has looked; a quit that stops waiting earlier never gets there, so the
            // close gives up after a real moment.
            let mark = clock.now().addingTimeInterval(45)
            clock.hold(at: mark)
            await close.enter()
            for _ in 0..<2000 where clock.now() < mark {
                try? await Task.sleep(for: .milliseconds(1))
            }
            await close.finish(launchedMeanwhile: !process.recordedLaunches().isEmpty)
            clock.release()
        }
        let target = try h.folder("Claude_204")
        let request = Task { await h.engine.perform(.switchTo(folder: target)) }
        let entered = await eventually { await close.entered }
        XCTAssertTrue(entered)
        await h.engine.perform(.quitApp)
        await request.value
        let launchedMeanwhile = await close.launchedMeanwhile
        XCTAssertEqual(launchedMeanwhile, false)
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude_204"])
        await h.cleanup()
    }

    func testAQuitThatOutwaitsAnOperationLeavesItsAccountsForTheNextStart() async throws {
        let h = try await EngineHarness(running: ["Claude"])
        await h.start()
        let close = HeldClose()
        h.process.onClose { await close.hold() }
        let target = try h.folder("Claude_204")
        let request = Task { await h.engine.perform(.switchTo(folder: target)) }
        let entered = await eventually { await close.entered }
        XCTAssertTrue(entered)
        // The quit's own wait runs out on the test clock while the close is still under way.
        await h.engine.perform(.quitApp)
        XCTAssertTrue(h.process.recordedLaunches().isEmpty)
        let state = try await h.store.load()
        XCTAssertEqual(state.relaunchDebt, [target])
        XCTAssertEqual(try h.logLines(containing: "Quit while an operation was still running").count, 1)
        await close.release()
        await request.value
        await h.cleanup()
    }

    func testATargetAFailedCloseLeftClosedOpensAtTheNextPickup() async throws {
        let h = try await EngineHarness(running: ["Claude", "Claude_204"])
        await h.start()
        let target = try h.folder("Claude_204")
        // The close stops the target, open beside the active account, then fails, and the target
        // does not open again at once.
        h.process.failClose(.stillRunning(pids: [10], closedProfiles: [h.world.profileDirectory("Claude_204")]))
        h.process.enqueueLaunch(.failure(.failed("reopen")))
        await h.engine.perform(.switchTo(folder: target))
        var state = try await h.store.load()
        XCTAssertEqual(state.relaunchDebt, [target])
        // The failed switch holds it no longer, so the quit opens it.
        await h.engine.perform(.quitApp)
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude_204", "Claude_204"])
        state = try await h.store.load()
        XCTAssertTrue(state.relaunchDebt.isEmpty)
        await h.cleanup()
    }

    func testUnconfirmedLaunchCleanupDoesNotRestoreThePreviousAccount() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        h.process.onLaunch { profile, _ in
            if profile.lastPathComponent == "Claude_204" { throw ClaudeProcessError.launchCleanupFailed }
        }
        let target = try h.folder("Claude_204")
        await h.engine.perform(.switchTo(folder: target))
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude_204"])
        let state = try await h.store.load()
        XCTAssertEqual(state.relaunchDebt, [target])
        await h.cleanup()
    }

    func testFailedTargetRestoresPreviousConversationAfterOpeningBystanders() async throws {
        let h = try await EngineHarness(running: ["Claude", "Claude_Kxm8"])
        await h.start()
        h.process.enqueueLaunch(.failure(.failed("target")))
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        let launches = h.process.recordedLaunches()
        XCTAssertEqual(launches.map { $0.profile.lastPathComponent }, ["Claude_204", "Claude_Kxm8", "Claude"])
        XCTAssertNil(launches[1].deepLink)
        XCTAssertEqual(launches[2].deepLink?.absoluteString, "claude://code/continue?session=local_" + SandboxFixture.ID.liveSession)
        let state = try await h.store.load()
        XCTAssertTrue(state.relaunchDebt.isEmpty)
        XCTAssertEqual(state.activeFolder?.name, "Claude")
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome,
            .failed(operation: .switchTo(try h.folder("Claude_204")), reason: .returnedToPreviousAccount))
        for name in ["Claude", "Claude_204"] {
            let root = h.world.paths.companionDataDirectory.appending(path: "Backups/" + name)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
        }
        await h.cleanup()
    }

    func testFailedCaptureUsesPlainPreviousLaunchAndFailedPreviousKeepsOpenFailure() async throws {
        for previousFails in [false, true] {
            let h = try await EngineHarness(autoSync: false)
            await h.start()
            let source = try h.profile("Claude")
            let record = try h.sessionFile(source, id: "local_" + SandboxFixture.ID.liveSession)
            try AtomicFile.write(Data("invalid".utf8), to: record)
            h.process.enqueueLaunch(.failure(.failed("target")))
            if previousFails { h.process.enqueueLaunch(.failure(.failed("previous"))) }
            await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
            XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude_204", "Claude"])
            XCTAssertTrue(h.process.recordedLaunches().allSatisfy { $0.deepLink == nil })
            let state = try await h.store.load()
            // A previous account that could not be reopened stays owed to the next start.
            XCTAssertEqual(state.relaunchDebt, previousFails ? [try h.folder("Claude")] : [])
            XCTAssertEqual(state.activeFolder?.name, "Claude")
            let snapshot = await h.snapshot()
            XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .switchTo(try h.folder("Claude_204")),
                reason: previousFails ? .couldNotOpenClaude : .returnedToPreviousAccount))
            XCTAssertFalse(FileManager.default.fileExists(atPath: h.world.paths.companionDataDirectory.appending(path: "Backups").path))
            await h.cleanup()
        }
    }

    func testQuitClaimsRemainingBystandersAndFallbackExactlyOnceDuringTargetAttempt() async throws {
        let h = try await EngineHarness(autoSync: false, running: ["Claude", "Claude_Kxm8"])
        await h.start()
        let pause = AsyncLaunchPause()
        h.process.onLaunchAsync { profile, _ in
            if profile.lastPathComponent == "Claude_204" { await pause.wait() }
        }
        h.process.enqueueLaunch(.failure(.failed("target")))
        let target = try h.folder("Claude_204")
        let request = Task { await h.engine.perform(.switchTo(folder: target)) }
        let started = await eventually { await pause.started }
        XCTAssertTrue(started)
        let pending = try await h.store.load()
        XCTAssertEqual(Set(pending.relaunchDebt.map(\.name)), ["Claude_204", "Claude_Kxm8"])
        await h.engine.perform(.quitApp)
        await pause.release()
        await request.value
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude_204", "Claude_Kxm8", "Claude"])
        let state = try await h.store.load()
        XCTAssertTrue(state.relaunchDebt.isEmpty)
        XCTAssertEqual(state.activeFolder?.name, "Claude")
        await h.cleanup()
    }

    func testQuitDoesNotDuplicateAnAlreadyClaimedPreviousLaunch() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        let pause = AsyncLaunchPause()
        h.process.onLaunchAsync { profile, _ in
            if profile.lastPathComponent == "Claude" { await pause.wait() }
        }
        h.process.enqueueLaunch(.failure(.failed("target")))
        let target = try h.folder("Claude_204")
        let request = Task { await h.engine.perform(.switchTo(folder: target)) }
        let started = await eventually { await pause.started }
        XCTAssertTrue(started)
        await h.engine.perform(.quitApp)
        await pause.release()
        await request.value
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude_204", "Claude"])
        let state = try await h.store.load()
        XCTAssertTrue(state.relaunchDebt.isEmpty)
        await h.cleanup()
    }
}

private actor CloseObservation {
    private(set) var entered = false
    private(set) var launchedMeanwhile: Bool?

    func enter() { entered = true }
    func finish(launchedMeanwhile: Bool) { self.launchedMeanwhile = launchedMeanwhile }
}
