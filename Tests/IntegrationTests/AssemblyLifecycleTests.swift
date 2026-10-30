import CompanionCore
import CompanionPlatform
import Foundation
import XCTest
@testable import CCRelay

@MainActor
final class AssemblyLifecycleTests: XCTestCase {
    func testLiveAssemblyRefusesTestRunnerBeforeReadingAnyPaths() throws {
        let paths = AppPaths.sandbox(root: URL(fileURLWithPath: "/unused-test-root"))
        XCTAssertThrowsError(try AppServices.live(paths: paths))
    }

    func testSingleInstancePolicyExitsOnlyForAnotherPID() {
        expectFalse(AppLaunchPolicy.shouldExit(currentPID: 10, runningPIDs: []))
        expectFalse(AppLaunchPolicy.shouldExit(currentPID: 10, runningPIDs: [10]))
        expectTrue(AppLaunchPolicy.shouldExit(currentPID: 10, runningPIDs: [10, 11]))
    }

    func testTerminationRepliesAfterEngineFinishesForEitherQuitEntryPoint() {
        var systemQuit = AppTerminationState()
        expectEqual(systemQuit.request(), .begin)
        expectEqual(systemQuit.request(), .waiting)
        expectTrue(systemQuit.finish())
        expectEqual(systemQuit.request(), .finished)
        var panelQuit = AppTerminationState()
        expectFalse(panelQuit.finish())
        expectEqual(panelQuit.request(), .finished)
    }

    func testConcurrentQuitHonoursDebtOnceAndCallsHostOnce() async throws {
        let counter = QuitCounter()
        let h = try IntegrationHarness(onQuit: { await counter.increment() })
        addTeardownBlock { await h.cleanup() }
        try await h.start(launch: nil)
        let log = CompanionLog(paths: h.world.paths, clock: h.clock)
        let store = StateStore(paths: h.world.paths, log: log, clock: h.clock)
        let folder = try h.folder("Claude_204")
        try await store.update { @Sendable state in state.relaunchDebt = [folder] }
        async let first: Void = h.engine.perform(.quitApp)
        async let second: Void = h.engine.perform(.quitApp)
        _ = await (first, second)
        expectEqual(await counter.count, 1)
        expectTrue(try h.state().relaunchDebt.isEmpty)
        expectEqual(try await h.services.processes.runningInstances().map { $0.profileDirectory.lastPathComponent }, ["Claude_204"])
        await h.engine.perform(.quitApp)
        expectEqual(await counter.count, 1)
    }

    func testStartupRecoversPersistedDebtBeforeNormalScanning() async throws {
        let h = try IntegrationHarness()
        addTeardownBlock { await h.cleanup() }
        let log = CompanionLog(paths: h.world.paths, clock: h.clock)
        let store = StateStore(paths: h.world.paths, log: log, clock: h.clock)
        let target = try h.folder("Claude_204")
        let accounts = [ManagedAccount(folder: target, displayName: "Recovered", addedAt: h.clock.now())]
        try await store.update { @Sendable state in
            state.accounts = accounts
            state.activeFolder = target
            state.relaunchDebt = [target]
        }
        await h.engine.start()
        expectEqual((await h.snapshot()).currentFolder, target)
        expectTrue(try h.state().relaunchDebt.isEmpty)
        expectEqual(try await h.services.processes.runningInstances().map { $0.profileDirectory.lastPathComponent }, [target.name])
    }

    func testFixtureEncryptionRoundTripsLegacyAndHostBoundCookies() async throws {
        let decryptor = ChromiumCookieDecryptor()
        for version in [0, 24] {
            let blob = try ChromiumCookieEncryptor.encrypt("sandbox-Claude", version: version)
            let cookie = EncryptedCookie(hostKey: ".claude.ai", encryptedValue: blob, databaseVersion: version)
            expectEqual(try await decryptor.open(cookie, password: ChromiumCookieEncryptor.fixturePassword), "sandbox-Claude")
        }
        let wrongHost = EncryptedCookie(hostKey: "claude.ai", encryptedValue: try ChromiumCookieEncryptor.encrypt("sandbox-Claude"), databaseVersion: 24)
        do { _ = try await decryptor.open(wrongHost, password: nil); XCTFail("Expected host binding refusal") }
        catch { expectEqual(error as? CookieDecryptError, .wrongHostHash) }
    }

    func testGeneratorPreservesExistingDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cc-relay-nonempty-\(UUID().uuidString)")
        let sentinel = root.appendingPathComponent("keep.json")
        try AtomicFile.write(Data("keep".utf8), to: sentinel)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try SandboxWorldGenerator.generate(at: root, fakeClaude: root.appendingPathComponent("missing")))
        expectEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testEngineUsesInjectedLogClockAndRotation() async throws {
        let h = try IntegrationHarness()
        addTeardownBlock { await h.cleanup() }
        try await h.start(launch: nil)
        let log = CompanionLog(paths: h.world.paths, clock: LogFixtureClock(), rotationThreshold: 1)
        let engine = CompanionEngine(paths: h.world.paths, processes: h.services.processes,
            tasks: SandboxTaskInspector(root: h.root),
            cookies: SandboxSessionCookieReader(root: h.root), quota: h.services.quota, accountDetails: h.services.quota,
            loginItems: SandboxLoginItem(root: h.root), fileRevealer: SandboxFileRevealer(root: h.root),
            executable: h.root.appendingPathComponent("CCRelay"), clock: h.clock, automaticallyPoll: false, log: log)
        addTeardownBlock { await engine.stop() }
        await engine.start()
        log.info(.app, "Before the engine action.")
        await engine.perform(.rename(folder: try h.folder("Claude"), name: ""))
        log.info(.quota, "After the engine action.")
        let file = h.world.paths.companionDataDirectory.appendingPathComponent("Logs/cc-relay.log")
        let engineLine = try String(contentsOf: file.appendingPathExtension("1"), encoding: .utf8)
        expectTrue(engineLine.hasPrefix("2001-01-01T00:00:00.000Z"))
        expectTrue(engineLine.contains("Rejected an invalid account rename."))
        expectTrue(try String(contentsOf: file.appendingPathExtension("2"), encoding: .utf8).contains("Before the engine action."))
    }
}

private struct LogFixtureClock: CompanionCore.Clock {
    func now() -> Date { Date(timeIntervalSince1970: 978_307_200) }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

private actor QuitCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
