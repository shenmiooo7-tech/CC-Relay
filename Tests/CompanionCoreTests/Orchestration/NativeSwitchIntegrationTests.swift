import Foundation
import XCTest
@testable import CompanionCore

/// The real Engine -> SwitchCoordinator wiring, with isolated profile/transcript
/// files and fake OS launches. No real account, model turn or native tool is run.
@MainActor
final class NativeSwitchIntegrationTests: XCTestCase {
    func testManualSwitchWarnsOnceForHostWorkObservedBeforePreparationOrClosing() async throws {
        for observedBeforePreparation in [false, true] {
            let kinds = observedBeforePreparation ? ["shell"] : ["shell", "protected-shell"]
            for kind in kinds {
                let runtime = NativeSwitchRuntimeFixture()
                let h = try await EngineHarness(nativeRuntimeInspector: runtime)
                let files = NativeSwitchFiles(harness: h)
                let source = try h.profile("Claude"), target = try h.profile("Claude_204")
                try files.installFinishedTurn()
                await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
                try files.report(pid: 101)
                h.process.onClose { await runtime.clear(profile: source.url) }
                let log = CompanionLog(paths: h.world.paths, clock: h.clock)
                let lifecycle = ClaudeLifecycle(processes: h.process, tasks: h.inspector,
                    debt: RelaunchDebt(store: h.store), paths: h.world.paths, log: log)
                let recovery = NativeRecoveryCoordinator(paths: h.world.paths, inspector: runtime, clock: h.clock)
                let switches = SwitchCoordinator(paths: h.world.paths, store: h.store, lifecycle: lifecycle,
                    taskGuard: TaskGuard(inspector: h.inspector, clock: h.clock), clock: h.clock, log: log, recovery: recovery)
                let inventory = NativeHostWorkInventory(backgroundTasks: [.init(id: "host-shell", type: "shell", status: "running")])
                // The producer reports busy for a listed shell, even though the transcript's last
                // model turn has ended.
                let busy = true
                let activeTasks: [NativeRuntimeTask] = kind == "protected-shell"
                    ? [.init(id: "host-shell", kind: .bash, jobID: "cmd-preflight")] : []
                if observedBeforePreparation { try files.report(pid: 101, busy: busy, hostWorkInventory: inventory) }
                let outcome = await switches.run(target: target.folder, progress: { progress in
                    if case .switching(_, .closingClaude, _) = progress {
                        do {
                            if !observedBeforePreparation {
                                XCTAssertEqual(try files.operation().sessionIDs, [], "The idle conversation has no recovery request")
                            }
                            if kind == "protected-shell" {
                                // Matching the host ID is insufficient: this newly started worker
                                // was not captured, so no request or exit permit protects it.
                                let state = try files.command(status: "running")
                                XCTAssertFalse(FileManager.default.fileExists(atPath: state.deletingLastPathComponent().appending(path: "handoff.json").path))
                            }
                            try files.report(pid: 101, busy: busy, activeTasks: activeTasks, hostWorkInventory: inventory)
                        } catch { XCTFail("Could not inspect preparation or inject inventory: \(error)") }
                    }
                }, prompt: { _ in })
                if case .completed(let warnings, _) = outcome {
                    XCTAssertEqual(warnings.filter { $0 == .workContinuationUnavailable }.count, 1,
                        "\(kind), observed before preparation: \(observedBeforePreparation)")
                } else { XCTFail("Manual switching must still complete: \(outcome)") }
                XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1)
                XCTAssertEqual(h.process.recordedLaunches().count, 1)
                XCTAssertEqual(h.process.recordedLaunches().first?.profile, target.url)
                await h.cleanup()
            }
        }
    }

    func testManualSwitchDoesNotWarnForSafeOrUnverifiedFinalHostInventory() async throws {
        for kind in ["empty", "artifact", "subagent", "monitor", "unverified", "stale"] {
            let runtime = NativeSwitchRuntimeFixture()
            let h = try await EngineHarness(nativeRuntimeInspector: runtime)
            let files = NativeSwitchFiles(harness: h)
            let source = try h.profile("Claude"), target = try h.profile("Claude_204")
            if kind == "artifact" { try files.installWatchOnly(title: "Comments stay with source") }
            else { try files.installFinishedTurn() }
            await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
            try files.report(pid: 101, watchReopen: true)
            h.process.onClose { await runtime.clear(profile: source.url) }
            let log = CompanionLog(paths: h.world.paths, clock: h.clock)
            let lifecycle = ClaudeLifecycle(processes: h.process, tasks: h.inspector,
                debt: RelaunchDebt(store: h.store), paths: h.world.paths, log: log)
            let recovery = NativeRecoveryCoordinator(paths: h.world.paths, inspector: runtime, clock: h.clock)
            let switches = SwitchCoordinator(paths: h.world.paths, store: h.store, lifecycle: lifecycle,
                taskGuard: TaskGuard(inspector: h.inspector, clock: h.clock), clock: h.clock, log: log, recovery: recovery)
            let reportedAt = h.clock.now().timeIntervalSince1970 * 1000 - (kind == "stale" ? 60_000 : 0)
            // A shell in a report that is not verified or not fresh would warn if it were believed.
            let unsupported = ["unverified", "stale"].contains(kind)
            let task: NativeHostWorkInventory.Task? = switch kind {
            case "artifact": .init(id: "watch", type: "artifact-comment-monitor", status: "running")
            case "subagent": .init(id: "helper", type: "subagent", status: "running")
            case "monitor": .init(id: "watcher", type: "monitor", status: "running")
            default: unsupported ? .init(id: "untrusted-shell", type: "shell", status: "running") : nil
            }
            let inventory = NativeHostWorkInventory(backgroundTasks: task.map { [$0] } ?? [])
            let outcome = await switches.run(target: target.folder, progress: { progress in
                if case .switching(_, .closingClaude, _) = progress {
                    if kind == "unverified" { await runtime.reject(pid: 101) }
                    do {
                        XCTAssertEqual(try files.operation().sessionIDs, [], kind)
                        try files.report(pid: 101, busy: unsupported, reportedAt: reportedAt,
                                         watchReopen: true, hostWorkInventory: inventory)
                    } catch { XCTFail("Could not inspect preparation or inject inventory: \(error)") }
                }
            }, prompt: { _ in })
            if case .completed(let warnings, _) = outcome {
                XCTAssertFalse(warnings.contains(.workContinuationUnavailable), kind)
            } else { XCTFail("Manual switching must still complete: \(outcome)") }
            XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1, kind)
            XCTAssertEqual(h.process.recordedLaunches().count, 1, kind)
            await h.cleanup()
        }
    }

    func testHostWorkDiscoveredImmediatelyBeforeCloseKeepsTheSourceRunning() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installRateLimitedTurn()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
        try files.report(pid: 101)
        let original = try AtomicFile.read(files.sessionFile(source))
        let log = CompanionLog(paths: h.world.paths, clock: h.clock)
        let lifecycle = ClaudeLifecycle(processes: h.process, tasks: h.inspector,
            debt: RelaunchDebt(store: h.store), paths: h.world.paths, log: log)
        let recovery = NativeRecoveryCoordinator(paths: h.world.paths, inspector: runtime, clock: h.clock)
        let switches = SwitchCoordinator(paths: h.world.paths, store: h.store, lifecycle: lifecycle,
            taskGuard: TaskGuard(inspector: h.inspector, clock: h.clock), clock: h.clock, log: log, recovery: recovery)
        let inventory = NativeHostWorkInventory(backgroundTasks: [.init(id: "not-in-plugin", type: "shell", status: "running")])
        let outcome = await switches.run(target: target.folder, automaticSource: source.folder,
            progress: { progress in
                if case .switching(_, .closingClaude, _) = progress {
                    // Preparation saw no extra work. The final report now discloses it.
                    do { try files.report(pid: 101, hostWorkInventory: inventory) }
                    catch { XCTFail("Could not inject host inventory: \(error)") }
                }
            }, prompt: { _ in XCTFail("No real or simulated permission prompt is expected") })
        // Closing would cut the command off: the switch waits for it instead.
        if case .failed(.cancelled) = outcome {} else { XCTFail("\(outcome)") }
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        XCTAssertTrue(h.process.recordedLaunches().isEmpty)
        XCTAssertEqual(try AtomicFile.read(files.sessionFile(source)), original)
        let stored = try await h.store.load()
        XCTAssertEqual(stored.activeFolder, source.folder)
        XCTAssertNil(try? files.operation())
        await h.cleanup()
    }

    func testAManualSwitchIsNeverRefusedForTheConversationsPermissionMode() async throws {
        for mode in ["default", "bypassPermissions"] {
            let runtime = NativeSwitchRuntimeFixture()
            let h = try await EngineHarness(nativeRuntimeInspector: runtime)
            let files = NativeSwitchFiles(harness: h)
            let source = try h.profile("Claude"), target = try h.profile("Claude_204")
            try files.installRateLimitedTurn()
            try files.permissionMode(mode, profile: source)
            try files.bypass(profile: source, choice: true, gate: true)
            try files.bypass(profile: target, choice: false, gate: true)
            await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
            try files.report(pid: 101)
            h.process.onClose { await runtime.clear(profile: source.url) }
            await h.start()
            await h.engine.perform(.switchTo(folder: target.folder))
            let snapshot = await h.snapshot()
            XCTAssertEqual(snapshot.currentFolder, target.folder, mode)
            XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1, mode)
            await h.cleanup()
        }
    }

    func testAutomaticSwitchPassesOverAnAccountThatCannotCarryABypassConversationOn() async throws {
        for second in ["allows", "refuses"] {
            let runtime = NativeSwitchRuntimeFixture()
            let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
            let files = NativeSwitchFiles(harness: h)
            let source = try h.profile("Claude"), first = try h.profile("Claude_204")
            let other = try h.profile("Claude_Kxm8"), spent = try h.profile("Claude_Kxm2")
            try files.installRateLimitedTurn()
            try files.permissionMode("bypassPermissions", profile: source)
            try files.bypass(profile: first, choice: false, gate: true)
            try files.bypass(profile: other, choice: second == "allows", gate: true)
            await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
            try files.report(pid: 101)
            // The first account resets sooner, so it is tried first.
            await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                                first.folder: quotaReading(first, now: h.clock.now(), used: 20, weekResetDays: 1),
                                other.folder: quotaReading(other, now: h.clock.now(), used: 20, weekResetDays: 2),
                                spent.folder: quotaReading(spent, now: h.clock.now(), used: 100)])
            h.process.onClose { await runtime.clear(profile: source.url) }
            await h.start()
            await h.engine.checkAutomaticSwitch()
            XCTAssertTrue(h.process.recordedImmediateQuits().isEmpty, "Nothing is closed for an account that cannot carry the conversation on")
            let passed = await h.snapshot()
            XCTAssertNil(passed.lastResult, "Passing an account over is not a failure to show")
            for _ in 0..<2 {
                try files.report(pid: 101)
                await h.engine.checkAutomaticSwitch()
            }
            let after = await h.snapshot()
            if second == "allows" {
                XCTAssertEqual(after.currentFolder, other.folder)
                XCTAssertEqual(h.process.recordedImmediateQuits().count, 1)
            } else {
                XCTAssertTrue(h.process.recordedImmediateQuits().isEmpty)
                XCTAssertNil(after.lastResult)
                XCTAssertTrue(after.banners.contains(.autoSwitchNeedsBypass(account: first.folder)),
                              "With no account left, the best one is named so the person can turn bypass on there")
            }
            await h.cleanup()
        }
    }
    func testReopeningTheSameClosedAccountKeepsItsBypassContinuation() async throws {
        for sync in [false, true] {
            let runtime = NativeSwitchRuntimeFixture()
            let h = try await EngineHarness(autoSync: sync, running: [], nativeRuntimeInspector: runtime)
            let files = NativeSwitchFiles(harness: h)
            let source = try h.profile("Claude")
            try files.installRateLimitedTurn()
            try files.permissionMode("bypassPermissions", profile: source)
            try files.bypass(profile: source, choice: true, gate: true)
            let preference = source.url.appending(path: CodePreferenceInheritance.fileName)
            let original = try AtomicFile.read(preference)
            await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: true)
            try files.report(pid: 101)
            let recovery = NativeRecoveryCoordinator(paths: h.world.paths, inspector: runtime, clock: h.clock)
            let captured = try ContinuityInspector(paths: h.world.paths).capture(profile: source)
            let pending = try await recovery.prepare(source: source, target: source, primary: captured, claudeWasOpen: true)
            let saved = try XCTUnwrap(pending)
            XCTAssertEqual(saved.requests.count, 1)
            try await recovery.activate(saved)
            let root = h.world.paths.companionDataDirectory.appending(path: "NativeRecovery")
            let operationFile = root.appending(path: "active.json")
            let operationBytes = try AtomicFile.read(operationFile)
            await runtime.clear(profile: source.url)
            await h.start()
            await h.engine.perform(.switchTo(folder: source.folder))
            let snapshot = await h.snapshot()
            if case .switched = snapshot.lastResult?.outcome {} else { XCTFail("Same-account reopening is not a cross-account permission downgrade") }
            XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
            XCTAssertEqual(h.process.recordedLaunches().count, 1)
            XCTAssertEqual(try AtomicFile.read(preference), original)
            XCTAssertEqual(try files.request().phase, "prepared")
            XCTAssertTrue(try files.operation().ready)
            if !sync { XCTAssertEqual(try AtomicFile.read(operationFile), operationBytes, "Sync off must not revoke a prior same-account operation") }
            await h.cleanup()
        }
    }

    func testAutomaticSwitchRefusesWhenFinalHandoffSaveFailsBeforeClose() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        let originalInstances = try await h.process.runningInstances()
        try files.installNativeWork()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: true)
        try files.report(pid: 101)
        let log = CompanionLog(paths: h.world.paths, clock: h.clock)
        let lifecycle = ClaudeLifecycle(processes: h.process, tasks: h.inspector,
            debt: RelaunchDebt(store: h.store), paths: h.world.paths, log: log)
        let recovery = NativeRecoveryCoordinator(paths: h.world.paths, inspector: runtime, clock: h.clock)
        let switches = SwitchCoordinator(paths: h.world.paths, store: h.store, lifecycle: lifecycle,
            taskGuard: TaskGuard(inspector: h.inspector, clock: h.clock), clock: h.clock, log: log, recovery: recovery)
        let lease = NativeSwitchRequestLease()
        let lockFile = recovery.directory.appending(path: "locks/\(SandboxFixture.ID.liveSession).lock")
        let execution = await switches.run(target: target.folder, automaticSource: source.folder,
            progress: { progress in
                if case .switching(_, .closingClaude, _) = progress {
                    // Preparation succeeded. Refuse only the last save, immediately before close.
                    XCTAssertEqual(try? files.request().phase, "prepared")
                    do { try await lease.hold(lockFile) }
                    catch { XCTFail("Could not inject the final handoff save failure: \(error)") }
                }
            }, prompt: { _ in XCTFail("An automatic switch must not ask for task permission") })
        await lease.release()
        if case .failed(.couldNotPrepareContinuation) = execution {} else {
            XCTFail("A failed final handoff save must refuse the automatic switch")
        }
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        XCTAssertTrue(h.process.recordedLaunches().isEmpty)
        let running = try await h.process.runningInstances()
        XCTAssertEqual(running, originalInstances)
        let state = try await h.store.load()
        XCTAssertEqual(state.activeFolder, source.folder)
        XCTAssertTrue(state.relaunchDebt.isEmpty)
        XCTAssertNil(try? files.operation(), "The failed generation must not be activated later")
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.world.paths.companionDataDirectory.appending(path: "Backups").path))
        await h.cleanup()
    }

    func testAutomaticRateLimitSwitchCapturesSyncsAndArmsOriginalWorkWithoutAnyConfirmation() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installRateLimitedTurn()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
        let now = h.clock.now().timeIntervalSince1970 * 1000
        try files.report(pid: 101, quotaBlock: NativeQuotaBlock(reason: "rateLimit", observedAt: now, until: now + 600_000))
        // A real rate-limit failure can precede the web meter reaching 100%.
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 80),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        h.inspector.enqueue(.busy([CodeTaskInfo(pid: 101, sessionID: SandboxFixture.ID.liveSession, reason: .statusBusy)]))
        h.process.onClose {
            XCTAssertEqual(try? files.request().phase, "prepared")
            XCTAssertEqual(try? files.request().sourceWasBusy, true, "A failed model turn still needs continuation")
            XCTAssertEqual(try? files.request().work.latestAssistantInterrupted, true)
            XCTAssertEqual(try? files.operation().ready, false)
            h.clock.advance(by: 1)
            await runtime.clear(profile: source.url)
        }
        h.process.onLaunchAsync { profile, link in
            guard ProfilePaths.same(profile, target.url) else { return }
            XCTAssertNotNil(link)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try files.sessionFile(target).path))
            try files.focus(target)
            await runtime.set(profile: target, pid: 202, startedAt: h.clock.now(), busy: false)
            try files.report(pid: 202)
        }
        await h.start()
        await h.engine.checkAutomaticSwitch()
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.currentFolder, target.folder)
        XCTAssertNil(snapshot.taskGuardPrompt)
        XCTAssertTrue(try files.operation().ready)
        XCTAssertEqual(try files.request().phase, "prepared")
        await h.engine.pollNativeRecovery()
        XCTAssertEqual(try files.request().phase, "armed")
        XCTAssertEqual(try files.request().pid, 202)
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1)
        await h.engine.checkAutomaticSwitch()
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1, "Repeated notifications must not repeat a completed switch")
        await h.cleanup()
    }

    /// Claude's conversation hits a limit and the work goes to Claude_204, where it runs as pid 202.
    /// With `spent`, the figures confirm the limit; otherwise the report alone caused the switch.
    private func switchOnALimit(_ h: EngineHarness, _ runtime: NativeSwitchRuntimeFixture, _ files: NativeSwitchFiles,
                                spent: Bool = false) async throws {
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installRateLimitedTurn()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
        let now = h.clock.now().timeIntervalSince1970 * 1000
        try files.report(pid: 101, quotaBlock: NativeQuotaBlock(reason: "rateLimit", observedAt: now, until: now + 600_000))
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: spent ? 100 : 80),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        h.process.onClose { h.clock.advance(by: 1); await runtime.clear(profile: source.url) }
        h.process.onLaunchAsync { profile, _ in
            guard ProfilePaths.same(profile, target.url) else { return }
            try files.focus(target)
            await runtime.set(profile: target, pid: 202, startedAt: h.clock.now(), busy: false)
            try files.report(pid: 202)
        }
        await h.start()
        await h.engine.checkAutomaticSwitch()
        let switched = await h.snapshot()
        XCTAssertEqual(switched.currentFolder, target.folder)
    }

    /// The conversation hits a limit on Claude_204 too; the figures a read brings show `used`.
    private func limitAgain(_ h: EngineHarness, _ files: NativeSwitchFiles, used: Double) async throws -> NativeQuotaBlock {
        let target = try h.profile("Claude_204")
        let now = h.clock.now().timeIntervalSince1970 * 1000
        let block = NativeQuotaBlock(reason: "rateLimit", observedAt: now, until: now + 600_000)
        try files.report(pid: 202, quotaBlock: block)
        await h.quota.setRefreshHook {
            var readings: [ProfileFolder: QuotaReading] = [:]
            for profile in h.profiles where AutomaticSwitchPolicy.identity(profile) != nil {
                readings[profile.folder] = quotaReading(profile, now: h.clock.now(), used: 20)
            }
            readings[target.folder] = quotaReading(target, now: h.clock.now(), used: used)
            await h.quota.push(readings)
        }
        return block
    }

    func testALimitRightAfterALimitAloneMovedTheWorkDoesNotMoveItAgainWhileQuotaIsLeft() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        try await switchOnALimit(h, runtime, files)
        let target = try h.profile("Claude_204")
        h.clock.advance(by: 60)
        let block = try await limitAgain(h, files, used: 30)
        await h.engine.checkAutomaticSwitch()
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1, "Claude is not closed again")
        let held = await h.snapshot()
        XCTAssertEqual(held.currentFolder, target.folder)
        XCTAssertTrue(held.banners.paused(.limitRepeated))
        // Only this account was read for it, once, and the others are not read while it stands.
        let reads = await h.quota.refreshes
        XCTAssertEqual(reads.last?.0, [target.folder])
        for _ in 1...3 {
            h.clock.advance(by: 61)
            try files.report(pid: 202, quotaBlock: block)
            await h.engine.checkAutomaticSwitch()
        }
        let later = await h.quota.refreshes.count
        XCTAssertEqual(later, reads.count)
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1)
        // A reply that gets through, or the end of the limit, ends the notice by itself.
        h.clock.advance(by: 61)
        try files.report(pid: 202)
        await h.engine.checkAutomaticSwitch()
        let over = await h.snapshot()
        XCTAssertFalse(over.banners.paused(.limitRepeated))
        await h.cleanup()
    }

    func testALimitThatStillStandsShowsItsNoticeAgainAfterItWasTakenDown() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        try await switchOnALimit(h, runtime, files)
        let target = try h.profile("Claude_204")
        h.clock.advance(by: 60)
        let block = try await limitAgain(h, files, used: 30)
        await h.engine.checkAutomaticSwitch()
        let held = await h.snapshot()
        XCTAssertTrue(held.banners.paused(.limitRepeated))
        // The report cannot be verified for a moment, which takes the notice down.
        await runtime.clear(profile: target.url)
        h.clock.advance(by: 61)
        await h.engine.checkAutomaticSwitch()
        let down = await h.snapshot()
        XCTAssertFalse(down.banners.paused(.limitRepeated))
        h.clock.advance(by: 61)
        let started = h.clock.now()
        await runtime.set(profile: target, pid: 202, startedAt: started, busy: false)
        try files.report(pid: 202, quotaBlock: block, startedAt: started)
        await h.engine.checkAutomaticSwitch()
        let back = await h.snapshot()
        XCTAssertTrue(back.banners.paused(.limitRepeated))
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1)
        await h.cleanup()
    }

    func testAnAccountTheServiceStoppedKeepsItsWorkWhateverElseSaysItIsSpent() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installNativeWork()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: true)
        let ms = h.clock.now().timeIntervalSince1970 * 1000
        try files.report(pid: 101, quotaBlock: NativeQuotaBlock(reason: "accountRestricted", observedAt: ms, until: ms + 86_400_000))
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        h.process.onClose { await runtime.clear(profile: source.url) }
        await h.start()
        let reads = await h.quota.refreshes.count
        await h.engine.checkAutomaticSwitch()
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty, "Claude is not closed")
        let held = await h.snapshot()
        XCTAssertEqual(held.currentFolder, source.folder)
        XCTAssertTrue(held.banners.paused(.accountRestricted))
        let after = await h.quota.refreshes.count
        XCTAssertEqual(after, reads, "No account is read for a switch that will not come")
        // A reply got through: the notice goes by itself, with quota left.
        h.clock.advance(by: 61)
        try files.report(pid: 101)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 30),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        await h.engine.checkAutomaticSwitch()
        let over = await h.snapshot()
        XCTAssertFalse(over.banners.paused(.accountRestricted))
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        // And a spent account is left as ever from then on.
        h.clock.advance(by: 61)
        try files.report(pid: 101)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        await h.engine.checkAutomaticSwitch()
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1)
        await h.cleanup()
    }

    func testAnAccountStoppedWhileTheOthersAreReadStopsTheSwitch() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installNativeWork()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: true)
        try files.report(pid: 101)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100)])
        await h.quota.setRefreshHook {
            let ms = h.clock.now().timeIntervalSince1970 * 1000
            try? files.report(pid: 101, quotaBlock: NativeQuotaBlock(reason: "accountRestricted", observedAt: ms, until: ms + 86_400_000))
            await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                                target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        }
        await h.start()
        await h.engine.checkAutomaticSwitch()
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        let held = await h.snapshot()
        XCTAssertTrue(held.banners.paused(.accountRestricted))
        await h.cleanup()
    }

    func testASwitchByHandStillGoesAheadFromAnAccountTheServiceStopped() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installNativeWork()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
        let ms = h.clock.now().timeIntervalSince1970 * 1000
        try files.report(pid: 101, quotaBlock: NativeQuotaBlock(reason: "accountRestricted", observedAt: ms, until: ms + 86_400_000))
        h.process.onClose { await runtime.clear(profile: source.url) }
        await h.start()
        await h.engine.checkAutomaticSwitch()
        let held = await h.snapshot()
        XCTAssertTrue(held.banners.paused(.accountRestricted))
        await h.engine.perform(.switchTo(folder: target.folder))
        let switched = await h.snapshot()
        XCTAssertEqual(switched.currentFolder, target.folder)
        XCTAssertFalse(switched.banners.paused(.accountRestricted))
        await h.cleanup()
    }

    func testASpentAccountIsLeftAsEverRightAfterALimitAloneMovedTheWork() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        try await switchOnALimit(h, runtime, files)
        h.clock.advance(by: 60)
        _ = try await limitAgain(h, files, used: 100)
        let leaving = try h.profile("Claude_204").url
        h.process.onClose { await runtime.clear(profile: leaving) }
        await h.engine.checkAutomaticSwitch()
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 2, "The figures show this account's own limit")
        await h.cleanup()
    }

    func testALimitLaterThanTenMinutesMovesTheWorkAsEver() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        try await switchOnALimit(h, runtime, files)
        h.clock.advance(by: 601)
        _ = try await limitAgain(h, files, used: 30)
        let leaving = try h.profile("Claude_204").url
        h.process.onClose { await runtime.clear(profile: leaving) }
        await h.engine.checkAutomaticSwitch()
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 2)
        await h.cleanup()
    }

    func testALimitAfterASwitchTheFiguresConfirmedMovesTheWorkAsEver() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        try await switchOnALimit(h, runtime, files, spent: true)
        h.clock.advance(by: 60)
        _ = try await limitAgain(h, files, used: 30)
        let leaving = try h.profile("Claude_204").url
        h.process.onClose { await runtime.clear(profile: leaving) }
        await h.engine.checkAutomaticSwitch()
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 2)
        await h.cleanup()
    }

    func testAutomaticSwitchWaitsForAnUnprotectedBackgroundCommandThenContinues() async throws {
        for busy in [false, true] {
            let runtime = NativeSwitchRuntimeFixture()
            let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
            let files = NativeSwitchFiles(harness: h)
            let source = try h.profile("Claude"), target = try h.profile("Claude_204")
            try files.installRateLimitedTurn()
            await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: busy)
            try files.report(pid: 101, activeTasks: [NativeRuntimeTask(id: "once-approved-bash", kind: .bash)])
            await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                                target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
            await h.start(); await h.engine.checkAutomaticSwitch()
            XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty, "An unprotected native command must finish before automatic closing")
            XCTAssertTrue(h.process.recordedLaunches().isEmpty)
            let waiting = await h.snapshot()
            XCTAssertFalse(waiting.banners.paused(.commandRunning), "It waits without a notice; the switch follows the command")
            h.clock.advance(by: 61)
            try files.report(pid: 101, activeTasks: [])
            await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                                target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
            h.process.onClose { await runtime.clear(profile: source.url) }
            await h.engine.checkAutomaticSwitch()
            XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1)
            let switched = await h.snapshot()
            XCTAssertEqual(switched.currentFolder, target.folder)
            await h.cleanup()
        }
    }

    func testUnprotectedCommandStartingDuringQuotaRefreshPreventsAutomaticClose() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installRateLimitedTurn()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
        try files.report(pid: 101, activeTasks: [])
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        await h.start()
        await h.quota.setRefreshHook {
            try? files.report(pid: 101, activeTasks: [NativeRuntimeTask(id: "new-once-approved-bash", kind: .bash)])
        }
        await h.engine.checkAutomaticSwitch()
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        XCTAssertTrue(h.process.recordedLaunches().isEmpty)
        await h.cleanup()
    }

    func testAutomaticSwitchNeedsFreshQuotaAndNoOtherAccountOpen() async throws {
        for scenario in ["disabled", "stale", "network-error", "below-limit", "other-account"] {
            let runtime = NativeSwitchRuntimeFixture()
            let h = try await EngineHarness(autoSync: scenario != "sync-off", autoSwitch: scenario != "disabled",
                running: scenario == "other-account" ? ["Claude", "Claude_Kxm8"] : ["Claude"], nativeRuntimeInspector: runtime)
            let files = NativeSwitchFiles(harness: h)
            let source = try h.profile("Claude"), target = try h.profile("Claude_204")
            try files.installNativeWork()
            if scenario != "unverified" { await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false) }
            try files.report(pid: 101, userStopped: scenario == "user-stopped")
            var sourceQuota = quotaReading(source, now: h.clock.now(), used: scenario == "below-limit" ? 99.9 : 100)
            if scenario == "stale" { sourceQuota.freshness = .stale }
            if scenario == "network-error" { sourceQuota.lastError = .httpFailure(429) }
            await h.quota.push([source.folder: sourceQuota, target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
            await h.start(); await h.engine.checkAutomaticSwitch()
            XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty, scenario)
            XCTAssertTrue(h.process.recordedLaunches().isEmpty, scenario)
            await h.cleanup()
        }
    }

    func testAStoppedReplyAnUnverifiedRuntimeOrSyncTurnedOffDoNotHoldTheSwitch() async throws {
        for scenario in ["user-stopped", "unverified", "sync-off"] {
            let runtime = NativeSwitchRuntimeFixture()
            let h = try await EngineHarness(autoSync: scenario != "sync-off", autoSwitch: true, nativeRuntimeInspector: runtime)
            let files = NativeSwitchFiles(harness: h)
            let source = try h.profile("Claude"), target = try h.profile("Claude_204")
            try files.installNativeWork()
            if scenario != "unverified" { await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false) }
            try files.report(pid: 101, userStopped: scenario == "user-stopped")
            await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                                target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
            h.process.onClose { await runtime.clear(profile: source.url) }
            await h.start(); await h.engine.checkAutomaticSwitch()
            XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1, scenario)
            let snapshot = await h.snapshot()
            XCTAssertEqual(snapshot.currentFolder, target.folder, scenario)
            await h.cleanup()
        }
    }

    func testAnExhaustedAccountIsLeftAlsoWithNothingToCarryOn() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installFinishedTurn()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
        try files.report(pid: 101)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        h.process.onClose { await runtime.clear(profile: source.url) }
        await h.start(); await h.engine.checkAutomaticSwitch()
        // The next message goes to an account that can answer it; nothing goes on by itself.
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1)
        XCTAssertEqual(h.process.recordedLaunches().count, 1)
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.currentFolder, target.folder)
        XCTAssertNil(try? files.request())
        await h.cleanup()
    }

    func testAProtectedCommandThatCannotBeHandedOverDoesNotHoldTheSwitch() async throws {
        for record in ["missing", "present"] {
            let runtime = NativeSwitchRuntimeFixture()
            let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
            let files = NativeSwitchFiles(harness: h)
            let source = try h.profile("Claude"), target = try h.profile("Claude_204")
            try files.installNativeWork()
            if record == "present" { _ = try files.command(status: "running") }
            await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
            try files.report(pid: 101, activeTasks: [NativeRuntimeTask(id: "native-bash-task", kind: .bash,
                                                                       toolUseID: "native-bash", jobID: "cmd-preflight")])
            await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                                target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
            h.process.onClose { await runtime.clear(profile: source.url) }
            await h.start(); await h.engine.checkAutomaticSwitch()
            let snapshot = await h.snapshot()
            // Without its record the command cannot be handed over; the conversation still goes on.
            XCTAssertEqual(snapshot.currentFolder, target.folder, record)
            XCTAssertFalse(snapshot.banners.paused(.continuationNotReady), record)
            await h.cleanup()
        }
    }

    func testUserCanDisableWhileAutomaticSwitchIsRefreshingAlternatives() async throws {
        // Stopping a reply meanwhile leaves the switch to go on: the account is still spent.
        for action in ["disable", "stop"] {
            let runtime = NativeSwitchRuntimeFixture()
            let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
            let files = NativeSwitchFiles(harness: h)
            let source = try h.profile("Claude"), target = try h.profile("Claude_204")
            try files.installNativeWork()
            await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: true)
            try files.report(pid: 101)
            await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                                target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
            await h.start()
            let refresh = HeldClose()
            await h.quota.setRefreshHook { await refresh.hold() }
            let checking = Task { await h.engine.checkAutomaticSwitch() }
            let refreshing = await eventually { await refresh.entered }
            XCTAssertTrue(refreshing)
            if action == "disable" { await h.engine.perform(.setAutoSwitch(false)) }
            else { try files.report(pid: 101, userStopped: true) }
            if action == "stop" { h.process.onClose { await runtime.clear(profile: source.url) } }
            await refresh.release(); await checking.value
            XCTAssertEqual(h.process.recordedQuitTimeouts().count, action == "stop" ? 1 : 0, action)
            if action == "stop" { XCTAssertEqual(try files.request().sourceUserStopped, true, "The stopped reply is not taken up again") }
            await h.cleanup()
        }
    }

    func testExhaustedAccountWaitsWithoutClosingAndSwitchesWhenAnAlternativeBecomesAvailable() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installNativeWork()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: true)
        try files.report(pid: 101)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 100)])
        await h.start(); await h.engine.checkAutomaticSwitch()
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        let waiting = await h.snapshot()
        XCTAssertTrue(waiting.banners.paused(.noAvailableAccount))
        h.clock.advance(by: 61)
        try files.report(pid: 101)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        h.process.onClose { await runtime.clear(profile: source.url) }
        await h.engine.checkAutomaticSwitch()
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1)
        let switched = await h.snapshot()
        XCTAssertEqual(switched.currentFolder, target.folder)
        await h.cleanup()
    }

    func testAWatchKeptOnItsAccountIsToldAndStartsAgainWhenTheAccountOpens() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installWatchOnly(title: "Review the page")
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
        try files.report(pid: 101, watchReopen: true)
        h.process.onClose { await runtime.clear(profile: source.url) }
        await h.start()
        await h.engine.perform(.switchTo(folder: target.folder))
        var snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.currentFolder, target.folder)
        XCTAssertTrue(snapshot.banners.contains(.watchesStayed(account: source.folder, titles: ["Review the page"])))
        // Not opened on the target, and nothing asks either account to start it yet.
        XCTAssertNil(try files.record(source)["interruptedByQuitAt"])
        XCTAssertNil(try? files.record(target)["interruptedByQuitAt"] as Any?)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.watchReopenNote.path))
        h.clock.advance(by: 60)
        await h.engine.perform(.switchTo(folder: source.folder))
        snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.currentFolder, source.folder)
        XCTAssertFalse(snapshot.banners.contains { if case .watchesStayed = $0 { return true }; return false })
        let record = try files.record(source)
        XCTAssertNotNil(record["interruptedByQuitAt"])
        XCTAssertEqual(record["interruptedAwaitingPerson"] as? Bool, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.watchReopenNote.path))
        await h.cleanup()
    }

    func testWithNoAccountReadyTheOthersAreReadAgainOnlyOnceOneMayHaveReset() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204"), start = h.clock.now()
        try files.installNativeWork()
        await runtime.set(profile: source, pid: 101, startedAt: start, busy: true)
        // Every other account is spent until its five-hour window resets, an hour from now. The spent
        // account's own reading is not renewed while they wait: it ages like between regular refreshes.
        var spent: [ProfileFolder: QuotaReading] = [:]
        for profile in h.profiles where profile.folder != source.folder && AutomaticSwitchPolicy.identity(profile) != nil {
            spent[profile.folder] = quotaReading(profile, now: start, used: 100)
        }
        await h.quota.push(spent.merging([source.folder: quotaReading(source, now: start, used: 100)]) { $1 })
        func check() async throws { try files.report(pid: 101); await h.engine.checkAutomaticSwitch() }
        func forcedReads() async -> Int { await h.quota.refreshes.filter(\.1).count }
        await h.start()
        let before = await forcedReads()
        try await check()
        let first = await forcedReads()
        XCTAssertEqual(first, before + 1)
        let waiting = await h.snapshot()
        XCTAssertTrue(waiting.banners.paused(.noAvailableAccount))
        for _ in 1...59 { h.clock.advance(by: 60); try await check() }
        let held = await forcedReads()
        XCTAssertEqual(held, first, "Nothing can have reset yet")
        // From the reset on, a read finds the target free, and the switch follows at once.
        await h.quota.setRefreshHook { [h, spent] in
            await h.quota.push(spent.merging([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                                              target.folder: quotaReading(target, now: h.clock.now(), used: 20)]) { $1 })
        }
        h.process.onClose { await runtime.clear(profile: source.url) }
        h.clock.advance(by: 61); try await check()
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1)
        let switched = await h.snapshot()
        XCTAssertEqual(switched.currentFolder, target.folder)
        await h.cleanup()
    }

    func testTheAutomaticReadLeavesALoginClaudeTurnedAwayToItsOwnPace() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), refused = try h.profile("Claude_204"), start = h.clock.now()
        try files.installNativeWork()
        await runtime.set(profile: source, pid: 101, startedAt: start, busy: true)
        var readings: [ProfileFolder: QuotaReading] = [:]
        for profile in h.profiles where AutomaticSwitchPolicy.identity(profile) != nil {
            readings[profile.folder] = quotaReading(profile, now: start, used: 100)
        }
        readings[refused.folder] = QuotaReading(freshness: .unavailable, lastError: .signedOut)
        await h.quota.push(readings)
        try files.report(pid: 101)
        await h.start()
        let before = await h.quota.refreshes.count
        await h.engine.checkAutomaticSwitch()
        let reads = await h.quota.refreshes.dropFirst(before)
        XCTAssertTrue(reads.contains { $0.1 && $0.0.contains(source.folder) }, "The others are read as ever")
        XCTAssertFalse(reads.contains { $0.1 && $0.0.contains(refused.folder) }, "The same cookie is not forced through")
        XCTAssertTrue(reads.contains { !$0.1 && $0.0.contains(refused.folder) }, "Its own pace still applies")
        await h.cleanup()
    }

    func testFiguresThatCannotTellAreReadAgainAfterTenMinutesOrAsSoonAsTheAccountsOrTheSettingChange() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude")
        try files.installNativeWork()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: true)
        // Only the spent account has figures; the reads of the others bring none.
        func check() async throws {
            try files.report(pid: 101)
            await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100)])
            await h.engine.checkAutomaticSwitch()
        }
        func forcedReads() async -> Int { await h.quota.refreshes.filter(\.1).count }
        await h.start(); try await check()
        var reads = await forcedReads()
        for (seconds, expected) in [(61, 0), (480, 0), (60, 1)] {
            h.clock.advance(by: TimeInterval(seconds)); try await check()
            let now = await forcedReads()
            XCTAssertEqual(now - reads, expected, "after \(seconds) s")
            reads = now
        }
        let removed = try XCTUnwrap(h.profiles.first { $0.folder != source.folder && AutomaticSwitchPolicy.identity($0) != nil })
        await h.engine.perform(.remove(folder: removed.folder))
        h.clock.advance(by: 60); try await check()
        var now = await forcedReads()
        XCTAssertEqual(now - reads, 1, "Another set of accounts is read at once")
        reads = now
        h.clock.advance(by: 60); try await check()
        now = await forcedReads()
        XCTAssertEqual(now, reads)
        await h.engine.perform(.setAutoSwitch(false)); await h.engine.perform(.setAutoSwitch(true))
        try await check()
        now = await forcedReads()
        XCTAssertEqual(now - reads, 1, "Turning the setting on again reads at once")
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        await h.cleanup()
    }

    func testFailedAutomaticTargetIsNotImmediatelyTriedAgainAfterReturningToSource() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installNativeWork()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: true)
        try files.report(pid: 101)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        h.process.onClose { await runtime.clear(profile: source.url) }
        h.process.onLaunchAsync { profile, _ in
            if ProfilePaths.same(profile, source.url) {
                await runtime.set(profile: source, pid: 303, startedAt: h.clock.now(), busy: false)
                try files.report(pid: 303)
            }
        }
        await h.start()
        h.process.enqueueLaunch(.failure(.failed("target")))
        await h.engine.checkAutomaticSwitch()
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, [target.folder.name, source.folder.name])
        h.clock.advance(by: 31); try files.report(pid: 303)
        await h.engine.checkAutomaticSwitch()
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1)
        await h.cleanup()
    }

    func testAHistoryThatCannotBeFollowedDoesNotHoldTheSwitch() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installNativeWork()
        // A line that cannot be read leaves the history unverified.
        let transcript = try XCTUnwrap(h.world.cliSessions.first { $0.cliSessionID == SandboxFixture.ID.liveSession }).transcriptFile
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken\n".utf8)); try handle.close()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: true)
        try files.report(pid: 101)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        h.process.onClose { await runtime.clear(profile: source.url) }
        await h.start(); await h.engine.checkAutomaticSwitch()
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.currentFolder, target.folder)
        XCTAssertFalse(snapshot.banners.paused(.continuationNotReady))
        // The conversation goes on in the next account; nothing is replayed from what was not read.
        XCTAssertEqual(try files.request().phase, "prepared")
        XCTAssertFalse(try files.request().work.branchComplete)
        await h.cleanup()
    }

    func testAContinuationThatCannotBePreparedPausesWithoutBlamingTheTargetOrRepeating() async throws {
        guard geteuid() != 0 else { throw XCTSkip("POSIX write permissions do not constrain root") }
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installNativeWork()
        // The handoff cannot be written.
        let requests = h.world.paths.companionDataDirectory.appending(path: "NativeRecovery/requests")
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: requests.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: requests.path) }
        func exhausted() async throws {
            try files.report(pid: 101)
            await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                                target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        }
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: true)
        try await exhausted()
        await h.start(); await h.engine.checkAutomaticSwitch()
        var snapshot = await h.snapshot()
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty, "Nothing is closed without a prepared continuation")
        XCTAssertNil(snapshot.lastResult, "The pause explains it; no failure notice")
        XCTAssertTrue(snapshot.banners.paused(.continuationNotReady))
        XCTAssertEqual(snapshot.banners.pauseRetry, h.clock.now().addingTimeInterval(600), "it says when it tries again")
        // Half a minute later it is not tried again: it would only fail the same way.
        h.clock.advance(by: 61); try await exhausted()
        await h.engine.checkAutomaticSwitch()
        snapshot = await h.snapshot()
        XCTAssertNil(snapshot.lastResult)
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        // Once the handoff can be written, the same target is used: it was never set aside.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: requests.path)
        h.clock.advance(by: 600); try await exhausted()
        h.process.onClose { await runtime.clear(profile: source.url) }
        await h.engine.checkAutomaticSwitch()
        snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.currentFolder, target.folder)
        XCTAssertFalse(snapshot.banners.paused(.continuationNotReady))
        await h.cleanup()
    }

    func testAConversationThatNeverReportedDoesNotHoldTheSwitch() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installNativeWork()
        // The source is spent, and its working conversation never reported.
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: true)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        h.process.onClose { await runtime.clear(profile: source.url) }
        await h.start(); await h.engine.checkAutomaticSwitch()
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.currentFolder, target.folder)
        XCTAssertEqual(try files.request().phase, "prepared", "It goes on in the next account")
        XCTAssertTrue(try files.request().sourceWasBusy)
        await h.cleanup()
    }

    func testAfterAFailedAutomaticAttemptAManualSwitchStartsTheNewAccountsChecksAfresh() async throws {
        guard geteuid() != 0 else { throw XCTSkip("POSIX write permissions do not constrain root") }
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        // The automatic attempt cannot write its handoff, so it waits ten minutes before trying again.
        try files.installNativeWork()
        let requests = h.world.paths.companionDataDirectory.appending(path: "NativeRecovery/requests")
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: requests.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: requests.path) }
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: true)
        try files.report(pid: 101)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        await h.start(); await h.engine.checkAutomaticSwitch()
        var snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.currentFolder, source.folder)
        XCTAssertTrue(snapshot.banners.paused(.continuationNotReady))
        // The person switches by hand, and later the account it moved to runs out too.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: requests.path)
        h.process.onClose { await runtime.clear(profile: source.url) }
        await h.engine.perform(.switchTo(folder: target.folder))
        snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.currentFolder, target.folder)
        XCTAssertFalse(snapshot.banners.paused(.continuationNotReady))
        h.clock.advance(by: NativeRecoverySummary.settlingTime)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 20),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 100)])
        await h.engine.checkAutomaticSwitch()
        snapshot = await h.snapshot()
        // The account just left is set aside until its limit ends, so none can take over yet.
        XCTAssertTrue(snapshot.banners.paused(.noAvailableAccount),
                      "The new account is looked at once its conversations had time to report, not after the last one's wait")
        await h.cleanup()
    }

    func testWhileTheAccountHasQuotaTheCheckDoesNotVerifyRuntimes() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installNativeWork()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: true)
        try files.report(pid: 101)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 50),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        await h.start()
        let before = await runtime.sessionReads
        await h.engine.checkAutomaticSwitch()
        let after = await runtime.sessionReads
        XCTAssertEqual(after, before, "Nothing has run out, so no conversation or process is inspected")
        // A reported limit is still noticed straight away and verified before anything closes.
        let now = h.clock.now().timeIntervalSince1970 * 1000
        try files.report(pid: 101, quotaBlock: NativeQuotaBlock(reason: "rateLimit", observedAt: now, until: now + 600_000))
        h.process.onClose { await runtime.clear(profile: source.url) }
        await h.engine.checkAutomaticSwitch()
        let checked = await runtime.sessionReads
        XCTAssertGreaterThan(checked, after)
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.currentFolder, target.folder)
        await h.cleanup()
    }

    func testAnUnknownReadingDecidesNothingFetchesNothingAndNeverSwitchesFromCache() async throws {
        for initial in ["missing", "stale", "expired"] {
            let runtime = NativeSwitchRuntimeFixture()
            let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
            let files = NativeSwitchFiles(harness: h)
            let source = try h.profile("Claude"), target = try h.profile("Claude_204")
            try files.installNativeWork()
            await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
            try files.report(pid: 101)
            var cached = quotaReading(source, now: h.clock.now(), used: 100)
            if initial == "stale" { cached.freshness = .stale }
            if initial == "expired" { cached.snapshot?.fetchedAt = h.clock.now().addingTimeInterval(-300) }
            var values = [target.folder: quotaReading(target, now: h.clock.now(), used: 20)]
            if initial != "missing" { values[source.folder] = cached }
            await h.quota.push(values); await h.start()
            let before = await h.quota.refreshes.count
            let reads = await runtime.sessionReads
            await h.engine.checkAutomaticSwitch()
            let refreshes = await h.quota.refreshes.count
            XCTAssertEqual(refreshes, before, "\(initial): the regular refresh brings the next reading")
            let inspected = await runtime.sessionReads
            XCTAssertEqual(inspected, reads, "\(initial)")
            XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty, "\(initial)")
            // The next fresh reading decides.
            await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                                target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
            h.process.onClose { await runtime.clear(profile: source.url) }
            await h.engine.checkAutomaticSwitch()
            XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1, "\(initial)")
            await h.cleanup()
        }
    }

    func testAPauseStaysWhileItsReadingAgesAndEndsOnAFreshReadingWithQuota() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installNativeWork()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
        try files.report(pid: 101)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 100)])
        await h.start(); await h.engine.checkAutomaticSwitch()
        var snapshot = await h.snapshot()
        XCTAssertTrue(snapshot.banners.paused(.noAvailableAccount))
        // The fixture's other accounts have no figures yet: they are read again in ten minutes.
        XCTAssertEqual(snapshot.banners.pauseRetry, h.clock.now().addingTimeInterval(600), "it says when it looks again")
        h.clock.advance(by: 121); try files.report(pid: 101)
        let refreshes = await h.quota.refreshes.count
        await h.engine.checkAutomaticSwitch()
        snapshot = await h.snapshot()
        XCTAssertTrue(snapshot.banners.paused(.noAvailableAccount), "An older reading is not evidence of quota")
        let after = await h.quota.refreshes.count
        XCTAssertEqual(after, refreshes)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 40)])
        await h.engine.checkAutomaticSwitch()
        snapshot = await h.snapshot()
        XCTAssertFalse(snapshot.banners.paused(.noAvailableAccount))
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        await h.cleanup()
    }

    func testDisablingAutomaticSwitchDuringTheAlternativesRefreshPreventsClosing() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installNativeWork()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
        try files.report(pid: 101)
        let confirmed = [source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                         target.folder: quotaReading(target, now: h.clock.now(), used: 20)]
        await h.quota.push(confirmed)
        await h.start()
        let held = HeldClose()
        await h.quota.setRefreshHook { await held.hold(); await h.quota.push(confirmed) }
        let checking = Task { await h.engine.checkAutomaticSwitch() }
        let entered = await eventually { await held.entered }
        XCTAssertTrue(entered)
        await h.engine.perform(.setAutoSwitch(false))
        await held.release(); await checking.value
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        await h.cleanup()
    }

    func testAnotherAppInstancesSwitchLeaseRefusesBeforeTouchingTheRunningAccount() async throws {
        let h = try await EngineHarness(); defer { h.scratch.cleanup() }
        let target = try h.profile("Claude_204")
        let lease = try CompanionFileLease(file: h.world.paths.companionDataDirectory.appending(path: "locks/account-switch.lock"))
        defer { lease.release() }
        await h.start()
        await h.engine.perform(.switchTo(folder: target.folder))
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .switchTo(target.folder), reason: .operationInFlight))
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        XCTAssertTrue(h.process.recordedLaunches().isEmpty)
        XCTAssertNil(snapshot.taskGuardPrompt)
        await h.cleanup()
    }

    func testSwitchCapturesBeforeCloseAndOnlyActivatesAfterSyncAndLaunch() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installNativeWork()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now().addingTimeInterval(-20), busy: true)
        try files.report(pid: 101, startedAt: h.clock.now().addingTimeInterval(-20))
        let observed = NativeSwitchObservations()
        h.process.onClose {
            do {
                let request = try files.request()
                XCTAssertEqual(request.phase, "prepared")
                XCTAssertEqual(Set(request.work.tasks.map { $0.kind.rawValue }), ["bash", "monitor"])
                XCTAssertFalse(try files.operation().ready)
                await observed.record("captured-before-close")
            } catch { XCTFail("Source was not captured before closing: \(error)") }
            h.clock.advance(by: 1)
            await runtime.clear(profile: source.url)
        }
        h.process.onLaunchAsync { profile, link in
            guard ProfilePaths.same(profile, target.url) else { return }
            XCTAssertNotNil(link)
            XCTAssertFalse(try files.operation().ready, "A request must not be active while target launch is still in progress")
            XCTAssertTrue(FileManager.default.fileExists(atPath: try files.sessionFile(target).path), "Sync must precede target launch")
            await observed.record("synced-before-launch")
            try files.focus(target)
            await runtime.set(profile: target, pid: 202, startedAt: h.clock.now(), busy: false)
            try files.report(pid: 202)
        }
        await h.start()
        try await switchNow(h, to: target.folder)
        let events = await observed.events()
        XCTAssertEqual(events, ["captured-before-close", "synced-before-launch"])
        XCTAssertTrue(try files.operation().ready)
        XCTAssertEqual(try files.request().phase, "prepared", "Target launch alone must not claim native continuation executed")
        let observer = NativeRecoveryCoordinator(paths: h.world.paths, inspector: runtime, clock: h.clock)
        let summary = await observer.poll()
        XCTAssertEqual(summary?.waiting, 1)
        XCTAssertEqual(try files.request().phase, "armed")
        XCTAssertEqual(try files.request().pid, 202)
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, [target.folder.name])
        await h.cleanup()
    }

    func testBackupOrSyncFailureInvalidatesHandoffEvenWithAnExistingTargetConversation() async throws {
        for failure in ["backup", "sync"] {
            let runtime = NativeSwitchRuntimeFixture()
            let h = try await EngineHarness(nativeRuntimeInspector: runtime)
            let files = NativeSwitchFiles(harness: h)
            let source = try h.profile("Claude"), target = try h.profile("Claude_204")
            try files.installNativeWork()
            // A prior copy must not make this failed transfer appear safe to resume.
            try AtomicFile.write(AtomicFile.read(files.sessionFile(source)), to: files.sessionFile(target))
            await runtime.set(profile: source, pid: 101, startedAt: h.clock.now().addingTimeInterval(-20), busy: true)
            try files.report(pid: 101, startedAt: h.clock.now().addingTimeInterval(-20))
            await h.start()
            if failure == "backup" {
                try AtomicFile.write(Data("blocked".utf8), to: h.world.paths.companionDataDirectory.appending(path: "Backups"))
            } else {
                let corrupt = try h.sessionFile(target, id: "local_" + SandboxFixture.ID.session204)
                try AtomicFile.write(Data("invalid".utf8), to: corrupt)
            }
            h.process.onClose {
                XCTAssertEqual(try? files.request().phase, "prepared")
                h.clock.advance(by: 1)
                await runtime.clear(profile: source.url)
            }
            h.process.onLaunchAsync { profile, _ in
                guard ProfilePaths.same(profile, target.url) else { return }
                try files.focus(target)
                await runtime.set(profile: target, pid: 202, startedAt: h.clock.now(), busy: false)
                try files.report(pid: 202)
            }
            try await switchNow(h, to: target.folder)
            XCTAssertNil(try? files.operation(), "A failed \(failure) must withdraw the pending generation")
            let observer = NativeRecoveryCoordinator(paths: h.world.paths, inspector: runtime, clock: h.clock)
            let summary = await observer.poll()
            XCTAssertNil(summary)
            XCTAssertNotEqual(try files.request().phase, "armed")
            let snapshot = await h.snapshot()
            if case .switched(_, let warnings) = snapshot.lastResult?.outcome {
                XCTAssertTrue(warnings.contains(.workContinuationUnavailable))
                if failure == "backup" { XCTAssertTrue(warnings.contains(.backupFailed)) }
                else { XCTAssertTrue(warnings.contains { if case .sessionsNotSynced = $0 { return true }; return false }) }
            } else { XCTFail("Expected a switch with a transfer warning") }
            await h.cleanup()
        }
    }

    func testAutomaticTransferFailureReturnsToOriginalConversationWithoutActivatingOrRestoringFiles() async throws {
        for failure in ["backup", "sync", "capture"] {
            let runtime = NativeSwitchRuntimeFixture()
            let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
            let files = NativeSwitchFiles(harness: h)
            let source = try h.profile("Claude"), target = try h.profile("Claude_204")
            try files.installRateLimitedTurn()
            let original = try AtomicFile.read(files.sessionFile(source))
            await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
            try files.report(pid: 101)
            await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                                target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
            await h.start()
            if failure == "backup" {
                try AtomicFile.write(Data("blocked".utf8), to: h.world.paths.companionDataDirectory.appending(path: "Backups"))
            } else if failure == "sync" {
                let corrupt = try h.sessionFile(target, id: "local_" + SandboxFixture.ID.session204)
                try AtomicFile.write(Data("invalid".utf8), to: corrupt)
            }
            let transcript = try XCTUnwrap(h.world.cliSessions.first { $0.cliSessionID == SandboxFixture.ID.liveSession }).transcriptFile
            h.process.onClose {
                await runtime.clear(profile: source.url)
                if failure == "capture" {
                    do { try FileManager.default.removeItem(at: transcript) }
                    catch { XCTFail("Could not inject post-close capture failure: \(error)") }
                }
            }
            await h.engine.checkAutomaticSwitch()
            let snapshot = await h.snapshot(), state = try await h.store.load()
            XCTAssertEqual(snapshot.lastResult?.outcome,
                .failed(operation: .switchTo(target.folder), reason: .transferFailedReturnedToPreviousAccount), failure)
            XCTAssertEqual(snapshot.currentFolder, source.folder, failure)
            XCTAssertEqual(state.activeFolder, source.folder, failure)
            XCTAssertTrue(state.relaunchDebt.isEmpty, failure)
            XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, [source.folder.name], failure)
            XCTAssertEqual(h.process.recordedLaunches().first?.deepLink?.absoluteString,
                "claude://code/continue?session=local_" + SandboxFixture.ID.liveSession, failure)
            XCTAssertNil(try? files.operation(), "CC-Relay must not activate continuation when returning to the source")
            XCTAssertEqual(try AtomicFile.read(files.sessionFile(source)), original, failure)
            if failure == "sync" {
                XCTAssertEqual(try AtomicFile.read(files.sessionFile(target)), original,
                    "Successful copies from the partial sync are retained; returning must not restore an older tree")
            }
            await h.cleanup()
        }
    }

    func testAnAutomaticSwitchGoesBackWhenTheTargetCannotStartTheConversation() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installRateLimitedTurn()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
        try files.report(pid: 101)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        await h.start()
        // Closing, Desktop leaves the conversation waiting for the person: nothing may wake it on the target.
        h.process.onClose {
            await runtime.clear(profile: source.url)
            do {
                let file = try files.sessionFile(source)
                var object = try SessionJSON.object(AtomicFile.read(file), at: file)
                object["interruptedAwaitingPerson"] = true
                try AtomicFile.write(JSONSerialization.data(withJSONObject: object), to: file)
            } catch { XCTFail("Could not mark the conversation as waiting for the person: \(error)") }
        }
        await h.engine.checkAutomaticSwitch()
        let snapshot = await h.snapshot(), state = try await h.store.load()
        XCTAssertEqual(snapshot.lastResult?.outcome,
            .failed(operation: .switchTo(target.folder), reason: .transferFailedReturnedToPreviousAccount))
        XCTAssertEqual(state.activeFolder, source.folder)
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, [source.folder.name])
        XCTAssertNil(try? files.operation(), "CC-Relay must not activate continuation when returning to the source")
        await h.cleanup()
    }

    func testAFailedTransferDoesNotCloseClaudeAgainUntilTheLimitEndsOrTheSettingIsTurnedBackOn() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installRateLimitedTurn()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
        try files.report(pid: 101)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        await h.start()
        // A cause that does not clear by itself: the backups location is a file, not a folder.
        try AtomicFile.write(Data("blocked".utf8), to: h.world.paths.companionDataDirectory.appending(path: "Backups"))
        h.process.onClose { await runtime.clear(profile: source.url) }
        var pid: Int32 = 101
        // The reopened original chat runs again, at its limit: the person opened it, as the notice asks.
        func limitedAgain(after seconds: TimeInterval) async throws {
            h.clock.advance(by: seconds); pid += 1
            await runtime.set(profile: source, pid: pid, startedAt: h.clock.now(), busy: false)
            try files.report(pid: pid)
            await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                                target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        }

        await h.engine.checkAutomaticSwitch()
        let failed = await h.snapshot()
        XCTAssertEqual(failed.lastResult?.outcome,
            .failed(operation: .switchTo(target.folder), reason: .transferFailedReturnedToPreviousAccount))
        XCTAssertTrue(failed.banners.paused(.lastSwitchFailed))
        XCTAssertEqual(h.process.recordedImmediateQuits().count, 1)
        for _ in 1...3 {
            try await limitedAgain(after: 31)
            await h.engine.checkAutomaticSwitch()
        }
        XCTAssertEqual(h.process.recordedImmediateQuits().count, 1, "The same cause must not close Claude every half minute")
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, [source.folder.name])
        let held = await h.snapshot()
        XCTAssertTrue(held.banners.paused(.lastSwitchFailed))

        // Turning automatic switching off and on is the person asking for another try.
        await h.engine.perform(.setAutoSwitch(false))
        await h.engine.perform(.setAutoSwitch(true))
        try await limitedAgain(after: 31)
        await h.engine.checkAutomaticSwitch()
        XCTAssertEqual(h.process.recordedImmediateQuits().count, 2)

        // Held again; the next limit, once this one has reset, gets one try of its own.
        try await limitedAgain(after: 31)
        await h.engine.checkAutomaticSwitch()
        XCTAssertEqual(h.process.recordedImmediateQuits().count, 2)
        try await limitedAgain(after: 3_600)
        await h.engine.checkAutomaticSwitch()
        XCTAssertEqual(h.process.recordedImmediateQuits().count, 3)
        await h.cleanup()
    }

    func testAutomaticTransferDoesNotRequireAnUnrelatedFocusedConversationToReopen() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installRateLimitedTurn()
        let focused = try h.sessionFile(source, id: "local_" + SandboxFixture.ID.archivedSession)
        var record = try SessionJSON.object(AtomicFile.read(focused), at: focused)
        record["lastFocusedAt"] = Int(h.clock.now().timeIntervalSince1970 * 1_000) + 10_000
        try AtomicFile.write(JSONSerialization.data(withJSONObject: record), to: focused)
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
        try files.report(pid: 101)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        h.process.onClose { await runtime.clear(profile: source.url) }
        await h.start()
        await h.engine.checkAutomaticSwitch()
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.currentFolder, target.folder)
        guard case .switched(_, let warnings) = snapshot.lastResult?.outcome else {
            await h.cleanup()
            return XCTFail("The verified runtime's transfer is independent of the last focused conversation")
        }
        XCTAssertTrue(warnings.contains(.conversationNotReopened))
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, [target.folder.name])
        XCTAssertTrue(try files.operation().ready)
        XCTAssertEqual(try files.request().sessionID, SandboxFixture.ID.liveSession)
        XCTAssertEqual(try files.request().phase, "prepared")
        await h.cleanup()
    }

    func testAutomaticFailedTransferKeepsOnlySourceOwedWhenReopeningItFails() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installRateLimitedTurn()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
        try files.report(pid: 101)
        await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                            target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
        await h.start()
        try AtomicFile.write(Data("blocked".utf8), to: h.world.paths.companionDataDirectory.appending(path: "Backups"))
        h.process.onClose { await runtime.clear(profile: source.url) }
        h.process.enqueueLaunch(.failure(.failed("source reopen")))
        await h.engine.checkAutomaticSwitch()
        let snapshot = await h.snapshot(), state = try await h.store.load()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .switchTo(target.folder), reason: .transferFailedNotReopened))
        XCTAssertEqual(state.activeFolder, source.folder)
        XCTAssertEqual(state.relaunchDebt, [source.folder], "A later recovery must not launch the rejected target")
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, [source.folder.name])
        XCTAssertNil(try? files.operation())
        await h.cleanup()
    }

    func testAutomaticSourceCloseOrLeaseFailureDoesNotExcludeHealthyTarget() async throws {
        for failure in ["close", "lease"] {
            let runtime = NativeSwitchRuntimeFixture()
            let h = try await EngineHarness(autoSwitch: true, nativeRuntimeInspector: runtime)
            let files = NativeSwitchFiles(harness: h)
            let source = try h.profile("Claude"), target = try h.profile("Claude_204")
            try files.installRateLimitedTurn()
            await runtime.set(profile: source, pid: 101, startedAt: h.clock.now(), busy: false)
            try files.report(pid: 101)
            await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                                target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
            await h.start()
            let lease = failure == "lease" ? try CompanionFileLease(
                file: h.world.paths.companionDataDirectory.appending(path: "locks/account-switch.lock")) : nil
            if failure == "close" { h.process.enqueueQuit(.failure(.failed("source close"))) }
            await h.engine.checkAutomaticSwitch()
            lease?.release()
            let failed = await h.snapshot()
            XCTAssertEqual(failed.lastResult?.outcome, .failed(operation: .switchTo(target.folder),
                reason: failure == "close" ? .couldNotCloseClaude : .operationInFlight))
            XCTAssertTrue(h.process.recordedLaunches().isEmpty)

            // Only the target's own failures bring another try within a minute; this waits ten.
            let quits = h.process.recordedQuitTimeouts().count + h.process.recordedScopedQuits().count
            h.clock.advance(by: 31)
            await h.engine.checkAutomaticSwitch()
            XCTAssertEqual(h.process.recordedQuitTimeouts().count + h.process.recordedScopedQuits().count, quits, failure)
            XCTAssertTrue(h.process.recordedLaunches().isEmpty, failure)
            h.clock.advance(by: 570)
            try files.report(pid: 101)
            await h.quota.push([source.folder: quotaReading(source, now: h.clock.now(), used: 100),
                                target.folder: quotaReading(target, now: h.clock.now(), used: 20)])
            h.process.onClose { await runtime.clear(profile: source.url) }
            h.process.onLaunchAsync { profile, _ in
                if ProfilePaths.same(profile, target.url) { try files.focus(target) }
            }
            await h.engine.checkAutomaticSwitch()
            let retried = await h.snapshot()
            XCTAssertEqual(retried.currentFolder, target.folder, failure)
            XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, [target.folder.name], failure)
            await h.cleanup()
        }
    }

    func testFailedTargetRedirectsSavedNativeWorkToTheNewFallbackRuntime() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installNativeWork()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now().addingTimeInterval(-20), busy: true)
        try files.report(pid: 101, startedAt: h.clock.now().addingTimeInterval(-20))
        let observed = NativeSwitchObservations()
        h.process.onClose {
            if let operation = try? files.operation() { await observed.record(operation.operationID) }
            XCTAssertEqual(try? files.request().phase, "prepared")
            h.clock.advance(by: 1)
            await runtime.clear(profile: source.url)
        }
        h.process.onLaunchAsync { profile, _ in
            XCTAssertFalse(try files.operation().ready)
            if ProfilePaths.same(profile, source.url) {
                await runtime.set(profile: source, pid: 404, startedAt: h.clock.now(), busy: false)
                try files.report(pid: 404)
                // The fallback runtime is already up before redirect is persisted.
                h.clock.advance(by: 1)
            }
        }
        await h.start()
        h.process.enqueueLaunch(.failure(.failed("target")))
        try await switchNow(h, to: target.folder)
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .switchTo(target.folder), reason: .returnedToPreviousAccount))
        let redirected = try files.operation()
        let originals = await observed.events()
        XCTAssertNotEqual(redirected.operationID, originals.first)
        XCTAssertEqual(redirected.targetProfile, source.folder.name)
        XCTAssertTrue(redirected.ready)
        let observer = NativeRecoveryCoordinator(paths: h.world.paths, inspector: runtime, clock: h.clock)
        _ = await observer.poll()
        XCTAssertEqual(try files.request().phase, "armed")
        XCTAssertEqual(try files.request().pid, 404)
        XCTAssertEqual(try files.request().targetAccountID, source.identity?.accountUUID)
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, [target.folder.name, source.folder.name])
        await h.cleanup()
    }

    func testTargetFailureDoesNotReviveWorkBlockedDuringSourceClose() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installNativeWork()
        let transcript = try XCTUnwrap(h.world.cliSessions.first {
            $0.cliSessionID == SandboxFixture.ID.liveSession
        }).transcriptFile
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now().addingTimeInterval(-20), busy: true)
        try files.report(pid: 101, startedAt: h.clock.now().addingTimeInterval(-20))
        h.process.onClose {
            XCTAssertEqual(try? files.request().phase, "prepared")
            try? FileManager.default.removeItem(at: transcript)
            h.clock.advance(by: 1)
            await runtime.clear(profile: source.url)
        }
        h.process.onLaunchAsync { profile, _ in
            XCTAssertEqual(try files.request().phase, "blocked")
            if ProfilePaths.same(profile, source.url) {
                await runtime.set(profile: source, pid: 404, startedAt: h.clock.now(), busy: false)
                try files.report(pid: 404)
            }
        }
        await h.start()
        h.process.enqueueLaunch(.failure(.failed("target")))
        try await switchNow(h, to: target.folder)
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome,
            .failed(operation: .switchTo(target.folder), reason: .returnedToPreviousAccount))
        XCTAssertTrue(try files.operation().ready)
        XCTAssertEqual(try files.operation().targetProfile, source.folder.name)
        let observer = NativeRecoveryCoordinator(paths: h.world.paths, inspector: runtime, clock: h.clock)
        let summary = await observer.poll()
        XCTAssertEqual(summary?.attention, 1)
        XCTAssertEqual(try files.request().phase, "blocked")
        XCTAssertNotNil(try files.request().activationError)
        XCTAssertNil(try files.request().pid)
        await h.cleanup()
    }

    func testNativeRecoveryPollAndAccountSwitchCannotOverlapAcrossRuntimeInspection() async throws {
        let runtime = NativeSwitchRuntimeFixture()
        let h = try await EngineHarness(nativeRuntimeInspector: runtime)
        defer { h.scratch.cleanup() }
        let files = NativeSwitchFiles(harness: h)
        let source = try h.profile("Claude"), target = try h.profile("Claude_204")
        try files.installNativeWork()
        await runtime.set(profile: source, pid: 101, startedAt: h.clock.now().addingTimeInterval(-20), busy: true)
        try files.report(pid: 101, startedAt: h.clock.now().addingTimeInterval(-20))
        h.process.onClose {
            h.clock.advance(by: 1)
            await runtime.clear(profile: source.url)
            await runtime.clear(profile: target.url)
        }
        h.process.onLaunchAsync { profile, _ in
            let opened = ProfilePaths.same(profile, target.url) ? target : source
            let pid: Int32 = opened.folder == target.folder ? 202 : 303
            try files.focus(opened)
            await runtime.set(profile: opened, pid: pid, startedAt: h.clock.now(), busy: false)
            try files.report(pid: pid)
        }
        await h.start()
        try await switchNow(h, to: target.folder)
        let firstOperation = try files.operation(), firstRequest = try files.request()
        XCTAssertTrue(firstOperation.ready)
        XCTAssertEqual(firstRequest.phase, "prepared")

        // Reenter Engine.perform while poll is suspended in another actor, after it acquired
        // the operation gate. Checking isBusy only before the await would not protect this gap.
        await runtime.pauseNextSessions(profile: target.url)
        let poll = Task { await h.engine.pollNativeRecovery() }
        let paused = await eventually { await runtime.sessionsPaused }
        guard paused else {
            await runtime.resumeSessions()
            _ = await poll.value
            await h.cleanup()
            XCTFail("Recovery poll did not reach the held runtime inspection")
            return
        }
        h.inspector.enqueue(.busy([CodeTaskInfo(pid: 101, sessionID: SandboxFixture.ID.liveSession, reason: .statusBusy)]))
        let queuedSwitch = Task { await h.engine.perform(.switchTo(folder: source.folder)) }
        let accepted = await eventually { await h.snapshot().isPreparingOperation }
        XCTAssertTrue(accepted)
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 1, "A switch must not close the account while its recovery poll holds the gate")
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, [target.folder.name])
        XCTAssertEqual(try? files.operation().operationID, firstOperation.operationID)
        XCTAssertEqual(try? files.request().requestID, firstRequest.requestID)
        XCTAssertEqual(try? files.request().phase, "prepared")
        let heldSnapshot = await h.snapshot()
        XCTAssertEqual(heldSnapshot.currentFolder, target.folder)
        XCTAssertNil(heldSnapshot.taskGuardPrompt)
        XCTAssertNil(heldSnapshot.operation)

        XCTAssertTrue(heldSnapshot.isPreparingOperation)
        // A duplicate click is still rejected; only the first accepted action is retained.
        await h.engine.perform(.switchTo(folder: source.folder))
        h.process.onClose {
            // Conversely, an explicit poll during the next switch cannot arm anything while
            // the new generation is only prepared and the previous runtime is still alive.
            XCTAssertNotEqual(try? files.operation().operationID, firstOperation.operationID)
            XCTAssertEqual(try? files.request().phase, "prepared")
            await h.engine.pollNativeRecovery()
            XCTAssertEqual(try? files.request().phase, "prepared")
            XCTAssertNil(try? files.request().pid)
            h.clock.advance(by: 1)
            await runtime.clear(profile: source.url)
            await runtime.clear(profile: target.url)
        }
        await runtime.resumeSessions()
        _ = await poll.value
        let offered = await eventually { await h.snapshot().taskGuardPrompt != nil }
        XCTAssertTrue(offered, "The accepted switch must proceed without a second click")
        await h.engine.perform(.taskGuard(.switchNow))
        await queuedSwitch.value
        let secondOperation = try files.operation()
        XCTAssertNotEqual(secondOperation.operationID, firstOperation.operationID)
        XCTAssertTrue(secondOperation.ready)
        XCTAssertEqual(secondOperation.targetProfile, source.folder.name)
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 2)
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, [target.folder.name, source.folder.name])
        await h.engine.pollNativeRecovery()
        XCTAssertEqual(try files.request().operationID, secondOperation.operationID)
        XCTAssertEqual(try files.request().phase, "armed")
        XCTAssertEqual(try files.request().pid, 303)
        let afterQueued = await h.snapshot()
        XCTAssertFalse(afterQueued.isPreparingOperation)

        await runtime.pauseNextSessions(profile: source.url)
        let finalPoll = Task { await h.engine.pollNativeRecovery() }
        let finalPaused = await eventually { await runtime.sessionsPaused }
        XCTAssertTrue(finalPaused)
        let rename = Task { await h.engine.perform(.rename(folder: source.folder, name: "must not run after stop")) }
        let waiting = await eventually { await h.snapshot().isPreparingOperation }
        XCTAssertTrue(waiting)
        await h.engine.stop()
        await rename.value
        await runtime.resumeSessions()
        _ = await finalPoll.value
        let afterStopped = await h.snapshot()
        XCTAssertFalse(afterStopped.isPreparingOperation)
        XCTAssertFalse(afterStopped.accounts.contains { $0.displayName == "must not run after stop" })
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, 2)
        await h.cleanup()
    }

    private func switchNow(_ h: EngineHarness, to folder: ProfileFolder) async throws {
        h.inspector.enqueue(.busy([CodeTaskInfo(pid: 101, sessionID: SandboxFixture.ID.liveSession, reason: .statusBusy)]))
        let operation = Task { await h.engine.perform(.switchTo(folder: folder)) }
        let offered = await eventually { await h.snapshot().taskGuardPrompt != nil }
        guard offered else {
            await h.engine.perform(.taskGuard(.cancel)); operation.cancel()
            XCTFail("Switch did not reach the task guard")
            throw NativeSwitchFixtureError.missing
        }
        await h.engine.perform(.taskGuard(.switchNow))
        await operation.value
    }
}

private struct NativeSwitchFiles: Sendable {
    let harness: EngineHarness
    private var session: String { SandboxFixture.ID.liveSession }
    private var directory: URL { harness.world.paths.companionDataDirectory.appending(path: "NativeRecovery") }

    func command(status: String) throws -> URL {
        let file = directory.appending(path: "commands/cmd-preflight/state.json")
        let previous = (try? AtomicFile.read(file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let owner = previous?["owner"] as? [String: Any] ?? ["pid": 101, "start": harness.clock.now().timeIntervalSince1970 * 1_000]
        let object: [String: Any] = ["version": 1, "executionProtocol": 3, "jobID": "cmd-preflight", "sessionID": session,
            "status": status, "owner": owner]
        try AtomicFile.write(JSONSerialization.data(withJSONObject: object), to: file)
        return file
    }

    func permissionMode(_ mode: String, profile: ProfileSnapshot) throws {
        let file = try sessionFile(profile)
        var object = try SessionJSON.object(AtomicFile.read(file), at: file)
        object["permissionMode"] = mode
        try AtomicFile.write(JSONSerialization.data(withJSONObject: object), to: file)
    }

    func bypass(profile: ProfileSnapshot, choice: Bool, gate: Bool) throws {
        let account = try XCTUnwrap(profile.identity?.accountUUID)
        let object: [String: Any] = ["preferences": ["bypassPermissionsOptInByAccount": [account: choice],
            "bypassPermissionsGateByAccount": [account: gate]]]
        try AtomicFile.write(JSONSerialization.data(withJSONObject: object), to: profile.url.appending(path: CodePreferenceInheritance.fileName))
    }

    func sessionFile(_ profile: ProfileSnapshot) throws -> URL { try harness.sessionFile(profile, id: "local_" + session) }
    func operation() throws -> NativeRecoveryOperation {
        try JSONDecoder().decode(NativeRecoveryOperation.self, from: AtomicFile.read(directory.appending(path: "active.json")))
    }
    func request() throws -> NativeRecoveryRequest {
        try JSONDecoder().decode(NativeRecoveryRequest.self, from: AtomicFile.read(directory.appending(path: "requests/\(session).json")))
    }
    func report(pid: Int32, busy: Bool = false, userStopped: Bool = false, quotaBlock: NativeQuotaBlock? = nil,
                startedAt: Date? = nil, reportedAt: Double? = nil, activeTasks: [NativeRuntimeTask]? = [], watchReopen: Bool = false,
                hostWorkInventory: NativeHostWorkInventory? = nil) throws {
        let file = directory.appending(path: "runtimes/\(session)/runtime-\(pid).json")
        let previous = try? JSONDecoder().decode(NativeRuntimeReport.self, from: AtomicFile.read(file))
        let procStart = startedAt.map(TaskGuardEvaluator.registryStartTime) ?? previous?.procStart
            ?? TaskGuardEvaluator.registryStartTime(harness.clock.now())
        var report = NativeRuntimeReport(sessionID: session, instanceID: "runtime-\(pid)", pid: pid,
            procStart: procStart, reportedAt: reportedAt ?? harness.clock.now().timeIntervalSince1970 * 1000,
            busy: busy, userStopped: userStopped, activeTasks: activeTasks, quotaBlock: quotaBlock, hostWorkInventory: hostWorkInventory)
        if watchReopen { report.capabilities.append(NativeRecoveryCoordinator.watchReopenCapability) }
        try AtomicFile.write(JSONEncoder().encode(report), to: directory.appending(path: "runtimes/\(session)/runtime-\(pid).json"))
    }
    func focus(_ profile: ProfileSnapshot) throws {
        let file = try sessionFile(profile)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        object["lastFocusedAt"] = Int(harness.clock.now().timeIntervalSince1970 * 1000) + 1
        try AtomicFile.write(JSONSerialization.data(withJSONObject: object), to: file)
    }
    func installNativeWork() throws {
        let cli = try XCTUnwrap(harness.world.cliSessions.first { $0.cliSessionID == session })
        let rows: [[String: Any]] = [
            ["uuid": "native-user", "parentUuid": NSNull(), "type": "user", "origin": ["kind": "human"], "message": ["content": "Continue the original work"]],
            ["uuid": "native-calls", "parentUuid": "native-user", "type": "assistant", "message": ["stop_reason": "tool_use", "content": [
                ["type": "tool_use", "id": "native-bash", "name": "Bash", "input": ["command": "DO_NOT_RUN", "run_in_background": true]],
                ["type": "tool_use", "id": "native-monitor", "name": "Monitor", "input": ["command": "DO_NOT_RUN"]],
            ]]],
            ["uuid": "native-bash-result", "parentUuid": "native-calls", "type": "user", "toolUseResult": ["backgroundTaskId": "native-bash-task"],
             "message": ["content": [["type": "tool_result", "tool_use_id": "native-bash", "content": "registered"]]]],
            ["uuid": "native-monitor-result", "parentUuid": "native-bash-result", "type": "user", "toolUseResult": ["taskId": "native-monitor-task"],
             "message": ["content": [["type": "tool_result", "tool_use_id": "native-monitor", "content": "registered"]]]],
            ["uuid": "native-head", "parentUuid": "native-monitor-result", "type": "assistant", "message": ["stop_reason": "end_turn",
                "content": [["type": "text", "text": "Watching the work"]]]],
        ]
        var data = Data()
        for var row in rows {
            row["sessionId"] = session; row["timestamp"] = "2026-10-27T01:00:00Z"
            data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10)
        }
        try AtomicFile.write(data, to: cli.transcriptFile)
        let source = try harness.profile("Claude"), file = try sessionFile(source)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        record["lastAssistantUuid"] = "native-head"
        try AtomicFile.write(JSONSerialization.data(withJSONObject: record), to: file)
    }

    /// A conversation whose last turn ended as it should, with nothing left running.
    func installFinishedTurn() throws {
        let cli = try XCTUnwrap(harness.world.cliSessions.first { $0.cliSessionID == session })
        let rows: [[String: Any]] = [
            ["uuid": "done-user", "parentUuid": NSNull(), "type": "user", "origin": ["kind": "human"], "message": ["content": "Sum up the notes"]],
            ["uuid": "done-head", "parentUuid": "done-user", "type": "assistant", "message": ["stop_reason": "end_turn",
                "content": [["type": "text", "text": "Here is the summary"]]]],
        ]
        var data = Data()
        for var row in rows {
            row["sessionId"] = session; row["timestamp"] = "2026-10-27T01:00:00Z"
            data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10)
        }
        try AtomicFile.write(data, to: cli.transcriptFile)
        let file = try sessionFile(harness.profile("Claude"))
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        record["lastAssistantUuid"] = "done-head"
        try AtomicFile.write(JSONSerialization.data(withJSONObject: record), to: file)
    }

    /// A finished conversation that only watches an Artifact's comments.
    func installWatchOnly(title: String) throws {
        let cli = try XCTUnwrap(harness.world.cliSessions.first { $0.cliSessionID == session })
        let rows: [[String: Any]] = [
            ["uuid": "watch-user", "parentUuid": NSNull(), "type": "user", "origin": ["kind": "human"], "message": ["content": "Watch the page"]],
            ["uuid": "watch-head", "parentUuid": "watch-user", "type": "assistant", "message": ["stop_reason": "end_turn",
                "content": [["type": "text", "text": "Watching the comments"]]]],
            ["type": "artifact-comment-monitor", "v": 1, "artifacts": ["artifact-1": ["state": "armed", "writtenAtMs": 1]]],
        ]
        var data = Data()
        for var row in rows {
            row["sessionId"] = session; row["timestamp"] = "2026-10-27T01:00:00Z"
            data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10)
        }
        try AtomicFile.write(data, to: cli.transcriptFile)
        let file = try sessionFile(harness.profile("Claude"))
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        record["lastAssistantUuid"] = "watch-head"; record["title"] = title
        try AtomicFile.write(JSONSerialization.data(withJSONObject: record), to: file)
    }
    func record(_ profile: ProfileSnapshot) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(sessionFile(profile))) as? [String: Any])
    }
    var watchReopenNote: URL { directory.appending(path: "watch-reopen/\(session).json") }

    func installRateLimitedTurn() throws {
        let cli = try XCTUnwrap(harness.world.cliSessions.first { $0.cliSessionID == session })
        let rows: [[String: Any]] = [
            ["uuid": "limited-user", "parentUuid": NSNull(), "type": "user", "message": ["content": "Finish the original task"]],
            ["uuid": "limited-head", "parentUuid": "limited-user", "type": "assistant", "isApiErrorMessage": true,
             "error": "rate_limit", "message": ["content": [["type": "text", "text": "You've hit your limit"]]]],
        ]
        var data = Data()
        for var row in rows {
            row["sessionId"] = session
            data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10)
        }
        try AtomicFile.write(data, to: cli.transcriptFile)
        let file = try sessionFile(harness.profile("Claude"))
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        record["lastAssistantUuid"] = "limited-head"
        try AtomicFile.write(JSONSerialization.data(withJSONObject: record), to: file)
    }
}

private actor NativeSwitchRuntimeFixture: NativeRuntimeInspecting {
    private var values: [String: [NativeProcessSession]] = [:]
    private var identities: [Int32: (String, AccountIdentity)] = [:]
    private var pausedProfile: String?
    private var sessionsContinuation: CheckedContinuation<Void, Never>?
    private(set) var sessionReads = 0
    var sessionsPaused: Bool { sessionsContinuation != nil }
    func pauseNextSessions(profile: URL) { pausedProfile = profile.path }
    func resumeSessions() {
        pausedProfile = nil
        sessionsContinuation?.resume()
        sessionsContinuation = nil
    }
    func set(profile: ProfileSnapshot, pid: Int32, startedAt: Date, busy: Bool) {
        values[profile.url.path] = [NativeProcessSession(sessionID: SandboxFixture.ID.liveSession, pid: pid, startedAt: startedAt, busy: busy)]
        if let identity = profile.identity { identities[pid] = (profile.url.path, identity) }
    }
    func reject(pid: Int32) { identities[pid] = nil }
    func clear(profile: URL) { values[profile.path] = [] }
    func sessions(profile: URL) async -> [NativeProcessSession] {
        sessionReads += 1
        if pausedProfile == profile.path {
            pausedProfile = nil
            await withCheckedContinuation { sessionsContinuation = $0 }
        }
        return values[profile.path] ?? []
    }
    func validate(_ report: NativeRuntimeReport, profile: URL, account: AccountIdentity) -> Bool {
        guard let (path, identity) = identities[report.pid] else { return false }
        return path == profile.path && identity.accountUUID == account.accountUUID &&
            identity.activeOrganizationUUID == account.activeOrganizationUUID &&
            values[path]?.contains(where: { $0.pid == report.pid && $0.sessionID == report.sessionID }) == true
    }
}

private actor NativeSwitchObservations {
    private var recorded: [String] = []
    func record(_ event: String) { recorded.append(event) }
    func events() -> [String] { recorded }
}

private enum NativeSwitchFixtureError: Error { case missing }

private actor NativeSwitchRequestLease {
    private var lease: CompanionFileLease?
    func hold(_ file: URL) throws { lease = try CompanionFileLease(file: file) }
    func release() { lease?.release(); lease = nil }
}
