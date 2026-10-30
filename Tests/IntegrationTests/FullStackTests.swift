import CompanionCore
import CompanionPlatform
import CompanionUI
import Foundation
import XCTest
@testable import CCRelay

@MainActor
final class FullStackTests: XCTestCase {
    private func harness(environment: [String: String] = [:], autoPoll: Bool = false) throws -> IntegrationHarness {
        let harness = try IntegrationHarness(environment: environment, autoPoll: autoPoll)
        addTeardownBlock { await harness.cleanup() }
        return harness
    }

    func testDefaultCorrectionLeavesTheBusyCurrentFakeClaudeProcessUntouched() async throws {
        let h = try harness()
        try await h.start(launch: "Claude_204")
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        let active = try require(try await h.services.processes.runningInstances().first { $0.profileDirectory.lastPathComponent == "Claude_204" })
        try h.setTasks(busy: true)
        _ = try h.launchFlagless()
        try await waitFor { (await h.snapshot()).banners.contains(.autoCorrected(to: try h.folder("Claude_204"))) }
        let running = try await h.services.processes.runningInstances()
        expectEqual(running, [active])
        expectNil((await h.snapshot()).taskGuardPrompt)
    }

    func testFirstRunRegistersSignedInProfilesAndQuotaRunsThroughEncryptedCookiesToMenuBar() async throws {
        let h = try harness()
        expectFalse(FileManager.default.fileExists(atPath: h.world.paths.companionDataDirectory.appendingPathComponent("state.json").path))
        await h.engine.start()
        let state = try h.state()
        expectEqual(state.accounts.map(\.folder.name), ["Claude", "Claude_204", "Claude_Kxm2", "Claude_Kxm8"])
        // Starting at login waits for the person to turn it on.
        let login = try await SandboxLoginItem(root: h.root).isEnabled
        expectFalse(login)
        let model = PanelViewModel(facade: h.engine, clock: h.clock)
        model.panelAppeared()
        try await waitFor { (await h.snapshot()).accounts.allSatisfy { $0.quota?.source == .network && $0.quotaFreshness == .fresh } }
        let values = await h.snapshot()
        expectEqual(values.accounts.map { $0.quota?.fiveHour.usedPercent }, [10, 20, 30, 40])
        expectEqual(values.accounts.map(\.channel), Array(repeating: .appStore, count: 4))
        expectEqual(values.accounts.map(\.email), ["ada@example.com", "bob@example.com", "cara@example.com", "dax@example.com"])
        // Without an email to go by, the first run names accounts by folder; the email names follow.
        try await waitFor { model.menuBarModel.title == "ada" && model.menuBarModel.quotaPercent == 90 }
        expectEqual(try h.state().accounts.map(\.displayName), ["ada", "bob", "cara", "dax"])
        let cookie = try require(SandboxSessionCookieReader(root: h.root).sessionCookie(profile: h.directory("Claude")))
        expectEqual(cookie.databaseVersion, 24)
        expectNil(cookie.plaintextValue)
        expectTrue(cookie.encryptedValue.starts(with: Data("v10".utf8)))
        let versions = try SandboxVersionReader(root: h.root).versions()
        expectTrue(ClaudeUserAgent.headerValue(claude: versions.claude, electron: versions.electron).contains("Claude/1.2.3 Electron/40.0.0"))
        await h.engine.panelClosed()
        await h.engine.perform(.openBackupsFolder)
        let revealed = try JSONDecoder().decode(String.self, from: Data(contentsOf: h.root.appendingPathComponent("revealed.json")))
        expectEqual(revealed, h.world.paths.companionDataDirectory.appendingPathComponent("Backups").path)
        do {
            try await SandboxFileRevealer(root: h.root).reveal(h.root.deletingLastPathComponent())
            XCTFail("Expected sandbox boundary refusal")
        } catch { expectEqual(error as? SandboxAdapterError, .outsideSandbox) }
    }

    func testSwitchMergesBothWaysBacksUpRebuildsIndexAndConfirmsFreshFocus() async throws {
        let h = try harness()
        try await h.start()
        let liveID = "local_" + SandboxFixture.ID.liveSession
        let archivedID = "local_" + SandboxFixture.ID.archivedSession
        let targetID = "local_" + SandboxFixture.ID.session204
        let transcript = try require(h.world.cliSessions.first { $0.cliSessionID == SandboxFixture.ID.liveSession }).transcriptFile
        let originalTranscript = try Data(contentsOf: transcript)
        let oldPID = try require(try await h.services.processes.runningInstances().first?.pid)
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        let snapshot = await h.snapshot()
        expectEqual(snapshot.currentFolder?.name, "Claude_204")
        expectEqual(snapshot.lastResult?.outcome, .switched(to: try h.folder("Claude_204"), warnings: []))
        expectTrue(FileManager.default.fileExists(atPath: try h.session("Claude_204", id: liveID).path))
        expectTrue(FileManager.default.fileExists(atPath: try h.session("Claude", id: targetID).path))
        let index = try h.session("Claude_204", id: liveID).deletingLastPathComponent().appendingPathComponent("archived-sessions.idx")
        let indexed = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any]
        expectTrue((indexed?["archived"] as? [String] ?? []).contains(archivedID))
        for name in ["Claude", "Claude_204"] {
            let backups = h.world.paths.companionDataDirectory.appendingPathComponent("Backups/" + name)
            expectFalse(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
        }
        expectEqual(try Data(contentsOf: transcript), originalTranscript)
        let running = try await h.services.processes.runningInstances()
        expectEqual(running.count, 1)
        expectNotEqual(running.first?.pid, oldPID)
        expectEqual(running.first?.profileDirectory.lastPathComponent, "Claude_204")
        let links = h.directory("Claude_204").appendingPathComponent(".fake-claude/deeplinks.log")
        expectEqual(try String(contentsOf: links, encoding: .utf8), "claude://code/continue?session=\(liveID)\n")
        let recordURL = try h.session("Claude_204", id: liveID)
        var record = try require(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        record["lastFocusedAt"] = Int64(h.clock.now().timeIntervalSince1970 * 1000) + 1
        try writeJSON(record, to: recordURL)
        try await Task.sleep(for: .milliseconds(300))
        // A confirmed task must stay complete even after its original timeout and a later stale record.
        record["lastFocusedAt"] = 0
        try writeJSON(record, to: recordURL)
        h.clock.advance(100)
        try await Task.sleep(for: .milliseconds(300))
        expectEqual((await h.snapshot()).lastResult?.outcome, snapshot.lastResult?.outcome)
        expectTrue(try h.state().relaunchDebt.isEmpty)
    }

    func testBusyGuardWaitsUntilSandboxTaskBecomesIdle() async throws {
        let h = try harness()
        try await h.start()
        try h.setTasks(busy: true)
        let work = Task { await h.engine.perform(.switchTo(folder: try h.folder("Claude_204"))) }
        try await waitFor { (await h.snapshot()).taskGuardPrompt?.busyCount == 1 }
        await h.engine.perform(.taskGuard(.waitThenSwitch))
        try await waitFor { (await h.snapshot()).taskGuardPrompt?.isWaiting == true }
        expectEqual(try await h.services.processes.runningInstances().first?.profileDirectory.lastPathComponent, "Claude")
        try h.setTasks(busy: false)
        try await work.value
        expectEqual((await h.snapshot()).currentFolder?.name, "Claude_204")
        expectNil((await h.snapshot()).taskGuardPrompt)
    }

    func testAddUsesFixtureEmailImportsEveryDonorThenRemoveArchivesFolder() async throws {
        let h = try harness(autoPoll: true)
        try await h.start()
        await h.engine.perform(.addAccount)
        let pending = try require((await h.snapshot()).pendingAdd?.folder)
        try SandboxWorldGenerator.installSignIn(root: h.root, folder: pending,
            account: "99999999-9999-4999-8999-999999999999", organization: "99999999-9999-4999-8999-999999999991",
            email: "new.person@example.com")
        try await waitFor {
            let state = try h.state()
            let snapshot = await h.snapshot()
            return state.pendingSignIns.isEmpty && state.historyJobs.isEmpty && state.accounts.contains { $0.folder == pending }
                && snapshot.operation == nil
        }
        expectEqual(try h.state().accounts.first { $0.folder == pending }?.displayName, "new.person")
        for id in [SandboxFixture.ID.liveSession, SandboxFixture.ID.archivedSession, SandboxFixture.ID.session204,
                   SandboxFixture.ID.session203, SandboxFixture.ID.session208] {
            expectTrue(FileManager.default.fileExists(atPath: try h.session(pending.name, id: "local_" + id).path))
        }
        expectEqual(try await h.services.processes.runningInstances().first?.profileDirectory.lastPathComponent, pending.name)
        await h.engine.perform(.switchTo(folder: try h.folder("Claude")))
        await h.engine.perform(.remove(folder: pending))
        expectEqual((await h.snapshot()).lastResult?.outcome, .removed(folder: pending, partialCleanup: false))
        expectFalse(FileManager.default.fileExists(atPath: h.directory(pending.name).path))
        let archives = try FileManager.default.contentsOfDirectory(atPath: h.world.paths.companionDataDirectory.appendingPathComponent("Archive").path)
        expectTrue(archives.contains { $0.hasPrefix(pending.name + "-") })
        expectFalse(try h.state().accounts.contains { $0.folder == pending })
    }

    func testFlaglessLaunchIsCorrectedByRealSandboxMonitor() async throws {
        let h = try harness()
        try await h.start(launch: nil)
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        let child = try h.launchFlagless()
        try await waitFor { (await h.snapshot()).banners.contains(.autoCorrected(to: try h.folder("Claude_204"))) }
        expectFalse(child.isRunning)
        let running = try await h.services.processes.runningInstances()
        expectFalse(running.isEmpty)
        expectTrue(running.allSatisfy { $0.hasExplicitProfileFlag && $0.profileDirectory.lastPathComponent == "Claude_204" })
    }

    func testALongConversationIsCompactedBeforeClaudeClosesThenReopenedOnTheNewAccount() async throws {
        let h = try harness()
        try await h.start()
        await h.engine.perform(.setAutoCompact(true))
        let session = SandboxFixture.ID.liveSession
        let transcript = try require(h.world.cliSessions.first { $0.cliSessionID == session }).transcriptFile
        let row: [String: Any] = ["type": "assistant", "sessionId": session,
            "message": ["usage": ["input_tokens": 10_000, "cache_read_input_tokens": 270_000,
                                  "cache_creation_input_tokens": 19_000, "output_tokens": 1_000]]]
        let bytes = try Data(contentsOf: transcript) + Data("\n".utf8) + JSONSerialization.data(withJSONObject: row) + Data("\n".utf8)
        try AtomicFile.write(bytes, to: transcript)
        // The plugin's part: the conversation reports, then answers the request with a compaction.
        let shared = h.world.paths.companionDataDirectory.appendingPathComponent("AutoCompact")
        let report: [String: Any] = ["sessionID": session, "updatedAt": Int64(h.clock.now().timeIntervalSince1970 * 1000),
                                     "switchRequests": true]
        try AtomicFile.write(JSONSerialization.data(withJSONObject: report), to: shared.appendingPathComponent("sessions/\(session).json"))
        let request = shared.appendingPathComponent("switch-request.json")
        let result = shared.appendingPathComponent("switch-result.json")
        let plugin = Task.detached { () -> Bool in
            for _ in 0..<2000 {
                if let data = try? Data(contentsOf: request),
                   let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = fields["id"] as? Int {
                    let answer: [String: Any] = ["id": id, "sessionID": session, "status": "compacted",
                                                 "tokensBefore": 300_000, "tokensAfter": 20_000]
                    return (try? AtomicFile.write(JSONSerialization.data(withJSONObject: answer), to: result)) != nil
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        let answered = await plugin.value
        expectTrue(answered)
        expectEqual((await h.snapshot()).lastResult?.outcome, .switched(to: try h.folder("Claude_204"), warnings: []))
        expectFalse(FileManager.default.fileExists(atPath: request.path))
        expectTrue(FileManager.default.fileExists(atPath: h.directory("Claude_204").appendingPathComponent(".fake-claude/deeplinks.log").path))
    }

    func testFailedTargetReturnsToPreviousAccountWithCapturedDeepLink() async throws {
        let h = try harness()
        try await h.start()
        try AtomicFile.write(Data(), to: h.directory("Claude_204").appendingPathComponent(".fake-claude/fail-launch"))
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        expectEqual((await h.snapshot()).lastResult?.outcome,
            .failed(operation: .switchTo(try h.folder("Claude_204")), reason: .returnedToPreviousAccount))
        expectEqual(try h.state().activeFolder?.name, "Claude")
        expectTrue(try h.state().relaunchDebt.isEmpty)
        expectEqual(try await h.services.processes.runningInstances().map { $0.profileDirectory.lastPathComponent }, ["Claude"])
        let links = try String(contentsOf: h.directory("Claude").appendingPathComponent(".fake-claude/deeplinks.log"), encoding: .utf8)
        expectTrue(links.contains("session=local_" + SandboxFixture.ID.liveSession))
    }

    func testSwitchForcesOrphanHelperAfterGraceAndCompletes() async throws {
        let h = try harness(environment: ["FAKE_CLAUDE_SPAWN_CHILD": "1", "FAKE_CLAUDE_ORPHAN_CHILD": "1", "FAKE_CLAUDE_CHILD_IGNORE_TERM": "1"])
        try await h.start()
        let helperFile = h.directory("Claude").appendingPathComponent(".fake-claude/child.json")
        let helper = try require(JSONSerialization.jsonObject(with: Data(contentsOf: helperFile)) as? [String: Any])
        let pid = try require(helper["pid"] as? Int32)
        let started = h.clock.now()
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        XCTAssertGreaterThanOrEqual(h.clock.now().timeIntervalSince(started), 5)
        expectNil(ProcessTable().record(pid: pid))
        expectEqual((await h.snapshot()).currentFolder?.name, "Claude_204")
        guard case .switched = (await h.snapshot()).lastResult?.outcome else { return XCTFail("Switch did not complete") }
    }

    func testTaskBecomingBusyDuringCloseBlocksEngineForceCheck() async throws {
        let h = try harness(environment: ["FAKE_CLAUDE_SPAWN_CHILD": "1", "FAKE_CLAUDE_ORPHAN_CHILD": "1", "FAKE_CLAUDE_CHILD_IGNORE_TERM": "1"])
        try await h.start()
        let data = try Data(contentsOf: h.directory("Claude").appendingPathComponent(".fake-claude/child.json"))
        struct Helper: Decodable { let pid: Int32 }
        let helper = try JSONDecoder().decode(Helper.self, from: data)
        let work = Task { await h.engine.perform(.switchTo(folder: try h.folder("Claude_204"))) }
        try await waitFor { try await h.services.processes.runningInstances().isEmpty }
        try h.setTasks(busy: true)
        try await work.value
        expectEqual((await h.snapshot()).lastResult?.outcome,
            .failed(operation: .switchTo(try h.folder("Claude_204")), reason: .couldNotCloseClaude))
        let survivor = ProcessTable().record(pid: helper.pid)
        XCTAssertNotNil(survivor)
        let expectedHelper = SandboxWorldGenerator.fakeClaudeExecutable(root: h.world.root)
            .deletingLastPathComponent().appendingPathComponent("Helpers/FakeClaudeHelper")
        expectTrue(survivor.map { ProfilePaths.same($0.executableURL, expectedHelper) } == true)
        expectTrue(try h.state().relaunchDebt.isEmpty)
        expectFalse(FileManager.default.fileExists(atPath: h.directory("Claude_204").appendingPathComponent(".fake-claude/instance.json").path))
    }
}
