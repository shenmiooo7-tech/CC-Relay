import Foundation
import XCTest
@testable import CompanionCore

@MainActor
final class HistoryImporterTests: XCTestCase {
    func testLateHelperPreventsHistoryWritesAndLeavesTheJobForExplicitRetry() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        let job = try await enqueue(h)
        let target = try h.profile(job.target.name)
        let copied = try h.sessionFile(target, id: "local_" + SandboxFixture.ID.liveSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
        h.process.onCloseCompleted {
            h.process.setLeftovers(true)
            h.process.setLeftoverUse(profiles: [target.url])
        }
        await h.engine.perform(.setAutoSync(true))
        let state = try await h.store.load()
        XCTAssertEqual(state.historyJobs.first?.issue, .failed)
        XCTAssertEqual(state.historyJobs.first?.paused, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.world.paths.companionDataDirectory.appending(path: "Backups").path))

        h.process.onCloseCompleted {}
        await h.engine.perform(.retryHistoryImport(folder: target.folder))
        let completed = try await h.store.load()
        XCTAssertTrue(completed.historyJobs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        await h.cleanup()
    }

    private func enqueue(_ h: EngineHarness, donors: [ProfileSnapshot]? = nil) async throws -> HistoryJob {
        let target = try h.profile("Claude_Kxm8")
        let pins = (donors ?? h.profiles.filter { $0.folder != target.folder }).compactMap { profile -> HistoryDonor? in
            guard let identity = profile.identity, let org = identity.activeOrganizationUUID else { return nil }
            return HistoryDonor(folder: profile.folder, accountUUID: identity.accountUUID, organizationUUID: org)
        }
        let job = HistoryJob(target: target.folder, targetAccountUUID: target.identity?.accountUUID,
            targetOrganizationUUID: target.identity?.activeOrganizationUUID, donors: pins, createdAt: h.clock.now())
        try await h.store.update { @Sendable state in state.historyJobs.append(job) }
        return job
    }

    func testAllDonorsImportIntoReadableBucketAndAreNotWritten() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        let job = try await enqueue(h)
        let sourceBytes = try h.profiles.filter { $0.folder != job.target }.map { profile in
            try FileManager.default.contentsOfDirectory(at: profile.url.appending(path: try XCTUnwrap(profile.readableBucket).relativePath),
                includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map { ($0, try AtomicFile.read($0)) }
        }.flatMap { $0 }
        h.process.onClose {
            let current = try? await h.store.load()
            XCTAssertEqual(current?.historyJobs.first?.paused, true)
            XCTAssertEqual(current?.historyJobs.first?.issue, .interrupted)
        }
        await h.engine.perform(.setAutoSync(true))
        let state = try await h.store.load()
        XCTAssertTrue(state.historyJobs.isEmpty)
        let target = try h.profile("Claude_Kxm8")
        for id in [SandboxFixture.ID.liveSession, SandboxFixture.ID.session204, SandboxFixture.ID.session203] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: try h.sessionFile(target, id: "local_" + id).path))
        }
        for (file, bytes) in sourceBytes { XCTAssertEqual(try AtomicFile.read(file), bytes) }
        await h.cleanup()
    }

    func testPartialDonorsRemainPausedAndOnlyExplicitRetryRuns() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        _ = try await enqueue(h)
        let sourceConfig = h.world.profileDirectory("Claude_204").appending(path: "config.json")
        let original = try AtomicFile.read(sourceConfig)
        try AtomicFile.write(Data("{}".utf8), to: sourceConfig)
        await h.engine.perform(.setAutoSync(true))
        var state = try await h.store.load()
        XCTAssertEqual(state.historyJobs.first?.issue, .unavailable)
        XCTAssertEqual(state.historyJobs.first?.paused, true)
        let target = try h.profile("Claude_Kxm8")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try h.sessionFile(target, id: "local_" + SandboxFixture.ID.liveSession).path))
        let quits = h.process.recordedQuitTimeouts().count
        try AtomicFile.write(original, to: sourceConfig)
        await h.engine.perform(.panelOpened)
        await h.engine.checkPendingSignIns()
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, quits)
        await h.engine.perform(.retryHistoryImport(folder: target.folder))
        state = try await h.store.load()
        XCTAssertTrue(state.historyJobs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try h.sessionFile(target, id: "local_" + SandboxFixture.ID.session204).path))
        await h.cleanup()
    }

    func testBackupFailureKeepsPausedAndIncludesDesktopConfigurationInBackup() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        let job = try await enqueue(h)
        let target = try h.profile(job.target.name)
        let config = target.url.appending(path: CodePreferenceInheritance.fileName)
        let original = Data("{\"keep\":42}".utf8)
        try AtomicFile.write(original, to: config)
        let backupRoot = h.world.paths.companionDataDirectory.appending(path: "Backups")
        try AtomicFile.write(Data("blocked".utf8), to: backupRoot)
        await h.engine.perform(.setAutoSync(true))
        let failed = try await h.store.load()
        XCTAssertEqual(failed.historyJobs.first?.issue, .failed)
        XCTAssertEqual(failed.historyJobs.first?.paused, true)
        try FileManager.default.removeItem(at: backupRoot)
        await h.engine.perform(.retryHistoryImport(folder: job.target))
        let directory = backupRoot.appending(path: job.target.name)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(try AtomicFile.read(XCTUnwrap(backups.first).appending(path: CodePreferenceInheritance.fileName)), original)
        await h.cleanup()
    }

    func testAnOlderOwedProfileThatStillFailsToReopenDoesNotFailTheImport() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        _ = try await enqueue(h)
        // Owed by an earlier operation and still failing to open: not this import's to report.
        let earlier = try h.folder("Claude_Kxm2")
        try await h.store.update { @Sendable state in state.relaunchDebt = [earlier] }
        let stuck = h.world.profileDirectory("Claude_Kxm2")
        h.process.onLaunch { profile, _ in
            if ProfilePaths.same(profile, stuck) { throw FakeScriptError.failed("earlier") }
        }
        await h.engine.perform(.setAutoSync(true))
        let state = try await h.store.load()
        XCTAssertTrue(state.historyJobs.isEmpty)
        XCTAssertEqual(state.relaunchDebt, [earlier])
        await h.cleanup()
    }

    func testAQuitDuringAnImportOpensWhatItOwesButTheProfileBeingWritten() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        let job = try await enqueue(h)
        let close = HeldClose()
        h.process.onClose { await close.hold() }
        let work = Task { await h.engine.perform(.setAutoSync(true)) }
        let entered = await eventually { await close.entered }
        XCTAssertTrue(entered)
        // The quit's own wait runs out on the test clock while the import is still under way. The
        // account it closed is still open, so only the one it copies into is still owed, unopened.
        await h.engine.perform(.quitApp)
        XCTAssertTrue(h.process.recordedLaunches().isEmpty)
        let state = try await h.store.load()
        XCTAssertEqual(state.relaunchDebt, [job.target])
        await close.release()
        await work.value
        await h.cleanup()
    }

    func testAnImportTargetAFailedCloseLeftClosedOpensAtTheNextPickup() async throws {
        let h = try await EngineHarness(autoSync: false, running: ["Claude", "Claude_Kxm8"])
        await h.start()
        let job = try await enqueue(h)
        // The close stops the target, then fails, and the target does not open again at once.
        h.process.failClose(.stillRunning(pids: [10], closedProfiles: [h.world.profileDirectory("Claude_Kxm8")]))
        h.process.enqueueLaunch(.failure(.failed("reopen")))
        await h.engine.perform(.setAutoSync(true))
        var state = try await h.store.load()
        XCTAssertEqual(state.historyJobs.first?.issue, .failed)
        XCTAssertEqual(state.relaunchDebt, [job.target])
        // The import holds it no longer, so the quit opens it.
        await h.engine.perform(.quitApp)
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, ["Claude_Kxm8", "Claude_Kxm8"])
        state = try await h.store.load()
        XCTAssertTrue(state.relaunchDebt.isEmpty)
        await h.cleanup()
    }

    func testStaleRevisionCannotClearReplacementJob() async throws {
        let h = try await EngineHarness(autoSync: false)
        let old = try await enqueue(h)
        var replacement = old
        replacement.revision += 1
        let current = replacement
        try await h.store.update { @Sendable state in state.historyJobs = [current] }
        let log = CompanionLog(paths: h.world.paths, clock: h.clock)
        let debt = RelaunchDebt(store: h.store)
        let lifecycle = ClaudeLifecycle(processes: h.process, tasks: h.inspector, debt: debt, paths: h.world.paths, log: log)
        let importer = HistoryImporter(paths: h.world.paths, store: h.store, lifecycle: lifecycle,
            taskGuard: TaskGuard(inspector: h.inspector, clock: h.clock), clock: h.clock, log: log)
        let changed = try await importer.replace(old, with: nil)
        XCTAssertFalse(changed)
        let state = try await h.store.load()
        XCTAssertEqual(state.historyJobs, [replacement])
        await h.cleanup()
    }
}
