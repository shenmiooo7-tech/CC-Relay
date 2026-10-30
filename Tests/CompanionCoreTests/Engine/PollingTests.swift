import Foundation
import XCTest
@testable import CompanionCore

@MainActor
final class PollingTests: XCTestCase {
    private func engine(_ h: EngineHarness, clock: SuspendingClock) -> CompanionEngine {
        CompanionEngine(paths: h.world.paths, processes: h.process, tasks: h.inspector,
            cookies: h.cookies, quota: h.quota, accountDetails: h.quota, loginItems: h.login, fileRevealer: h.revealer,
            executable: h.scratch.root.appending(path: "CCRelay"), clock: clock)
    }

    func testPanelScanCadenceAndTwoSecondSignInPolling() async throws {
        let h = try await EngineHarness(autoSync: false)
        let clock = SuspendingClock(now: h.clock.now())
        let engine = engine(h, clock: clock)
        await engine.start()
        var ready = await eventually { clock.recordedSleeps().contains(.seconds(300)) }
        XCTAssertTrue(ready)
        await engine.perform(.panelOpened)
        ready = await eventually { clock.recordedSleeps().contains(.seconds(30)) }
        XCTAssertTrue(ready)
        let baseline = await h.quota.replacements.count
        clock.advance(by: 29)
        await Task.yield()
        let before = await h.quota.replacements.count
        XCTAssertEqual(before, baseline)
        clock.advance(by: 1)
        ready = await eventually { await h.quota.replacements.count > baseline }
        XCTAssertTrue(ready)
        await engine.panelClosed()
        await engine.perform(.addAccount)
        let folder = try engineUnwrap(await engine.currentSnapshot().pendingAdd?.folder)
        try h.writeSignIn(folder: folder)
        ready = await eventually { clock.recordedSleeps().contains(.seconds(2)) }
        XCTAssertTrue(ready)
        clock.advance(by: 2)
        ready = await eventually { await engine.currentSnapshot().pendingAdd == nil }
        XCTAssertTrue(ready)
        await engine.stop()
        await h.cleanup()
    }

    func testWaitRechecksAtFiveSecondsAndCanCancelWithoutClockAdvancing() async throws {
        for cancel in [true, false] {
            let h = try await EngineHarness(autoSync: false)
            let clock = SuspendingClock(now: h.clock.now())
            let engine = engine(h, clock: clock)
            await engine.start()
            h.inspector.enqueue(.busy([CodeTaskInfo(pid: 2, reason: .statusBusy)]))
            let folder = try h.folder("Claude_204")
            let request = Task { await engine.perform(.switchTo(folder: folder)) }
            var ready = await eventually { await engine.currentSnapshot().taskGuardPrompt != nil }
            XCTAssertTrue(ready)
            await engine.perform(.taskGuard(.waitThenSwitch))
            ready = await eventually { clock.recordedSleeps().contains(.seconds(5)) }
            XCTAssertTrue(ready)
            if cancel { await engine.perform(.taskGuard(.cancel)) }
            else {
                clock.advance(by: 4)
                XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
                clock.advance(by: 1)
            }
            await request.value
            XCTAssertEqual(h.process.recordedQuitTimeouts().count, cancel ? 0 : 1)
            await engine.stop()
            await h.cleanup()
        }
    }
}
