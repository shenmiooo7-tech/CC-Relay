import Foundation
import XCTest
@testable import CompanionCore

@MainActor
final class AccountManagerTests: XCTestCase {
    func testCancellingAddDoesNotArchiveAProfileStillUsedByALateHelper() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        await h.engine.perform(.addAccount)
        let adding = try await h.store.load()
        let pending = try XCTUnwrap(adding.pendingSignIns.first)
        let directory = h.world.profileDirectory(pending.folder.name)
        h.process.onCloseCompleted {
            h.process.setLeftovers(true)
            h.process.setLeftoverUse(profiles: [directory])
        }
        await h.engine.perform(.cancelAddAccount)
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .addAccount, reason: .refusedWhileRunning))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        let state = try await h.store.load()
        XCTAssertTrue(state.pendingSignIns.contains { $0.folder == pending.folder })
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.world.paths.companionDataDirectory.appending(path: "Archive").path))

        // Once the helper is gone, an explicit retry can complete the original cancellation.
        h.process.onCloseCompleted {}
        await h.engine.perform(.cancelAddAccount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let completed = try await h.store.load()
        XCTAssertTrue(completed.pendingSignIns.isEmpty)
        await h.cleanup()
    }

    func testCancellingAddKeepsTheProfileWhenPostCloseProcessInspectionFails() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        await h.engine.perform(.addAccount)
        let adding = try await h.store.load()
        let pending = try XCTUnwrap(adding.pendingSignIns.first)
        let directory = h.world.profileDirectory(pending.folder.name)
        h.process.onCloseCompleted { h.process.failInstances(.failed("unavailable")) }
        await h.engine.perform(.cancelAddAccount)
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .addAccount, reason: .runningStateUnknown))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        let state = try await h.store.load()
        XCTAssertTrue(state.pendingSignIns.contains { $0.folder == pending.folder })
        await h.cleanup()
    }

    func testExplicitAuthenticationRejectionKeepsSignInPending() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        let folder = try h.folder("Claude_204")
        try h.writeSignIn(folder: folder, account: SandboxFixture.ID.account204, org: SandboxFixture.ID.organization204)
        await h.quota.setDetails(.failure(.signedOut))
        await h.quota.push([folder: QuotaReading(freshness: .stale, lastError: .signedOut)])
        await h.engine.perform(.panelOpened)
        await h.engine.perform(.switchTo(folder: folder))
        await h.engine.checkPendingSignIns()
        var state = try await h.store.load()
        XCTAssertEqual(state.pendingSignIns.map(\.folder), [folder])
        let rejected = await h.snapshot()
        if case .added = rejected.lastResult?.outcome { XCTFail("Authentication rejection must not complete sign-in") }
        // The cookie turned down is not asked about again; signing in again writes a new one.
        h.cookies.setCookie(EncryptedCookie(hostKey: ".claude.ai", encryptedValue: Data([2]), databaseVersion: 0),
                            for: h.world.profileDirectory(folder.name))
        await h.quota.setDetails(.failure(.accountMismatch))
        await h.engine.checkPendingSignIns()
        let mismatch = await h.snapshot()
        XCTAssertEqual(mismatch.lastResult?.outcome, .failed(operation: .addAccount, reason: .signedInAccountDiffers))
        state = try await h.store.load()
        XCTAssertEqual(state.pendingSignIns.map(\.folder), [folder])
        // A temporary transport failure may still register from local sign-in evidence.
        await h.quota.setDetails(.failure(.transportFailed))
        await h.engine.checkPendingSignIns()
        state = try await h.store.load()
        XCTAssertTrue(state.pendingSignIns.isEmpty)
        await h.cleanup()
    }

    func testFailedCloseDoesNotCreateAProfileOrPendingRecords() async throws {
        let h = try await EngineHarness()
        await h.start()
        let root = h.world.paths.claudeProfilesRoot
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        h.process.failClose(.stillRunning(pids: [10]))
        await h.engine.perform(.addAccount)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), before)
        let state = try await h.store.load()
        XCTAssertTrue(state.pendingSignIns.isEmpty)
        XCTAssertTrue(state.historyJobs.isEmpty)
        XCTAssertTrue(state.relaunchDebt.isEmpty)
        let snapshot = await h.snapshot()
        XCTAssertNil(snapshot.pendingAdd)
        XCTAssertNil(snapshot.operation)
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .addAccount, reason: .couldNotCloseClaude))
        XCTAssertTrue(h.process.recordedLaunches().isEmpty)
        await h.cleanup()
    }

    func testANewAccountThatDoesNotOpenIsSetAsideAndThePreviousOneOpensAgain() async throws {
        let h = try await EngineHarness()
        await h.start()
        let root = h.world.paths.claudeProfilesRoot
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        h.process.onLaunch { profile, _ in
            if !before.contains(profile.lastPathComponent) { throw ClaudeProcessError.launchFailed }
        }
        await h.engine.perform(.addAccount)
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .addAccount, reason: .couldNotOpenClaude))
        XCTAssertNil(snapshot.pendingAdd)
        let state = try await h.store.load()
        XCTAssertTrue(state.pendingSignIns.isEmpty)
        XCTAssertTrue(state.historyJobs.isEmpty)
        XCTAssertTrue(state.relaunchDebt.isEmpty)
        XCTAssertEqual(state.activeFolder?.name, "Claude")
        // The empty folder is archived rather than left behind, and the account it replaced is open again.
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), before)
        let archive = h.world.paths.companionDataDirectory.appending(path: "Archive")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: archive.path).filter { $0.hasPrefix("Claude_") }.count, 1)
        let launches = h.process.recordedLaunches().map { $0.profile.lastPathComponent }
        XCTAssertEqual(launches.count, 2)
        XCTAssertEqual(launches.last, "Claude")
        let running = try await h.process.runningInstances().map { $0.profileDirectory.lastPathComponent }
        XCTAssertEqual(running, ["Claude"])
        await h.cleanup()
    }

    func testANewAccountFolderAHelperStillUsesIsNotMoved() async throws {
        let h = try await EngineHarness()
        await h.start()
        let root = h.world.paths.claudeProfilesRoot
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        // The main instance did not come up, but one of its helpers still has the new folder open.
        h.process.onLaunch { profile, _ in
            if !before.contains(profile.lastPathComponent) {
                h.process.setLeftoverUse(profiles: [profile])
                throw ClaudeProcessError.launchFailed
            }
        }
        await h.engine.perform(.addAccount)
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .addAccount, reason: .couldNotOpenClaude))
        let added = Set(try FileManager.default.contentsOfDirectory(atPath: root.path)).subtracting(before)
        XCTAssertEqual(added.count, 1, "The folder stays where the helper has it")
        let archive = h.world.paths.companionDataDirectory.appending(path: "Archive")
        XCTAssertEqual(((try? FileManager.default.contentsOfDirectory(atPath: archive.path)) ?? []).filter { $0.hasPrefix("Claude_") }, [])
        let state = try await h.store.load()
        XCTAssertEqual(state.pendingSignIns.map(\.folder.name), Array(added))
        await h.cleanup()
    }

    func testANewAccountThatDoesNotOpenStaysWhereTheStateNamesItWhenTheStateCannotBeWritten() async throws {
        let h = try await EngineHarness()
        await h.start()
        let root = h.world.paths.claudeProfilesRoot
        let data = h.world.paths.companionDataDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        try FileManager.default.createDirectory(at: data.appending(path: "Archive"), withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: data.path) }
        h.process.onLaunch { profile, _ in
            guard !before.contains(profile.lastPathComponent) else { return }
            // From here on the state file cannot be written, while the profiles folder and the archive can.
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: data.path)
            throw ClaudeProcessError.launchFailed
        }
        await h.engine.perform(.addAccount)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: data.path)
        let state = try await h.store.load()
        // Every folder the state still names is still there: none is archived from under its records.
        let named = state.pendingSignIns.map(\.folder) + state.relaunchDebt + state.historyJobs.map(\.target)
        XCTAssertFalse(named.isEmpty)
        for folder in named {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: folder.name).path), folder.name)
        }
        await h.cleanup()
    }

    func testANewAccountWhoseClaudeRunsAfterAllIsLeftForTheUserToSignIn() async throws {
        let h = try await EngineHarness()
        await h.start()
        let root = h.world.paths.claudeProfilesRoot
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        // The launch reports a failure, yet its Claude is up.
        h.process.onLaunch { profile, _ in
            guard !before.contains(profile.lastPathComponent) else { return }
            h.process.setInstances([ClaudeInstance(pid: 99, profileDirectory: profile, hasExplicitProfileFlag: true,
                startedAt: Date(), executableURL: profile.appending(path: "FakeClaude"))])
            throw ClaudeProcessError.launchFailed
        }
        await h.engine.perform(.addAccount)
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .addAccount, reason: .couldNotOpenClaude))
        let state = try await h.store.load()
        let folder = try XCTUnwrap(state.pendingSignIns.first?.folder)
        XCTAssertEqual(state.historyJobs.map(\.target), [folder])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: folder.name).path))
        XCTAssertEqual(h.process.recordedLaunches().map { $0.profile.lastPathComponent }, [folder.name])
        await h.cleanup()
    }

    func testAddNamesFromDetailsAndKeepsHistoryIntentWithAutoSyncOff() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        await h.engine.perform(.rename(folder: try h.folder("Claude"), name: "ada"))
        await h.quota.setDetails(.success(AccountRecord(accountUUID: "99999999-9999-4999-8999-999999999999",
            email: "ada@example.com", organizationUUID: "99999999-9999-4999-8999-999999999991", plan: "Pro")))
        await h.engine.perform(.addAccount)
        let pending = try engineUnwrap(await h.snapshot().pendingAdd)
        XCTAssertEqual(pending.folder.name.count, 13)
        XCTAssertEqual(try posixMode(of: h.world.profileDirectory(pending.folder.name)), 0o700)
        var state = try await h.store.load()
        XCTAssertEqual(state.historyJobs.first?.donors.count, 4)
        try h.writeSignIn(folder: pending.folder)
        await h.engine.checkPendingSignIns()
        state = try await h.store.load()
        XCTAssertEqual(state.accounts.last?.displayName, "ada-2")
        XCTAssertEqual(state.accounts.last?.nameIsAutomatic, false)
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.accounts.last?.email, "ada@example.com")
        XCTAssertEqual(snapshot.accounts.last?.plan, "Pro")
        let unknownPlan = QuotaSnapshot(folder: pending.folder, accountUUID: "99999999-9999-4999-8999-999999999999",
            organizationUUID: "99999999-9999-4999-8999-999999999991", fetchedAt: h.clock.now())
        await h.quota.push([pending.folder: QuotaReading(snapshot: unknownPlan, freshness: .fresh)])
        let clearedPlan = await eventually { await h.snapshot().accounts.last?.plan == nil }
        XCTAssertTrue(clearedPlan)
        XCTAssertTrue(state.pendingSignIns.isEmpty)
        XCTAssertEqual(state.historyJobs.first?.paused, false)
        XCTAssertNotNil(state.historyJobs.first?.targetAccountUUID)
        let before = h.process.recordedQuitTimeouts().count
        await h.engine.perform(.setAutoSync(true))
        state = try await h.store.load()
        XCTAssertTrue(state.historyJobs.isEmpty)
        XCTAssertEqual(h.process.recordedQuitTimeouts().count, before + 1)
        let signedIn = try XCTUnwrap(try ProfileScanner(paths: h.world.paths).scan().profiles.first { $0.folder == pending.folder })
        for id in [SandboxFixture.ID.liveSession, SandboxFixture.ID.session204, SandboxFixture.ID.session203, SandboxFixture.ID.session208] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: try h.sessionFile(signedIn, id: "local_" + id).path))
        }
        await h.cleanup()
    }

    func testCodePreferenceIsCapturedAtAddStartAndAppliedOnlyAfterHistoryCopies() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        let source = h.world.profileDirectory("Claude").appending(path: CodePreferenceInheritance.fileName)
        let initial = try JSONSerialization.data(withJSONObject: ["preferences": [
            "bypassPermissionsOptInByAccount": [SandboxFixture.ID.defaultAccount: false]]])
        try AtomicFile.write(initial, to: source)
        await h.engine.perform(.addAccount)
        let folder = try engineUnwrap(await h.snapshot().pendingAdd?.folder)
        let captured = try await h.store.load()
        XCTAssertEqual(captured.historyJobs.first?.codePreference?.bypassOptIn, false)
        try AtomicFile.write(Data("{}".utf8), to: source)
        try h.writeSignIn(folder: folder)
        await h.engine.checkPendingSignIns()
        await h.engine.perform(.setAutoSync(true))
        let target = h.world.profileDirectory(folder.name).appending(path: CodePreferenceInheritance.fileName)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(target)) as? [String: Any])
        let preferences = try XCTUnwrap(object["preferences"] as? [String: Any])
        let choices = try XCTUnwrap(preferences["bypassPermissionsOptInByAccount"] as? [String: Bool])
        XCTAssertEqual(choices["99999999-9999-4999-8999-999999999999"], false)
        await h.cleanup()
    }

    func testPlaceholderAndOneTimeQuotaRenameAndManualRenameWins() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        await h.engine.perform(.setLanguage(.zhHans))
        await h.engine.perform(.addAccount)
        let folder = try engineUnwrap(await h.snapshot().pendingAdd?.folder)
        try h.writeSignIn(folder: folder)
        await h.engine.checkPendingSignIns()
        var state = try await h.store.load()
        XCTAssertEqual(state.accounts.last?.displayName, "新账号")
        XCTAssertEqual(state.accounts.last?.nameIsAutomatic, true)
        let quota = QuotaSnapshot(folder: folder, accountUUID: "99999999-9999-4999-8999-999999999999",
            organizationUUID: "99999999-9999-4999-8999-999999999991", email: "lee@example.com", fetchedAt: h.clock.now())
        await h.quota.push([folder: QuotaReading(snapshot: quota, freshness: .fresh)])
        let renamed = await eventually { await h.snapshot().accounts.last?.displayName == "lee" }
        XCTAssertTrue(renamed)
        var changed = quota
        changed.email = "second@example.com"
        await h.quota.push([folder: QuotaReading(snapshot: changed, freshness: .fresh)])
        await h.engine.perform(.panelOpened)
        state = try await h.store.load()
        XCTAssertEqual(state.accounts.last?.displayName, "lee")
        await h.engine.perform(.rename(folder: folder, name: "  自定义名称  "))
        state = try await h.store.load()
        XCTAssertEqual(state.accounts.last?.displayName, "自定义名称")
        XCTAssertEqual(state.accounts.last?.nameIsAutomatic, false)
        await h.engine.perform(.rename(folder: folder, name: "   "))
        await h.engine.perform(.rename(folder: folder, name: String(repeating: "a", count: 21)))
        state = try await h.store.load()
        XCTAssertEqual(state.accounts.last?.displayName, "自定义名称")
        await h.cleanup()
    }

    func testDuplicateKeepBothAndDiscardArchivesNewFolder() async throws {
        for keep in [true, false] {
            let h = try await EngineHarness(autoSync: false)
            await h.start()
            await h.engine.perform(.addAccount)
            let folder = try engineUnwrap(await h.snapshot().pendingAdd?.folder)
            try h.writeSignIn(folder: folder, account: SandboxFixture.ID.defaultAccount, org: SandboxFixture.ID.defaultOrganization)
            await h.engine.checkPendingSignIns()
            let snapshot = await h.snapshot()
            XCTAssertEqual(snapshot.pendingAdd?.duplicateOf?.name, "Claude")
            await h.engine.perform(.resolveDuplicateAdd(keep ? .keepBoth : .discardNew))
            let state = try await h.store.load()
            XCTAssertEqual(state.accounts.contains { $0.folder == folder }, keep)
            XCTAssertTrue(state.pendingSignIns.isEmpty)
            if !keep {
                XCTAssertFalse(FileManager.default.fileExists(atPath: h.world.profileDirectory(folder.name).path))
                let archive = h.world.paths.companionDataDirectory.appending(path: "Archive")
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: archive.path).count, 1)
                XCTAssertEqual(state.activeFolder?.name, "Claude")
            }
            await h.cleanup()
        }
    }

    func testCancelArchivesAndCookiePlusOrgAreRequired() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        await h.engine.perform(.addAccount)
        let folder = try engineUnwrap(await h.snapshot().pendingAdd?.folder)
        let config = h.world.profileDirectory(folder.name).appending(path: "config.json")
        try AtomicFile.write(Data("{\"lastKnownAccountUuid\":\"test-account\"}".utf8), to: config)
        await h.engine.checkPendingSignIns()
        var state = try await h.store.load()
        XCTAssertEqual(state.pendingSignIns.count, 1)
        try h.writeSignIn(folder: folder)
        h.cookies.setCookie(nil, for: h.world.profileDirectory(folder.name))
        await h.engine.checkPendingSignIns()
        state = try await h.store.load()
        XCTAssertEqual(state.pendingSignIns.count, 1)
        await h.engine.perform(.cancelAddAccount)
        state = try await h.store.load()
        XCTAssertTrue(state.pendingSignIns.isEmpty)
        XCTAssertTrue(state.historyJobs.isEmpty)
        XCTAssertEqual(state.activeFolder?.name, "Claude")
        await h.cleanup()
    }

    func testSignedOutRecoveryRejectsDifferentAccount() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        let folder = try h.folder("Claude_204")
        await h.quota.push([folder: QuotaReading(freshness: .stale, lastError: .signedOut)])
        await h.engine.perform(.panelOpened)
        await h.engine.perform(.switchTo(folder: folder))
        var state = try await h.store.load()
        XCTAssertEqual(state.pendingSignIns.first?.expectAccountUUID, SandboxFixture.ID.account204)
        try h.writeSignIn(folder: folder)
        await h.engine.checkPendingSignIns()
        state = try await h.store.load()
        XCTAssertEqual(state.pendingSignIns.count, 1)
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .addAccount, reason: .signedInAccountDiffers))
        try h.writeSignIn(folder: folder, account: SandboxFixture.ID.account204, org: SandboxFixture.ID.organization204)
        await h.engine.checkPendingSignIns()
        let recovered = try await h.store.load()
        XCTAssertTrue(recovered.pendingSignIns.isEmpty)
        await h.cleanup()
    }

    func testAConfirmedSignInAgainReadsTheQuotaAtOnce() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        let folder = try h.folder("Claude_204")
        await h.quota.push([folder: QuotaReading(freshness: .stale, lastError: .signedOut)])
        await h.engine.perform(.panelOpened)
        await h.engine.perform(.switchTo(folder: folder))
        try h.writeSignIn(folder: folder, account: SandboxFixture.ID.account204, org: SandboxFixture.ID.organization204)
        await h.engine.checkPendingSignIns()
        // The failure behind "sign in again" is moments old: a throttled or cached read would keep it.
        let refreshes = await h.quota.refreshes
        XCTAssertTrue(refreshes.contains { $0.0 == [folder] && $0.1 }, "\(refreshes)")
        await h.cleanup()
    }

    func testASignInAgainIsNotReportedAsAnAddedAccount() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        let folder = try h.folder("Claude_204")
        await h.quota.push([folder: QuotaReading(freshness: .stale, lastError: .signedOut)])
        await h.engine.perform(.panelOpened)
        await h.engine.perform(.switchTo(folder: folder))
        try h.writeSignIn(folder: folder, account: SandboxFixture.ID.account204, org: SandboxFixture.ID.organization204)
        await h.engine.checkPendingSignIns()
        let pending = try await h.store.load().pendingSignIns
        XCTAssertTrue(pending.isEmpty, "\(pending)")
        // 204 was registered all along: nothing was added.
        let outcome = await h.snapshot().lastResult?.outcome
        if case .added = outcome { XCTFail("signing in again was reported as \(String(describing: outcome))") }
        // A new account still says it was added.
        await h.engine.perform(.addAccount)
        let added = try engineUnwrap(await h.snapshot().pendingAdd?.folder)
        try h.writeSignIn(folder: added)
        await h.engine.checkPendingSignIns()
        let addedOutcome = await h.snapshot().lastResult?.outcome
        XCTAssertEqual(addedOutcome, .added(folder: added, warnings: []))
        await h.cleanup()
    }

    func testWaitingForASignInAgainDoesNotAskTheServiceEveryPoll() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        let folder = try h.folder("Claude_204")
        // The service turned the session down; Claude still holds the old cookie and the same login.
        try h.writeSignIn(folder: folder, account: SandboxFixture.ID.account204, org: SandboxFixture.ID.organization204)
        await h.quota.push([folder: QuotaReading(freshness: .stale, lastError: .signedOut)])
        await h.quota.setDetails(.failure(.signedOut))
        await h.engine.perform(.panelOpened)
        await h.engine.perform(.switchTo(folder: folder))
        let pending = try await h.store.load().pendingSignIns
        XCTAssertEqual(pending.map(\.folder), [folder])
        // The app checks every 2 s while a sign-in is pending: ten checks are 20 s of waiting.
        for _ in 0..<10 { await h.engine.checkPendingSignIns() }
        let calls = await h.quota.detailCalls.count
        XCTAssertLessThanOrEqual(calls, 1, "the service was asked \(calls) times in 20 s")
        await h.cleanup()
    }

    func testSwitchingToAnotherAccountEndsTheWaitForASignInAgain() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        let folder = try h.folder("Claude_204")
        await h.quota.push([folder: QuotaReading(freshness: .stale, lastError: .signedOut)])
        await h.engine.perform(.panelOpened)
        await h.engine.perform(.switchTo(folder: folder))
        var pending = try await h.store.load().pendingSignIns
        XCTAssertEqual(pending.map(\.folder), [folder])
        // The switch closes the window the sign-in was waited in.
        let other = try h.folder("Claude")
        await h.engine.perform(.switchTo(folder: other))
        let state = try await h.store.load()
        XCTAssertEqual(state.activeFolder, other)
        pending = state.pendingSignIns
        XCTAssertTrue(pending.isEmpty, "\(pending)")
        await h.cleanup()
    }

    func testANewCookieAfterARefusedOneIsAskedAbout() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        let folder = try h.folder("Claude_204")
        try h.writeSignIn(folder: folder, account: SandboxFixture.ID.account204, org: SandboxFixture.ID.organization204)
        await h.quota.push([folder: QuotaReading(freshness: .stale, lastError: .signedOut)])
        await h.quota.setDetails(.failure(.signedOut))
        await h.engine.perform(.panelOpened)
        await h.engine.perform(.switchTo(folder: folder))
        await h.engine.checkPendingSignIns()
        let waiting = try await h.store.load().pendingSignIns
        XCTAssertEqual(waiting.map(\.folder), [folder])
        // Signing in again gives the profile a new cookie: that one is asked about, and accepted.
        h.cookies.setCookie(EncryptedCookie(hostKey: ".claude.ai", encryptedValue: Data([2]), databaseVersion: 0),
                            for: h.world.profileDirectory(folder.name))
        await h.quota.setDetails(.success(AccountRecord(accountUUID: SandboxFixture.ID.account204, email: nil,
            organizationUUID: SandboxFixture.ID.organization204, plan: nil)))
        await h.engine.checkPendingSignIns()
        let calls = await h.quota.detailCalls.count
        XCTAssertEqual(calls, 2)
        let left = try await h.store.load().pendingSignIns
        XCTAssertTrue(left.isEmpty, "\(left)")
        await h.cleanup()
    }

    func testPartialCleanupIsReportedAfterTheFolderMoves() async throws {
        let h = try await EngineHarness()
        await h.start()
        let cache = h.world.paths.companionDataDirectory.appending(path: "quota-cache.json")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        let folder = try h.folder("Claude_204")
        await h.engine.perform(.remove(folder: folder))
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .removed(folder: folder, partialCleanup: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.world.profileDirectory(folder.name).path))
        let state = try await h.store.load()
        XCTAssertFalse(state.accounts.contains { $0.folder == folder })
        await h.cleanup()
    }

    func testRemovalWaitsForHelpersOrTasksThatOutlivedTheirMainProcess() async throws {
        let h = try await EngineHarness(autoSync: false, running: ["Claude"])
        await h.start()
        let other = try h.folder("Claude_204")
        let folder = h.world.profileDirectory("Claude_204")
        h.process.setLeftoverUse(profiles: [folder])
        await h.engine.perform(.remove(folder: other))
        var snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .remove(other), reason: .refusedWhileRunning))
        h.process.setLeftoverUse(profiles: [], unattributed: true)
        await h.engine.perform(.remove(folder: other))
        snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .remove(other), reason: .runningStateUnknown))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        h.process.setLeftoverUse(profiles: [])
        await h.engine.perform(.remove(folder: other))
        snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .removed(folder: other, partialCleanup: false))
        await h.cleanup()
    }

    func testRemovingAnAccountForgetsItsRelaunch() async throws {
        let h = try await EngineHarness(autoSync: false, running: ["Claude"])
        await h.start()
        let other = try h.folder("Claude_204"), owed = try h.folder("Claude_Kxm8")
        try await h.store.update { @Sendable state in state.relaunchDebt = [other, owed] }
        await h.engine.perform(.remove(folder: other))
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .removed(folder: other, partialCleanup: false))
        let state = try await h.store.load()
        XCTAssertEqual(state.relaunchDebt, [owed])
        await h.cleanup()
    }

    func testRemovalRefusalsAndArchiveThenCleanup() async throws {
        let h = try await EngineHarness(autoSync: false, running: ["Claude", "Claude_204"])
        await h.start()
        let active = try h.folder("Claude"), other = try h.folder("Claude_204")
        await h.engine.perform(.remove(folder: active))
        var snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .remove(active), reason: .refusedActiveAccount))
        await h.engine.perform(.remove(folder: other))
        snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .remove(other), reason: .refusedWhileRunning))
        h.process.failInstances(.failed("unreadable"))
        await h.engine.perform(.remove(folder: other))
        snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .remove(other), reason: .runningStateUnknown))
        h.process.setInstances([])
        await h.engine.perform(.remove(folder: other))
        snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .removed(folder: other, partialCleanup: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.world.profileDirectory(other.name).path))
        try await h.store.update { @Sendable state in state.accounts = state.accounts.filter { $0.folder == active }; state.activeFolder = nil }
        await h.engine.perform(.remove(folder: active))
        snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .remove(active), reason: .refusedLastAccount))
        await h.cleanup()
    }
}
