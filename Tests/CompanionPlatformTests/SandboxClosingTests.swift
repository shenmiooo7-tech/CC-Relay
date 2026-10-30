import CompanionCore
import Darwin
import Foundation
import XCTest
@testable import CompanionPlatform

/// Scales elapsed time and sleeps equally, preserving the production phase budgets
/// while retaining real scheduling headroom for stand-ins on a busy machine.
struct AcceleratedSandboxClock: CompanionCore.Clock {
    private let origin = Date()
    private let factor = 2.0

    func now() -> Date { origin.addingTimeInterval(Date().timeIntervalSince(origin) * factor) }
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(duration.timeInterval / factor))
    }
}

@MainActor
final class SandboxClosingTests: XCTestCase {
    func testHelperAndGrandchildExitWithTheirMainAndAreNotRunningInstances() async throws {
        let fixture = try SandboxClosingFixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller(environment: ["FAKE_CLAUDE_SPAWN_CHILD": "1", "FAKE_CLAUDE_KEEP_GRANDCHILD": "1"])
        let profile = fixture.profile("family")
        let main = try await controller.launch(profile: profile, deepLink: nil)
        let child = try fixture.helper(profile, role: "child")
        let grandchild = try fixture.helper(profile, role: "grandchild")
        let instances = try await controller.runningInstances()
        XCTAssertEqual(instances.map(\.pid), [main.pid])
        let outcome = try await controller.quitAll(timeout: .seconds(90))
        XCTAssertEqual(outcome, .quitAfterSignal)
        XCTAssertNil(ProcessTable().closingProcess(pid: main.pid))
        XCTAssertNil(ProcessTable().closingProcess(pid: child.pid))
        XCTAssertNil(ProcessTable().closingProcess(pid: grandchild.pid))
    }

    func testHelpersThatOutliveTheirMainStillCountAsClaudeRunning() async throws {
        let fixture = try SandboxClosingFixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller(environment: fixture.orphanEnvironment, clock: AcceleratedSandboxClock())
        let profile = fixture.profile("crashed")
        let main = try await controller.launch(profile: profile, deepLink: nil)
        let child = try fixture.helper(profile, role: "child")
        let grandchild = try fixture.helper(profile, role: "grandchild")
        _ = Darwin.kill(main.pid, SIGKILL)
        var mainGone = false
        for _ in 0..<200 where !mainGone {
            mainGone = try await controller.runningInstances().isEmpty
            if !mainGone { try await Task.sleep(for: .milliseconds(25)) }
        }
        XCTAssertTrue(mainGone)
        let leftovers = try await controller.hasAnyProcess()
        XCTAssertTrue(leftovers)
        _ = try await controller.quitAll(timeout: .seconds(90))
        let afterClose = try await controller.hasAnyProcess()
        XCTAssertFalse(afterClose)
        for pid in [child.pid, grandchild.pid] { XCTAssertNil(ProcessTable().closingProcess(pid: pid)) }
    }

    func testOrphanedHelpersAreForcedOnlyAfterNormalWaitAndTermGrace() async throws {
        let fixture = try SandboxClosingFixture()
        defer { fixture.cleanup() }
        let clock = AcceleratedSandboxClock()
        var environment = fixture.orphanEnvironment
        environment["FAKE_CLAUDE_QUIT_DELAY_MS"] = "1000"
        let controller = fixture.controller(environment: environment, clock: clock)
        let profile = fixture.profile("orphans")
        let main = try await controller.launch(profile: profile, deepLink: nil)
        let child = try fixture.helper(profile, role: "child")
        let grandchild = try fixture.helper(profile, role: "grandchild")
        let started = clock.now()
        let gate = ForceObservation()
        let outcome = try await controller.quitAll(timeout: .seconds(90), beforeForce: {
            gate.record(elapsed: clock.now().timeIntervalSince(started),
                        pids: [child.pid, grandchild.pid].filter { ProcessTable().closingProcess(pid: $0) != nil })
            return true
        })
        XCTAssertEqual(outcome, .quitAfterForce)
        XCTAssertEqual(gate.pids, [child.pid, grandchild.pid])
        XCTAssertGreaterThanOrEqual(gate.elapsed, 7)
        XCTAssertLessThan(gate.elapsed, 20)
        for pid in [main.pid, child.pid, grandchild.pid] { XCTAssertNil(ProcessTable().closingProcess(pid: pid)) }
    }

    func testACloseThePersonConfirmedForcesAtOnceWithoutAskingClaudeToQuit() async throws {
        let fixture = try SandboxClosingFixture()
        defer { fixture.cleanup() }
        let clock = AcceleratedSandboxClock()
        // A main that does not quit when asked, as Claude while its own confirmation is open.
        let stubborn = ["FAKE_CLAUDE_IGNORE_TERM": "1", "FAKE_CLAUDE_SPAWN_CHILD": "1", "FAKE_CLAUDE_KEEP_GRANDCHILD": "1"]
        let controller = fixture.controller(environment: stubborn, clock: clock)
        let profile = fixture.profile("confirmed")
        let main = try await controller.launch(profile: profile, deepLink: nil)
        let child = try fixture.helper(profile, role: "child")
        let grandchild = try fixture.helper(profile, role: "grandchild")
        let started = clock.now()
        let gate = ForceObservation()
        let outcome = try await controller.quitAll(timeout: .seconds(90), immediately: true, beforeForce: {
            gate.record(elapsed: clock.now().timeIntervalSince(started),
                        pids: [main.pid, child.pid, grandchild.pid].filter { ProcessTable().closingProcess(pid: $0) != nil })
            return true
        })
        XCTAssertEqual(outcome, .quitAfterForce)
        // Nothing waited on Claude's own quit: all of it was still running when the force began.
        XCTAssertEqual(gate.pids, [main.pid, child.pid, grandchild.pid])
        XCTAssertLessThan(gate.elapsed, 2)
        for pid in [main.pid, child.pid, grandchild.pid] { XCTAssertNil(ProcessTable().closingProcess(pid: pid)) }

        // A refusal before the force still forces nothing.
        let other = fixture.profile("refused-at-once")
        let kept = try await controller.launch(profile: other, deepLink: nil)
        do {
            _ = try await controller.quitAll(timeout: .seconds(90), immediately: true, beforeForce: { false })
            XCTFail("Force refusal must fail the close")
        } catch {
            guard case .stillRunning(_, _, _, let stall) = error as? ClaudeProcessError else { return XCTFail("\(error)") }
            XCTAssertEqual(stall, .notForced)
        }
        XCTAssertEqual(ProcessTable().closingProcess(pid: kept.pid)?.identity.pid, kept.pid)
    }

    func testRefusedForceLeavesOrphansAndReportsOnlyCleanlyClosedProfile() async throws {
        let fixture = try SandboxClosingFixture()
        defer { fixture.cleanup() }
        let clean = fixture.controller()
        let stubborn = fixture.controller(environment: fixture.orphanEnvironment)
        let cleanProfile = fixture.profile("clean")
        let orphanProfile = fixture.profile("orphan")
        let cleanMain = try await clean.launch(profile: cleanProfile, deepLink: nil)
        let orphanMain = try await stubborn.launch(profile: orphanProfile, deepLink: nil)
        let child = try fixture.helper(orphanProfile, role: "child")
        let grandchild = try fixture.helper(orphanProfile, role: "grandchild")
        do {
            _ = try await stubborn.quitAll(timeout: .seconds(90), beforeForce: { false })
            XCTFail("Force refusal must fail the close")
        } catch {
            XCTAssertEqual(error as? ClaudeProcessError,
                .stillRunning(pids: [child.pid, grandchild.pid].sorted(), closedProfiles: [ProfilePaths.canonical(cleanProfile)],
                              names: ["FakeClaudeHelper"], stall: .notForced))
        }
        XCTAssertNil(ProcessTable().closingProcess(pid: cleanMain.pid))
        XCTAssertNil(ProcessTable().closingProcess(pid: orphanMain.pid))
        XCTAssertEqual(ProcessTable().closingProcess(pid: child.pid)?.identity, child)
        XCTAssertEqual(ProcessTable().closingProcess(pid: grandchild.pid)?.identity, grandchild)
        let mains = try await stubborn.runningInstances()
        XCTAssertTrue(mains.isEmpty)
    }

    func testSecondMainLaunchedDuringCloseIsLeftRunningAndReported() async throws {
        let fixture = try SandboxClosingFixture()
        defer { fixture.cleanup() }
        let closing = fixture.controller(environment: ["FAKE_CLAUDE_IGNORE_TERM": "1"])
        let other = fixture.controller()
        let original = try await closing.launch(profile: fixture.profile("original"), deepLink: nil)
        let task = Task { () -> ClaudeProcessError? in
            do { _ = try await closing.quitAll(timeout: .seconds(90)); return nil }
            catch { return error as? ClaudeProcessError }
        }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        let reopened = try await other.launch(profile: fixture.profile("reopened"), deepLink: nil)
        let error = await task.value
        XCTAssertEqual(error, .stillRunning(pids: [original.pid, reopened.pid].sorted(), closedProfiles: [], names: ["FakeClaude"],
                                            stall: .reopened))
        XCTAssertNotNil(ProcessTable().closingProcess(pid: original.pid))
        XCTAssertNotNil(ProcessTable().closingProcess(pid: reopened.pid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.profile("reopened").appending(path: ".fake-claude/events.log").path))
    }

    func testNewMainWhileAwaitingForcePermissionIsNotTouched() async throws {
        let fixture = try SandboxClosingFixture()
        defer { fixture.cleanup() }
        let closing = fixture.controller(environment: fixture.orphanEnvironment)
        let other = fixture.controller()
        let profile = fixture.profile("original")
        _ = try await closing.launch(profile: profile, deepLink: nil)
        let child = try fixture.helper(profile, role: "child")
        let grandchild = try fixture.helper(profile, role: "grandchild")
        let newProfile = fixture.profile("reopened")
        let holder = ReopenedInstance()
        do {
            _ = try await closing.quitAll(timeout: .seconds(90), beforeForce: {
                let instance = try? await other.launch(profile: newProfile, deepLink: nil)
                await holder.set(instance)
                return true
            })
            XCTFail("A reopened main must stop the close")
        } catch {
            let reopened = await holder.value
            let instance = try XCTUnwrap(reopened)
            XCTAssertEqual(error as? ClaudeProcessError,
                           .stillRunning(pids: [child.pid, grandchild.pid, instance.pid].sorted(), closedProfiles: [],
                                         names: ["FakeClaude", "FakeClaudeHelper"], stall: .reopened))
            XCTAssertNotNil(ProcessTable().closingProcess(pid: instance.pid))
        }
        XCTAssertEqual(ProcessTable().closingProcess(pid: child.pid)?.identity, child)
        XCTAssertEqual(ProcessTable().closingProcess(pid: grandchild.pid)?.identity, grandchild)
    }

    func testExhaustedNonzeroBudgetNeverSkipsAheadToForce() async throws {
        let fixture = try SandboxClosingFixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller(environment: ["FAKE_CLAUDE_IGNORE_TERM": "1"])
        let instance = try await controller.launch(profile: fixture.profile("budget"), deepLink: nil)
        do {
            _ = try await controller.quitAll(timeout: .seconds(1), beforeForce: { XCTFail("Budget cannot reach force"); return true })
            XCTFail("Expected exhausted budget")
        } catch { XCTAssertEqual(error as? ClaudeProcessError, .stillRunning(pids: [instance.pid], names: ["FakeClaude"], stall: .outOfTime)) }
        XCTAssertNotNil(ProcessTable().closingProcess(pid: instance.pid))
    }

    func testHelperOnlySnapshotCanBeClosedAfterAnEarlierRefusal() async throws {
        let fixture = try SandboxClosingFixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller(environment: fixture.orphanEnvironment)
        let profile = fixture.profile("refused")
        let instance = try await controller.launch(profile: profile, deepLink: nil)
        let child = try fixture.helper(profile, role: "child")
        let grandchild = try fixture.helper(profile, role: "grandchild")
        do { _ = try await controller.quitAll(timeout: .seconds(90), beforeForce: { false }); XCTFail() }
        catch {
            XCTAssertEqual(error as? ClaudeProcessError,
                           .stillRunning(pids: [child.pid, grandchild.pid].sorted(), names: ["FakeClaudeHelper"], stall: .notForced))
        }
        XCTAssertNil(ProcessTable().closingProcess(pid: instance.pid))
        let outcome = try await controller.quitAll(timeout: .seconds(90))
        XCTAssertEqual(outcome, .quitAfterForce)
        XCTAssertNil(ProcessTable().closingProcess(pid: child.pid))
        XCTAssertNil(ProcessTable().closingProcess(pid: grandchild.pid))
    }
}

@MainActor
private final class SandboxClosingFixture {
    let directory: PlatformTestDirectory
    let executable: URL
    var orphanEnvironment: [String: String] {
        ["FAKE_CLAUDE_SPAWN_CHILD": "1", "FAKE_CLAUDE_KEEP_GRANDCHILD": "1",
         "FAKE_CLAUDE_ORPHAN_CHILD": "1", "FAKE_CLAUDE_CHILD_IGNORE_TERM": "1"]
    }

    init() throws {
        directory = try PlatformTestDirectory()
        let folder = directory.root.appending(path: "application with spaces", directoryHint: .isDirectory)
        executable = folder.appending(path: "FakeClaude")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let products = Bundle(for: SandboxClosingTests.self).bundleURL.deletingLastPathComponent()
            try FileManager.default.copyItem(at: products.appending(path: "FakeClaude"), to: executable)
        } catch { directory.remove(); throw error }
    }

    func profile(_ name: String) -> URL { directory.root.appending(path: name, directoryHint: .isDirectory) }

    func controller(environment: [String: String] = [:], clock: any CompanionCore.Clock = AcceleratedSandboxClock()) -> SandboxClaudeProcessController {
        SandboxClaudeProcessController(root: directory.root, fakeClaudeExecutable: executable, environment: environment, clock: clock, verificationTimeout: .seconds(90))
    }

    func helper(_ profile: URL, role: String) throws -> ClosingIdentity {
        struct Ready: Decodable { let pid: Int32 }
        let data = try Data(contentsOf: profile.appending(path: ".fake-claude/\(role).json"))
        let pid = try JSONDecoder().decode(Ready.self, from: data).pid
        let entry = try XCTUnwrap(ProcessTable().closingProcess(pid: pid))
        XCTAssertEqual(entry.identity.executable.lastPathComponent, "FakeClaudeHelper")
        XCTAssertTrue(entry.identity.executable.path.hasPrefix(directory.root.resolvingSymlinksInPath().path + "/"))
        return entry.identity
    }

    func cleanup() {
        FakeClaudeTestCleanup(root: directory.root).stop()
        directory.remove()
    }
}

private final class ForceObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var observed: (Double, [Int32]) = (0, [])
    var elapsed: Double { lock.withLock { observed.0 } }
    var pids: [Int32] { lock.withLock { observed.1 } }
    func record(elapsed: Double, pids: [Int32]) { lock.withLock { observed = (elapsed, pids) } }
}

private actor ReopenedInstance {
    var value: ClaudeInstance?
    func set(_ value: ClaudeInstance?) { self.value = value }
}
