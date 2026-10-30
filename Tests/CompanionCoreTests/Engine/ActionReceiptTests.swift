import Foundation
import XCTest
@testable import CompanionCore

@MainActor
final class ActionReceiptTests: XCTestCase {
    func testViewingFoldersDoesNotStartPendingHistoryOrAccountWork() async throws {
        for started in [false, true] {
            let h = try await EngineHarness()
            if started { await h.start() }
            let target = try h.profile("Claude_Kxm8"), source = try h.profile("Claude")
            let identity = try XCTUnwrap(source.identity)
            let job = HistoryJob(target: target.folder, targetAccountUUID: target.identity?.accountUUID,
                targetOrganizationUUID: target.identity?.activeOrganizationUUID,
                donors: [HistoryDonor(folder: source.folder, accountUUID: identity.accountUUID,
                    organizationUUID: try XCTUnwrap(identity.activeOrganizationUUID))], createdAt: h.clock.now())
            try await h.store.update { @Sendable state in state.historyJobs = [job] }
            let before = try await h.store.load()
            let copies = try h.sessionFile(target, id: "local_" + SandboxFixture.ID.liveSession)
            XCTAssertFalse(FileManager.default.fileExists(atPath: copies.path))
            for action in [CompanionAction.openRecoveryFolder, .openBackupsFolder] {
                _ = await h.engine.performWithReceipt(action)
                XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
                XCTAssertTrue(h.process.recordedLaunches().isEmpty)
                let after = try await h.store.load()
                XCTAssertEqual(after.historyJobs, before.historyJobs)
                XCTAssertFalse(FileManager.default.fileExists(atPath: copies.path))
            }
            await h.cleanup()
        }
    }

    /// Installing the plugin answers with its own receipt, says whether the plugin is ready now, and leaves
    /// Claude alone.
    func testPluginInstallAnswersWithItsOwnReceiptAndReadiness() async throws {
        let plugin = FakeClaudeCodePlugin(failure: .claudeCodeMissing)
        let h = try await EngineHarness(plugin: plugin)
        addTeardownBlock { await h.cleanup() }
        await h.start()
        let before = await h.engine.currentSnapshot().pluginReady
        XCTAssertEqual(before, false)
        let failed = await h.engine.performWithReceipt(.installPlugin)
        XCTAssertEqual(failed, .pluginNotInstalled(.claudeCodeMissing))
        let stillMissing = await h.engine.currentSnapshot().pluginReady
        XCTAssertEqual(stillMissing, false)
        plugin.letInstallSucceed()
        let installed = await h.engine.performWithReceipt(.installPlugin)
        XCTAssertEqual(installed, .pluginInstalled)
        let ready = await h.engine.currentSnapshot().pluginReady
        XCTAssertEqual(ready, true)
        XCTAssertTrue(h.process.recordedLaunches().isEmpty)
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
    }

    /// After an app update Claude Code still records the older plugin: the engine updates it by itself
    /// once it starts and shows nothing, unless that fails; an install that later succeeds clears it.
    func testAnOutdatedPluginIsUpdatedOnStartAndOnlyAFailureIsShown() async throws {
        for failing in [false, true] {
            let plugin = OutdatedClaudeCodePlugin(failing: failing)
            let h = try await EngineHarness(plugin: plugin)
            await h.start()
            let tried = await eventually { plugin.installs == 1 }
            XCTAssertTrue(tried, "failing: \(failing)")
            let shown = await eventually { await h.engine.currentSnapshot().pluginUpdateFailed == failing }
            XCTAssertTrue(shown, "failing: \(failing)")
            if failing {
                plugin.letInstallSucceed()
                let retried = await h.engine.performWithReceipt(.installPlugin)
                XCTAssertEqual(retried, .pluginInstalled)
                let cleared = await h.engine.currentSnapshot().pluginUpdateFailed
                XCTAssertFalse(cleared)
            }
            XCTAssertEqual(plugin.installs, failing ? 2 : 1, "nothing else updates it")
            XCTAssertTrue(h.process.recordedLaunches().isEmpty)
            XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
            await h.cleanup()
        }
    }

    func testRecoveryFolderReceiptTracksRevealAndDoesNotControlClaude() async throws {
        let h = try await EngineHarness()
        addTeardownBlock { await h.cleanup() }
        await h.start()
        let launches = h.process.recordedLaunches().count
        let success = await h.engine.performWithReceipt(.openRecoveryFolder)
        XCTAssertEqual(success, .recoveryFolderOpened)
        XCTAssertEqual(h.revealer.recordedURLs().last,
                       h.world.paths.companionDataDirectory.appending(path: "NativeRecovery"))
        h.revealer.fail(.failed("fixture reveal failure"))
        let failure = await h.engine.performWithReceipt(.openRecoveryFolder)
        XCTAssertEqual(failure, .failed)
        XCTAssertEqual(h.process.recordedLaunches().count, launches)
        await h.engine.stop()
        let stopped = await h.engine.performWithReceipt(.openRecoveryFolder)
        XCTAssertEqual(stopped, .notPerformed)
        XCTAssertEqual(h.revealer.recordedURLs().count, 2)
    }

    func testRecoveryFolderFailureDoesNotCallTheRevealer() async throws {
        let h = try await EngineHarness()
        addTeardownBlock { await h.cleanup() }
        await h.start()
        let directory = h.world.paths.companionDataDirectory.appending(path: "NativeRecovery")
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try AtomicFile.write(Data("fixture: not a directory".utf8), to: directory)
        let receipt = await h.engine.performWithReceipt(.openRecoveryFolder)
        XCTAssertEqual(receipt, .failed)
        XCTAssertTrue(h.revealer.recordedURLs().isEmpty)
    }

    func testQuotaFailureReachesTheAccountSnapshotAndClearsOnSuccess() async throws {
        let h = try await EngineHarness()
        addTeardownBlock { await h.cleanup() }
        await h.start()
        let folder = try ProfileFolder("Claude")
        await h.quota.push([folder: QuotaReading(freshness: .unavailable, lastError: .timedOut)])
        await h.engine.perform(.refreshQuota(folder: folder))
        let failed = await h.snapshot().accounts.first { $0.folder == folder }
        XCTAssertEqual(failed?.quotaFailure, .timedOut)
        await h.quota.push([folder: QuotaReading(freshness: .fresh)])
        await h.engine.perform(.refreshQuota(folder: folder))
        let succeeded = await h.snapshot().accounts.first { $0.folder == folder }
        XCTAssertNil(succeeded?.quotaFailure)
    }

    func testRefreshCountsOnlySuccessfulRequestedReads() async throws {
        let h = try await EngineHarness()
        addTeardownBlock { await h.cleanup() }
        await h.start()
        let requested = await h.snapshot().accounts.filter { $0.status == .signedIn }.map(\.folder)
        XCTAssertEqual(requested.count, 4)
        let first = try XCTUnwrap(requested.first)
        let foreign = try ProfileFolder("Claude_not_requested")
        await h.quota.setRefreshResults([first: true, foreign: true])
        let partial = await h.engine.performWithReceipt(.refreshQuota(folder: nil))
        XCTAssertEqual(partial, .quotaRefresh(updated: 1, requested: 4))
        await h.quota.setRefreshResults(Dictionary(uniqueKeysWithValues: requested.map { ($0, true) }))
        let success = await h.engine.performWithReceipt(.refreshQuota(folder: nil))
        XCTAssertEqual(success, .quotaRefresh(updated: 4, requested: 4))
    }

    func testOldFreshSnapshotCannotTurnAFailedRefreshIntoSuccess() async throws {
        let h = try await EngineHarness()
        addTeardownBlock { await h.cleanup() }
        await h.start()
        let profile = try h.profile("Claude")
        let identity = try XCTUnwrap(profile.identity)
        let old = QuotaSnapshot(folder: profile.folder, accountUUID: identity.accountUUID,
            organizationUUID: try XCTUnwrap(identity.activeOrganizationUUID),
            fiveHour: QuotaWindow(usedPercent: 20), sevenDay: QuotaWindow(usedPercent: 30), fetchedAt: h.clock.now())
        await h.quota.push([profile.folder: QuotaReading(snapshot: old, freshness: .fresh)])
        await h.quota.setRefreshResults([profile.folder: false])
        let failed = await h.engine.performWithReceipt(.refreshQuota(folder: profile.folder))
        XCTAssertEqual(failed, .quotaRefresh(updated: 0, requested: 1))
    }

    func testNoSignedInAccountsReturnsAnEmptyRefreshReceipt() async throws {
        let h = try await EngineHarness()
        addTeardownBlock { await h.cleanup() }
        await h.start()
        try await h.store.update { @Sendable state in state.accounts = []; state.activeFolder = nil }
        await h.engine.perform(.panelOpened)
        let receipt = await h.engine.performWithReceipt(.refreshQuota(folder: nil))
        XCTAssertEqual(receipt, .quotaRefresh(updated: 0, requested: 0))
    }

    func testBackupsReceiptTracksRevealSuccessAndFailure() async throws {
        let h = try await EngineHarness()
        addTeardownBlock { await h.cleanup() }
        await h.start()
        let success = await h.engine.performWithReceipt(.openBackupsFolder)
        XCTAssertEqual(success, .backupsOpened)
        h.revealer.fail(.failed("fixture reveal failure"))
        let failure = await h.engine.performWithReceipt(.openBackupsFolder)
        XCTAssertEqual(failure, .failed)
        XCTAssertEqual(h.revealer.recordedURLs().count, 2)
    }

    func testBackupsDirectoryFailureNeverCallsTheRevealer() async throws {
        let h = try await EngineHarness()
        addTeardownBlock { await h.cleanup() }
        await h.start()
        let directory = h.world.paths.companionDataDirectory.appending(path: "Backups")
        try AtomicFile.write(Data("blocks directory creation".utf8), to: directory)
        let failure = await h.engine.performWithReceipt(.openBackupsFolder)
        XCTAssertEqual(failure, .failed)
        XCTAssertTrue(h.revealer.recordedURLs().isEmpty)
    }

    func testStoppedEngineDoesNotAcknowledgeUtilityActions() async throws {
        let h = try await EngineHarness()
        addTeardownBlock { await h.cleanup() }
        await h.start()
        await h.engine.stop()
        let backups = await h.engine.performWithReceipt(.openBackupsFolder)
        let quota = await h.engine.performWithReceipt(.refreshQuota(folder: nil))
        XCTAssertEqual(backups, .notPerformed)
        XCTAssertEqual(quota, .notPerformed)
        XCTAssertTrue(h.revealer.recordedURLs().isEmpty)
    }
}

/// Missing until an install is let succeed; until then each install fails with `failure`.
private final class FakeClaudeCodePlugin: ClaudeCodePluginInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var failure: PluginInstallFailure?

    init(failure: PluginInstallFailure) {
        self.failure = failure
    }

    func letInstallSucceed() {
        lock.withLock { failure = nil }
    }

    func isReady() async -> Bool {
        lock.withLock { ready }
    }

    func install() async throws {
        try lock.withLock {
            if let failure { throw failure }
            ready = true
        }
    }
}

/// Installed but older than the app's copy until an install succeeds; while `failing`, each one fails.
private final class OutdatedClaudeCodePlugin: ClaudeCodePluginInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var outdated = true, failing: Bool, count = 0

    init(failing: Bool) { self.failing = failing }

    var installs: Int { lock.withLock { count } }

    func letInstallSucceed() { lock.withLock { failing = false } }

    func isReady() async -> Bool { true }

    func needsUpdate() async -> Bool { lock.withLock { outdated } }

    func install() async throws {
        try lock.withLock {
            count += 1
            if failing { throw PluginInstallFailure.notFinished }
            outdated = false
        }
    }
}
