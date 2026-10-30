import Foundation
import XCTest
@testable import CompanionCore

@MainActor
final class CompanionEngineTests: XCTestCase {
    func testStartupLogsTheVersionSoTheLogShowsWhichBuildRan() async throws {
        let h = try await EngineHarness(running: [])
        await h.start()
        await h.start()
        XCTAssertEqual(try h.logLines(containing: "Started version 0.1.0.").count, 1)
        await h.cleanup()
    }

    func testAClaudeThatIsNowhereToBeFoundIsSaidOnThePanel() async throws {
        for found in [false, true] {
            let h = try await EngineHarness(running: [], claudeFound: found)
            await h.start()
            let snapshot = await h.snapshot()
            XCTAssertEqual(snapshot.banners.contains(.claudeNotFound), !found)
            await h.cleanup()
        }
    }

    func testStartupRepairsAnEnabledSettingWhoseLoginItemWasNeverInstalled() async throws {
        let h = try await EngineHarness(running: [])
        try await h.store.update { @Sendable state in state.settings.launchAtLogin = true }
        await h.start()
        let enabled = try await h.login.isEnabled
        XCTAssertTrue(enabled)
        XCTAssertEqual(h.login.recordedEnables().count, 1)
        await h.cleanup()
    }

    func testStartupDoesNotRewriteAnExistingLoginItem() async throws {
        let h = try await EngineHarness(running: [])
        try await h.store.update { @Sendable state in state.settings.launchAtLogin = true }
        h.login.setEnabled(true)
        await h.start()
        XCTAssertTrue(h.login.recordedEnables().isEmpty)
        await h.cleanup()
    }

    func testStartupRespectsADisabledLoginItemSetting() async throws {
        let h = try await EngineHarness(running: [])
        try await h.store.update { @Sendable state in state.settings.launchAtLogin = false }
        await h.start()
        XCTAssertTrue(h.login.recordedEnables().isEmpty)
        let enabled = try await h.login.isEnabled
        XCTAssertFalse(enabled)
        await h.cleanup()
    }

    func testFailedInitialLoginItemDoesNotLeaveTheSettingEnabled() async throws {
        let h = try await EngineHarness(register: false, running: [])
        try await h.store.update { @Sendable state in state.settings.launchAtLogin = true }
        h.login.failEnable(.failed("fixture"))
        await h.start()
        let snapshot = await h.snapshot()
        XCTAssertFalse(snapshot.settings.launchAtLogin)
        let stored = try await h.store.load()
        XCTAssertFalse(stored.settings.launchAtLogin)
        XCTAssertTrue(h.login.recordedEnables().isEmpty)
        await h.cleanup()
    }

    func testAutoCorrectionPreservesTheBusyCurrentInstance() async throws {
        let h = try await EngineHarness(autoSync: false, active: "Claude_204", running: ["Claude", "Claude_204"], flagless: ["Claude"])
        await h.start()
        let original = try await h.process.runningInstances()
        let busy = try XCTUnwrap(original.first { $0.profileDirectory.lastPathComponent == "Claude_204" })
        h.inspector.enqueue(.busy([CodeTaskInfo(pid: 987, reason: .statusBusy)]))
        await h.engine.handleLaunch(LaunchEvent(pid: 10, profileDirectory: h.world.profileDirectory("Claude"), hasExplicitProfileFlag: false))
        let remaining = try await h.process.runningInstances()
        XCTAssertEqual(remaining, [busy])
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        XCTAssertEqual(h.process.recordedScopedQuits().map(\.pid), [10])
        XCTAssertTrue(h.process.recordedLaunches().isEmpty)
        await h.cleanup()
    }

    func testFirstRunLeavesStartingAtLoginToThePerson() async throws {
        let h = try await EngineHarness(register: false, running: [])
        await h.start()
        let snapshot = await h.snapshot()
        XCTAssertFalse(snapshot.settings.launchAtLogin)
        let enabled = try await h.login.isEnabled
        XCTAssertFalse(enabled)
        XCTAssertTrue(h.login.recordedEnables().isEmpty)
        // Turned on in the settings, it installs the login item.
        await h.engine.perform(.setLaunchAtLogin(true))
        XCTAssertEqual(h.login.recordedEnables(), [h.scratch.root.appending(path: "CCRelay")])
        await h.cleanup()
    }

    func testAnAccountAlreadyOpenLetsGoOfTheWatchesKeptForIt() async throws {
        let h = try await EngineHarness(active: "Claude_204", running: ["Claude_204"])
        let kept = h.world.paths.companionDataDirectory.appending(path: "NativeRecovery/left-watches")
        let watch = NativeLeftWatch(desktopSessionID: "local_kept", sessionID: "kept-session", title: "Review the page",
                                    leftAt: h.clock.now().timeIntervalSince1970 * 1000, pages: ["https://claude.ai/artifact/kept"])
        for name in ["Claude_204", "Claude"] {
            try AtomicFile.write(JSONEncoder().encode([watch]), to: kept.appending(path: "\(name).json"))
        }
        await h.start()
        func opened(_ name: String) throws -> [Bool?] {
            try JSONDecoder().decode([NativeLeftWatch].self, from: AtomicFile.read(kept.appending(path: "\(name).json"))).map(\.opened)
        }
        // Claude is open on the current account already, so Desktop cannot be told to start those
        // conversations: each picks its watch up when it is opened. Their record stays, marked, to
        // tell the other accounts whose pages they are.
        XCTAssertEqual(try opened("Claude_204"), [true])
        let snapshot = await h.snapshot()
        XCTAssertFalse(snapshot.banners.contains { if case .watchesStayed(let account, _) = $0 { account.name == "Claude_204" } else { false } })
        // Those kept for an account that is not open wait for it.
        XCTAssertEqual(try opened("Claude"), [nil])
        XCTAssertTrue(snapshot.banners.contains { if case .watchesStayed(let account, _) = $0 { account.name == "Claude" } else { false } })
        // The open Claude is listed with its account, for its conversations to tell their own
        // account's watches from another's.
        let listed = try JSONDecoder().decode([NativeOpenAccount].self, from: AtomicFile.read(
            h.world.paths.companionDataDirectory.appending(path: "NativeRecovery/open-accounts.json")))
        XCTAssertEqual(listed.map(\.pid), [10])
        XCTAssertEqual(listed.map(\.account), ["Claude_204"])
        await h.cleanup()
    }

    func testEveryAccountOpenAlreadyLetsGoOfTheWatchesKeptForIt() async throws {
        for flagless in [false, true] {
            let h = try await EngineHarness(active: "Claude_204", running: ["Claude_204", "Claude"], flagless: flagless ? ["Claude"] : [])
            let kept = h.world.paths.companionDataDirectory.appending(path: "NativeRecovery/left-watches")
            let watch = NativeLeftWatch(desktopSessionID: "local_kept", sessionID: "kept-session", title: "Review the page",
                                        leftAt: h.clock.now().timeIntervalSince1970 * 1000, pages: ["https://claude.ai/artifact/kept"])
            for name in ["Claude_204", "Claude", "Claude_Kxm2"] {
                try AtomicFile.write(JSONEncoder().encode([watch]), to: kept.appending(path: "\(name).json"))
            }
            await h.start()
            func waiting(_ name: String) throws -> Bool {
                try JSONDecoder().decode([NativeLeftWatch].self, from: AtomicFile.read(kept.appending(path: "\(name).json")))
                    .contains { $0.opened != true }
            }
            XCTAssertFalse(try waiting("Claude_204"))
            // Opened beside it with its own profile, another account stays open too: its conversations
            // cannot be started for their watch either. A plain launch of the default account is
            // auto-correct's to close, so its conversations still wait for it.
            XCTAssertEqual(try waiting("Claude"), flagless, "flagless \(flagless)")
            XCTAssertTrue(try waiting("Claude_Kxm2"))
            // Still, each open Claude is listed with the account it is open on.
            let listed = try JSONDecoder().decode([NativeOpenAccount].self, from: AtomicFile.read(
                h.world.paths.companionDataDirectory.appending(path: "NativeRecovery/open-accounts.json")))
            XCTAssertEqual(listed.map(\.account), ["Claude_204", "Claude"], "flagless \(flagless)")
            await h.cleanup()
        }
    }

    func testThePluginSwitchFollowsTheSettingAndTheLanguage() async throws {
        let h = try await EngineHarness()
        await h.start()
        let url = h.world.paths.companionDataDirectory.appending(path: "AutoCompact/settings.json")
        func written() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(url)) as? [String: Any])
        }
        var settings = try written()
        XCTAssertEqual(settings["enabled"] as? Bool, true)
        XCTAssertEqual(settings["minContextTokens"] as? Int, 100_000)
        await h.engine.perform(.setAutoCompact(false))
        settings = try written()
        XCTAssertEqual(settings["enabled"] as? Bool, false)
        await h.engine.perform(.setLanguage(.zhHans))
        settings = try written()
        XCTAssertEqual(settings["language"] as? String, "zh-Hans")
        XCTAssertEqual(settings["enabled"] as? Bool, false)
        await h.cleanup()
    }

    func testTheSwitchQuestionCanBeTurnedOffAndBackOn() async throws {
        let h = try await EngineHarness()
        await h.start()
        let before = await h.snapshot()
        XCTAssertTrue(before.settings.confirmSwitch)
        await h.engine.perform(.setConfirmSwitch(false))
        let off = await h.snapshot()
        XCTAssertFalse(off.settings.confirmSwitch)
        await h.engine.perform(.setConfirmSwitch(true))
        let on = await h.snapshot()
        XCTAssertTrue(on.settings.confirmSwitch)
        await h.cleanup()
    }

    func testAFailedCompactionIsLoggedWithTheHostReasonMasked() async throws {
        let h = try await EngineHarness()
        await h.start()
        let folder = h.world.paths.companionDataDirectory.appending(path: "AutoCompact")
        let now = Int64(h.clock.now().timeIntervalSince1970 * 1000)
        try AtomicFile.write(JSONSerialization.data(withJSONObject: ["reason": "early", "status": "failed",
            "tokensBefore": 468_539, "tokensAfter": 468_539, "finishedAt": now, "resumed": false,
            "error": "Account dana@example.com cannot run /compact here"]),
                             to: folder.appending(path: "results/1-s1.json"))
        await h.engine.perform(.panelOpened)
        let lines = try h.logLines(containing: "Auto-compact")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.hasSuffix("INFO quota Auto-compact (early line): failed, 468539 -> 468539 tokens. "
            + "Reason: Account d\u{2022}\u{2022}\u{2022}@example.com cannot run /compact here") == true, lines.first ?? "no line")
        await h.cleanup()
    }

    func testThePluginsReportsReachSettingsTheLogAndOneNotice() async throws {
        let h = try await EngineHarness()
        await h.start()
        let folder = h.world.paths.companionDataDirectory.appending(path: "AutoCompact")
        let now = Int64(h.clock.now().timeIntervalSince1970 * 1000)
        try AtomicFile.write(JSONSerialization.data(withJSONObject: ["sessionID": "s1", "updatedAt": now]),
                             to: folder.appending(path: "sessions/s1.json"))
        try AtomicFile.write(JSONSerialization.data(withJSONObject: ["reason": "hard", "status": "compacted",
            "tokensBefore": 812_000, "tokensAfter": 74_000, "finishedAt": now, "resumed": true]),
                             to: folder.appending(path: "results/1-s1.json"))
        await h.engine.perform(.panelOpened)
        var snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.autoCompact.status.liveConversations, 1)
        let result = try XCTUnwrap(snapshot.autoCompact.lastResult)
        XCTAssertEqual(result.trigger, .hard)
        XCTAssertTrue(snapshot.banners.contains(.autoCompacted(result)))
        var lines = try h.logLines(containing: "Auto-compact")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.hasSuffix("INFO quota Auto-compact (hard line, task paused and resumed): compacted, "
            + "812000 -> 74000 tokens.") == true, lines.first ?? "no line")
        // Reported once: the file moved to seen/, and the notice leaves once the panel showed it and closed.
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "results/seen/1-s1.json").path))
        await h.engine.panelClosed()
        await h.engine.perform(.panelOpened)
        snapshot = await h.snapshot()
        XCTAssertFalse(snapshot.banners.contains { if case .autoCompacted = $0 { return true }; return false })
        XCTAssertEqual(snapshot.autoCompact.lastResult, result)
        lines = try h.logLines(containing: "Auto-compact")
        XCTAssertEqual(lines.count, 1)
        await h.cleanup()
    }

    func testAPausedTaskThatDidNotGoOnShowsANoticeEvenWhenNothingWasCompacted() async throws {
        let h = try await EngineHarness()
        await h.start()
        let folder = h.world.paths.companionDataDirectory.appending(path: "AutoCompact")
        let now = Int64(h.clock.now().timeIntervalSince1970 * 1000)
        try AtomicFile.write(JSONSerialization.data(withJSONObject: ["reason": "hard", "status": "skipped",
            "tokensBefore": 812_000, "finishedAt": now, "resumed": false,
            "error": "the task could not be resumed: Prompt queue is full"]), to: folder.appending(path: "results/1-s1.json"))
        await h.engine.perform(.panelOpened)
        let snapshot = await h.snapshot()
        let result = try XCTUnwrap(snapshot.autoCompact.lastResult)
        XCTAssertTrue(result.leftTaskPaused)
        XCTAssertTrue(snapshot.banners.contains(.autoCompacted(result)))
        let lines = try h.logLines(containing: "Auto-compact")
        XCTAssertTrue(lines.first?.hasSuffix("INFO quota Auto-compact (hard line, task paused, not resumed): skipped, 812000 tokens. "
            + "Reason: the task could not be resumed: Prompt queue is full") == true, lines.first ?? "no line")
        await h.cleanup()
    }

    func testACompactionBeforeASwitchShowsANoticeOnlyWhenItCompacted() async throws {
        let h = try await EngineHarness()
        await h.start()
        let folder = h.world.paths.companionDataDirectory.appending(path: "AutoCompact")
        let now = Int64(h.clock.now().timeIntervalSince1970 * 1000)
        try AtomicFile.write(JSONSerialization.data(withJSONObject: ["reason": "switch", "status": "failed",
            "tokensBefore": 400_000, "tokensAfter": 400_000, "finishedAt": now, "resumed": false,
            "error": "another conversation on this Mac was compacting"]), to: folder.appending(path: "results/1-s1.json"))
        await h.engine.perform(.panelOpened)
        var snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.autoCompact.lastResult?.trigger, .beforeSwitch)
        XCTAssertFalse(snapshot.banners.contains { if case .autoCompacted = $0 { return true }; return false })
        await h.engine.panelClosed()
        try AtomicFile.write(JSONSerialization.data(withJSONObject: ["reason": "switch", "status": "compacted",
            "tokensBefore": 400_000, "tokensAfter": 30_000, "finishedAt": now + 1, "resumed": false]),
                             to: folder.appending(path: "results/2-s1.json"))
        await h.engine.perform(.panelOpened)
        snapshot = await h.snapshot()
        let result = try XCTUnwrap(snapshot.autoCompact.lastResult)
        XCTAssertEqual(result.outcome, .compacted)
        XCTAssertTrue(snapshot.banners.contains(.autoCompacted(result)))
        let lines = try h.logLines(containing: "Auto-compact (before a switch)")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.first?.hasSuffix("failed, 400000 -> 400000 tokens. Reason: another conversation on this Mac was compacting") == true,
                      lines.first ?? "no line")
        XCTAssertTrue(lines.last?.hasSuffix("compacted, 400000 -> 30000 tokens.") == true, lines.last ?? "no line")
        await h.cleanup()
    }

    func testFirstRunRegistersEverySignedInProfileAndOldNamesDecodeAsManual() async throws {
        let h = try await EngineHarness(register: false)
        await h.start()
        let state = try await h.store.load()
        XCTAssertEqual(state.accounts.count, 4)
        XCTAssertEqual(state.accounts.first?.displayName, AccountManager.placeholder(language: .system, firstRun: true))
        XCTAssertEqual(state.accounts.map(\.displayName).dropFirst(), ["204", "Kxm2", "Kxm8"])
        XCTAssertTrue(state.accounts.allSatisfy(\.nameIsAutomatic))
        let data = try JSONSerialization.data(withJSONObject: ["folder": "Claude", "displayName": "manual", "addedAt": "2026-10-25T00:00:00Z"])
        let old = try StableJSON.decode(ManagedAccount.self, from: data)
        XCTAssertFalse(old.nameIsAutomatic)
        await h.cleanup()
    }

    func testQuotaWiringAndStickyResultsAndSnapshotStream() async throws {
        let h = try await EngineHarness(autoSync: false)
        var iterator = h.engine.snapshots().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertNotNil(initial)
        await h.start()
        let folder = try h.folder("Claude_204")
        await h.engine.perform(.panelOpened)
        let replacements = await h.quota.replacements
        XCTAssertEqual(Set(try XCTUnwrap(replacements.last).map(\.folder)), Set(h.profiles.map(\.folder)))
        let visible = await h.quota.visible
        XCTAssertEqual(Set(try XCTUnwrap(visible.last)), Set(h.profiles.map(\.folder)))
        await h.engine.perform(.refreshQuota(folder: folder))
        await h.engine.perform(.refreshQuota(folder: nil))
        let refreshes = await h.quota.refreshes
        XCTAssertEqual(refreshes.first?.0, [folder])
        XCTAssertTrue(refreshes.allSatisfy(\.1))
        XCTAssertEqual(refreshes.last?.0.count, 4)
        let reading = QuotaSnapshot(folder: folder, accountUUID: SandboxFixture.ID.account204,
            organizationUUID: SandboxFixture.ID.organization204, plan: "Pro", email: "a@example.com", channel: .web, fetchedAt: h.clock.now())
        await h.quota.push([folder: QuotaReading(snapshot: reading, freshness: .stale, lastError: .keyUnavailable)])
        var seen = await eventually { await h.snapshot().banners.contains(.quotaUnavailable) }
        XCTAssertTrue(seen)
        var snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.accounts.first { $0.folder == folder }?.email, "a@example.com")
        XCTAssertEqual(snapshot.accounts.first { $0.folder == folder }?.quotaFreshness, .stale)
        await h.quota.push([folder: QuotaReading(snapshot: reading, freshness: .stale, lastError: .signedOut)])
        seen = await eventually { await h.snapshot().accounts.first { $0.folder == folder }?.status == .signedOut }
        XCTAssertTrue(seen)
        snapshot = await h.snapshot()
        XCTAssertFalse(snapshot.banners.contains(.quotaUnavailable))
        await h.quota.push([folder: QuotaReading(snapshot: reading, freshness: .fresh)])
        await h.engine.perform(.switchTo(folder: folder))
        snapshot = await h.snapshot()
        let result = try XCTUnwrap(snapshot.lastResult)
        await h.engine.perform(.panelOpened)
        snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.id, result.id)
        await h.engine.perform(.dismissResult(id: result.id))
        snapshot = await h.snapshot()
        XCTAssertNil(snapshot.lastResult)
        let currents = await h.quota.currents
        XCTAssertEqual(currents.last!, folder)
        await h.cleanup()
    }

    func testAMissingSignInCookieAsksToSignInAgainAndTheCardStartsIt() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        let folder = try h.folder("Claude_204")
        await h.quota.push([folder: QuotaReading(snapshot: nil, freshness: .unavailable, lastError: .cookieMissing)])
        let seen = await eventually { await h.snapshot().accounts.first { $0.folder == folder }?.status == .signedOut }
        XCTAssertTrue(seen)
        await h.engine.perform(.switchTo(folder: folder))
        let pending = try await h.store.load().pendingSignIns
        XCTAssertEqual(pending.map(\.folder), [folder])
        XCTAssertEqual(pending.first?.expectAccountUUID, SandboxFixture.ID.account204)
        await h.cleanup()
    }

    func testAProfileWithoutAnOrganizationStampStillShowsWhatTheServiceRead() async throws {
        let h = try await EngineHarness(autoSync: false, register: false)
        let folder = try h.folder("Claude_204")
        try AtomicFile.write(JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": SandboxFixture.ID.account204]),
            to: h.world.profileDirectory(folder.name).appending(path: "config.json"))
        XCTAssertNil(try ProfileScanner(paths: h.world.paths).scan().profiles.first { $0.folder == folder }?.identity?.activeOrganizationUUID)
        await h.start()
        // The service read the account's only organization.
        let read = QuotaSnapshot(folder: folder, accountUUID: SandboxFixture.ID.account204,
            organizationUUID: SandboxFixture.ID.organization204, plan: "Pro", email: "nora@example.com", channel: .web,
            fiveHour: QuotaWindow(usedPercent: 35), fetchedAt: h.clock.now())
        await h.quota.push([folder: QuotaReading(snapshot: read, freshness: .fresh)])
        let seen = await eventually { await h.snapshot().accounts.first { $0.folder == folder }?.quota != nil }
        XCTAssertTrue(seen)
        let accounts = await h.snapshot().accounts
        let account = try XCTUnwrap(accounts.first { $0.folder == folder })
        XCTAssertEqual(account.quota?.fiveHour.usedPercent, 35)
        XCTAssertEqual(account.email, "nora@example.com")
        XCTAssertEqual(account.plan, "Pro")
        XCTAssertEqual(account.displayName, "nora")
        await h.cleanup()
    }

    func testTheFirstSwitchedSnapshotAlreadyNamesTheNewCurrentAccount() async throws {
        let h = try await EngineHarness(autoSync: false)
        await h.start()
        let stream = h.engine.snapshots()
        let received = Task { () -> CompanionSnapshot? in
            for await value in stream {
                if case .switched = value.lastResult?.outcome { return value }
            }
            return nil
        }
        let folder = try h.folder("Claude_204")
        await h.engine.perform(.switchTo(folder: folder))
        let snapshot = await received.value
        XCTAssertEqual(snapshot?.currentFolder, folder)
        XCTAssertNil(snapshot?.operation)
        await h.cleanup()
    }

    func testQuotaOnlyRegistersManagedSignedInAndBackupsAreRevealed() async throws {
        let h = try await EngineHarness()
        await h.start()
        let removed = try h.folder("Claude_Kxm8")
        try await h.store.update { @Sendable state in state.accounts.removeAll { $0.folder == removed } }
        try AtomicFile.write(Data("{}".utf8), to: h.world.profileDirectory("Claude_204").appending(path: "config.json"))
        await h.engine.perform(.panelOpened)
        let calls = await h.quota.replacements
        XCTAssertEqual(Set(try XCTUnwrap(calls.last).map { $0.folder.name }), ["Claude", "Claude_Kxm2"])
        await h.engine.perform(.openBackupsFolder)
        let backup = h.world.paths.companionDataDirectory.appending(path: "Backups")
        XCTAssertEqual(h.revealer.recordedURLs(), [backup])
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        await h.cleanup()
    }

    func testRelaunchDebtSurvivesRestartAndClaimsExactlyOnce() async throws {
        let h = try await EngineHarness(running: [])
        let folders = try [h.folder("Claude"), h.folder("Claude_204")]
        let debt = RelaunchDebt(store: h.store)
        try await debt.record(folders + [folders[0]])
        await h.start()
        XCTAssertEqual(h.process.recordedLaunches().count, 2)
        await h.engine.perform(.panelOpened)
        XCTAssertEqual(h.process.recordedLaunches().count, 2)
        try await debt.record(folders)
        let claimed = try await withThrowingTaskGroup(of: [ProfileFolder].self) { group in
            for _ in 0..<10 { group.addTask { try await debt.claim() } }
            var all: [ProfileFolder] = []
            for try await part in group { all += part }
            return all
        }
        XCTAssertEqual(claimed, folders)
        await h.cleanup()
    }

    func testAutoCorrectValidatesTheRememberedTargetBeforeClosing() async throws {
        let h = try await EngineHarness(active: "Claude_204")
        await h.start()
        try AtomicFile.write(Data("{}".utf8), to: h.world.profileDirectory("Claude_204").appending(path: "config.json"))
        let event = LaunchEvent(pid: 10, profileDirectory: h.world.profileDirectory("Claude"), hasExplicitProfileFlag: false)
        await h.engine.handleLaunch(event)
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        await h.cleanup()
    }

    func testAutoCorrectionDoesNotForceTheDefaultWhenTasksBecomeBusy() async throws {
        let h = try await EngineHarness(active: "Claude_204", running: ["Claude", "Claude_Kxm8"], flagless: ["Claude", "Claude_Kxm8"])
        await h.start()
        let original = try await h.process.runningInstances()
        h.process.consultBeforeForce(closedProfilesWhenRefused: [])
        h.inspector.enqueue(.busy([CodeTaskInfo(pid: 11, reason: .statusBusy)]))
        await h.engine.handleLaunch(LaunchEvent(pid: 10, profileDirectory: h.world.profileDirectory("Claude"), hasExplicitProfileFlag: false))
        XCTAssertEqual(h.process.recordedBeforeForceAnswers(), [false])
        let remaining = try await h.process.runningInstances()
        XCTAssertEqual(remaining, original)
        XCTAssertTrue(h.process.recordedLaunches().isEmpty)
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        let state = try await h.store.load()
        XCTAssertTrue(state.relaunchDebt.isEmpty)
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .autoCorrect, reason: .couldNotCloseClaude))
        await h.cleanup()
    }

    func testAutoCorrectIgnoresExplicitFlagsAndPausesLoopForTenMinutes() async throws {
        let h = try await EngineHarness(autoSync: false, active: "Claude_204", flagless: ["Claude"])
        await h.start()
        let event = LaunchEvent(pid: 10, profileDirectory: h.world.profileDirectory("Claude"), hasExplicitProfileFlag: true)
        await h.engine.handleLaunch(event)
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        var external = event
        external.hasExplicitProfileFlag = false
        h.process.consultBeforeForce(closedProfilesWhenRefused: [])
        h.inspector.enqueue(.idle)
        await h.engine.handleLaunch(external)
        XCTAssertEqual(h.process.recordedBeforeForceAnswers(), [true])
        XCTAssertEqual(h.process.recordedLaunches().last?.profile.lastPathComponent, "Claude_204")
        let corrected = try h.logLines(containing: " switch Auto-correct ")
        XCTAssertEqual(corrected.count, 1)
        XCTAssertTrue(corrected.first?.hasSuffix("INFO switch Auto-correct Claude -> Claude_204: switched back in 0.0 s") == true,
                      corrected.first ?? "no line")
        h.clock.advance(by: 59)
        await h.engine.handleLaunch(external)
        var snapshot = await h.snapshot()
        XCTAssertTrue(snapshot.banners.contains(.autoCorrectPaused))
        XCTAssertEqual(h.process.recordedScopedQuits().count, 1)
        h.clock.advance(by: 599)
        await h.engine.handleLaunch(external)
        XCTAssertEqual(h.process.recordedScopedQuits().count, 1)
        h.clock.advance(by: 2)
        var running = try await h.process.runningInstances()
        running.append(ClaudeInstance(pid: 10, profileDirectory: h.world.profileDirectory("Claude"), hasExplicitProfileFlag: false,
            startedAt: h.clock.now(), executableURL: h.world.paths.claudeAppURL))
        h.process.setInstances(running)
        await h.engine.handleLaunch(external)
        XCTAssertEqual(h.process.recordedScopedQuits().count, 2)
        snapshot = await h.snapshot()
        XCTAssertFalse(snapshot.banners.contains(.autoCorrectPaused))
        await h.cleanup()
    }
}
