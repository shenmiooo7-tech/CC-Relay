import Foundation
import XCTest
@testable import CompanionCore

/// A conversation long enough is compacted by its plugin on the account it leaves, before Claude
/// closes for the switch. These tests play the plugin's part through the files it shares.
@MainActor
final class CompactionBeforeSwitchTests: XCTestCase {
    private let session = SandboxFixture.ID.liveSession

    func testALongConversationIsCompactedOnTheAccountItLeavesBeforeClaudeCloses() async throws {
        let h = try await EngineHarness()
        await h.start()
        try appendUsage(h, tokens: 400_000)
        try reportLive(h)
        await h.engine.perform(.panelOpened)
        let target = try h.folder("Claude_204")
        let (work, request) = try await switchUntilAsked(h, target: target)
        XCTAssertEqual(request["sessionID"] as? String, session)
        let id = try XCTUnwrap(request["id"] as? Int)
        // A little before the wait for a start ends: whatever begins in time reaches the switch while it still waits.
        XCTAssertEqual(Double(try XCTUnwrap(request["until"] as? Int) - id), 170_000, accuracy: 1)
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        try answer(h, id: id, status: "compacted", tokensAfter: 30_000)
        // The plugin records it too, as it does every compaction.
        try AtomicFile.write(JSONSerialization.data(withJSONObject: ["reason": "switch", "status": "compacted",
            "tokensBefore": 400_000, "tokensAfter": 30_000, "resumed": false,
            "finishedAt": Int64(h.clock.now().timeIntervalSince1970 * 1000)]),
                             to: directory(h).appending(path: "results/1-\(session).json"))
        h.clock.release()
        await work.value
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .switched(to: target, warnings: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestFile(h).path))
        XCTAssertNotNil(h.process.recordedLaunches().first?.deepLink)
        let line = try switchLine(h)
        XCTAssertTrue(line.contains("; compacted first: 400000 -> 30000 tokens in "), line)
        // Its notice arrives as Claude comes back to the front and closes the panel: the next
        // opening still shows it.
        await h.engine.panelClosed()
        await h.engine.perform(.panelOpened)
        let reopened = await h.snapshot()
        XCTAssertTrue(reopened.banners.contains {
            if case .autoCompacted(let result) = $0 { return result.trigger == .beforeSwitch }
            return false
        })
        await h.cleanup()
    }

    func testARefusalOrAFailureSwitchesAnywayAndSaysSo() async throws {
        for (status, reason) in [("skipped", "a turn is running"), ("failed", "another conversation on this Mac was compacting")] {
            let h = try await EngineHarness()
            await h.start()
            try appendUsage(h, tokens: 400_000)
            try reportLive(h)
            let target = try h.folder("Claude_204")
            let (work, request) = try await switchUntilAsked(h, target: target)
            try answer(h, id: try XCTUnwrap(request["id"] as? Int), status: status, error: reason)
            h.clock.release()
            await work.value
            let snapshot = await h.snapshot()
            XCTAssertEqual(snapshot.lastResult?.outcome, .switched(to: target, warnings: [.notCompactedFirst]), status)
            let line = try switchLine(h)
            XCTAssertTrue(line.contains("; not compacted first (400000 tokens): \(status) after "), line)
            XCTAssertTrue(line.contains(reason), line)
            await h.cleanup()
        }
    }

    func testSkippingEndsTheWaitAndSwitchesWithoutALine() async throws {
        let h = try await EngineHarness()
        await h.start()
        try appendUsage(h, tokens: 400_000)
        try reportLive(h)
        let target = try h.folder("Claude_204")
        let (work, _) = try await switchUntilAsked(h, target: target)
        await h.engine.perform(.skipCompaction)
        h.clock.release()
        await work.value
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .switched(to: target, warnings: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestFile(h).path))
        let line = try switchLine(h)
        XCTAssertTrue(line.contains("; compaction first skipped by the user after "), line)
        XCTAssertTrue(line.contains("(400000 tokens)"), line)
        await h.cleanup()
    }

    func testWithoutAnAnswerInThreeMinutesItSwitchesAnywayAndSaysSo() async throws {
        let h = try await EngineHarness()
        await h.start()
        try appendUsage(h, tokens: 400_000)
        try reportLive(h)
        // The answer to an earlier request does not count for this one.
        try answer(h, id: 1, status: "compacted", tokensAfter: 30_000)
        let target = try h.folder("Claude_204")
        let started = h.clock.now()
        await h.engine.perform(.switchTo(folder: target))
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .switched(to: target, warnings: [.notCompactedFirst]))
        XCTAssertGreaterThanOrEqual(h.clock.now().timeIntervalSince(started), SwitchCoordinator.compactionLimit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestFile(h).path))
        let line = try switchLine(h)
        XCTAssertTrue(line.contains("; not compacted first (400000 tokens): no answer in 180.0 s"), line)
        // The wait is reported apart from the switch's own time.
        let own = try XCTUnwrap(line.range(of: #"(?<=switched in )[0-9.]+"#, options: .regularExpression))
        XCTAssertLessThan(try XCTUnwrap(Double(line[own])), 60, line)
        await h.cleanup()
    }

    func testACompactionThatHasBegunIsWaitedForPastTheThreeMinutes() async throws {
        let h = try await EngineHarness()
        await h.start()
        try appendUsage(h, tokens: 400_000)
        try reportLive(h)
        let target = try h.folder("Claude_204")
        let started = h.clock.now()
        let (work, request) = try await switchUntilAsked(h, target: target)
        let id = try XCTUnwrap(request["id"] as? Int)
        // The plugin's /compact has begun, and a long one is still running five minutes in.
        try answer(h, id: id, status: "compacting")
        h.clock.release(holdingAgainAt: started.addingTimeInterval(300))
        let fiveMinutesIn = await eventually { h.clock.waitingSleeps() == 1 }
        XCTAssertTrue(fiveMinutesIn)
        // Claude is still open under it, and the panel still offers to skip.
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        let waiting = await h.snapshot()
        XCTAssertEqual(waiting.operation, .switching(target: target, step: .compactingConversation, completedSteps: []))
        try answer(h, id: id, status: "compacted", tokensAfter: 30_000)
        h.clock.release()
        await work.value
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .switched(to: target, warnings: []))
        let line = try switchLine(h)
        XCTAssertTrue(line.contains("; compacted first: 400000 -> 30000 tokens in "), line)
        await h.cleanup()
    }

    func testACompactionThatHasBegunButNeverEndsIsLeftAfterTenMinutesAndSaysSo() async throws {
        let h = try await EngineHarness()
        await h.start()
        try appendUsage(h, tokens: 400_000)
        try reportLive(h)
        let target = try h.folder("Claude_204")
        let started = h.clock.now()
        let (work, request) = try await switchUntilAsked(h, target: target)
        try answer(h, id: try XCTUnwrap(request["id"] as? Int), status: "compacting")
        h.clock.release()
        await work.value
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .switched(to: target, warnings: [.notCompactedFirst]))
        XCTAssertGreaterThanOrEqual(h.clock.now().timeIntervalSince(started), SwitchCoordinator.compactionRunLimit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestFile(h).path))
        let line = try switchLine(h)
        XCTAssertTrue(line.contains("; not compacted first (400000 tokens): still compacting after "), line)
        await h.cleanup()
    }

    func testATaskBegunDuringTheWaitIsAskedAboutBeforeClaudeCloses() async throws {
        let h = try await EngineHarness()
        await h.start()
        try appendUsage(h, tokens: 400_000)
        try reportLive(h)
        let target = try h.folder("Claude_204")
        let (work, request) = try await switchUntilAsked(h, target: target)
        // While the switch waits, a Code task starts in another conversation.
        h.inspector.enqueue(.busy([CodeTaskInfo(pid: 3, reason: .statusBusy)]))
        try answer(h, id: try XCTUnwrap(request["id"] as? Int), status: "compacted", tokensAfter: 30_000)
        h.clock.release()
        let asked = await eventually { await h.snapshot().taskGuardPrompt != nil }
        XCTAssertTrue(asked)
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        await h.engine.perform(.taskGuard(.cancel))
        await work.value
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .switchTo(target), reason: .cancelled))
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        let line = try switchLine(h)
        XCTAssertTrue(line.contains("Switch Claude -> Claude_204: cancelled at the task check after "), line)
        await h.cleanup()
    }

    func testAShorterConversationGoesStraightOnAndOneNoPluginCanBeAskedForSaysSo() async throws {
        let unreported = "the plugin does not report this conversation"
        let cases: [(tokens: Int, reportAge: TimeInterval?, answers: Bool, why: String?)] = [
            (299_999, 0, true, nil),
            (300_000, nil, true, unreported),
            (300_000, AutoCompactLink.liveInterval + 1, true, unreported),
            // A plugin from before requests at a switch reports, but would leave the switch waiting.
            (300_000, 0, false, "the plugin in this conversation is too old to ask"),
        ]
        for item in cases {
            let h = try await EngineHarness()
            await h.start()
            try appendUsage(h, tokens: item.tokens)
            if let age = item.reportAge { try reportLive(h, at: h.clock.now().addingTimeInterval(-age), answers: item.answers) }
            let target = try h.folder("Claude_204")
            let started = h.clock.now()
            await h.engine.perform(.switchTo(folder: target))
            let snapshot = await h.snapshot()
            XCTAssertEqual(snapshot.lastResult?.outcome,
                           .switched(to: target, warnings: item.why == nil ? [] : [.notCompactedFirst]), "\(item)")
            XCTAssertLessThan(h.clock.now().timeIntervalSince(started), 60, "\(item)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: requestFile(h).path), "\(item)")
            let line = try switchLine(h)
            if let why = item.why {
                XCTAssertTrue(line.contains("; not compacted first (300000 tokens): \(why)"), line)
            } else {
                XCTAssertFalse(line.contains("compact"), line)
            }
            await h.cleanup()
        }
    }

    func testNothingIsAskedWhenTheSwitchIsOffClaudeIsClosedOrTheUserSwitchesNow() async throws {
        let off = try await EngineHarness()
        await off.start()
        await off.engine.perform(.setAutoCompact(false))
        try appendUsage(off, tokens: 400_000)
        try reportLive(off)
        await off.engine.perform(.switchTo(folder: try off.folder("Claude_204")))
        try await expectNoCompaction(off)
        await off.cleanup()

        let closed = try await EngineHarness(running: [])
        await closed.start()
        try appendUsage(closed, tokens: 400_000)
        try reportLive(closed)
        await closed.engine.perform(.switchTo(folder: try closed.folder("Claude_204")))
        try await expectNoCompaction(closed)
        await closed.cleanup()

        // Switching now cuts the running task short anyway.
        let now = try await EngineHarness()
        await now.start()
        try appendUsage(now, tokens: 400_000)
        try reportLive(now)
        now.inspector.enqueue(.busy([CodeTaskInfo(pid: 2, reason: .statusBusy)]))
        let target = try now.folder("Claude_204")
        let work = Task { await now.engine.perform(.switchTo(folder: target)) }
        let shown = await eventually { await now.snapshot().taskGuardPrompt != nil }
        XCTAssertTrue(shown)
        await now.engine.perform(.taskGuard(.switchNow))
        await work.value
        try await expectNoCompaction(now)
        await now.cleanup()
    }

    func testQuittingDuringTheWaitCallsTheSwitchOffAndLeavesClaudeAsItWas() async throws {
        let h = try await EngineHarness()
        await h.start()
        try appendUsage(h, tokens: 400_000)
        try reportLive(h)
        let target = try h.folder("Claude_204")
        let (work, _) = try await switchUntilAsked(h, target: target)
        let quit = Task { await h.engine.perform(.quitApp) }
        // The quit's own wait sleeps on the held clock too, so once it waits it has called the switch off.
        let quitting = await eventually { h.clock.waitingSleeps() == 2 }
        XCTAssertTrue(quitting)
        h.clock.release()
        await work.value
        await quit.value
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .failed(operation: .switchTo(target), reason: .cancelled))
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        XCTAssertTrue(h.process.recordedLaunches().isEmpty)
        // Called off, not timed out: a wait that ran out would go on to close Claude.
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestFile(h).path))
        let line = try switchLine(h)
        XCTAssertTrue(line.contains("Switch Claude -> Claude_204: cancelled while compacting first after "), line)
        await h.cleanup()
    }

    func testASkipOutsideAWaitDoesNotCutTheNextOneShortAndQuittingEndsEveryWait() async {
        let wait = CompactionWait()
        await wait.skip()
        await wait.begin()
        var interruption = await wait.interruption
        XCTAssertNil(interruption)
        await wait.skip()
        interruption = await wait.interruption
        XCTAssertEqual(interruption, .skipped)
        await wait.end()
        await wait.skip()
        await wait.begin()
        interruption = await wait.interruption
        XCTAssertNil(interruption)
        await wait.cancelAll()
        await wait.skip()
        interruption = await wait.interruption
        XCTAssertEqual(interruption, .cancelled)
        await wait.end()
        await wait.begin()
        interruption = await wait.interruption
        XCTAssertEqual(interruption, .cancelled)
    }

    /// Starts the switch with the clock held five seconds into the wait, and returns once the
    /// request is there and the target card says so. The caller answers, then releases the clock.
    private func switchUntilAsked(_ h: EngineHarness, target: ProfileFolder) async throws -> (Task<Void, Never>, [String: Any]) {
        h.clock.hold(at: h.clock.now().addingTimeInterval(5))
        let work = Task { await h.engine.perform(.switchTo(folder: target)) }
        let asked = await eventually {
            await h.snapshot().operation == .switching(target: target, step: .compactingConversation, completedSteps: [])
        }
        guard asked else {
            h.clock.release()
            await work.value
            throw NeverAsked()
        }
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(requestFile(h))) as? [String: Any])
        return (work, request)
    }

    private struct NeverAsked: Error {}

    private func expectNoCompaction(_ h: EngineHarness, file: StaticString = #filePath, line: UInt = #line) async throws {
        let snapshot = await h.snapshot()
        guard case .switched(_, let warnings) = snapshot.lastResult?.outcome else {
            return XCTFail("expected a switch", file: file, line: line)
        }
        XCTAssertFalse(warnings.contains(.notCompactedFirst), file: file, line: line)
        let entry = try switchLine(h)
        XCTAssertFalse(entry.contains("compact"), entry, file: file, line: line)
    }

    private func switchLine(_ h: EngineHarness) throws -> String {
        try XCTUnwrap(h.logLines(containing: "Switch Claude -> Claude_204").last)
    }

    private func directory(_ h: EngineHarness) -> URL { AutoCompactLink(paths: h.world.paths).directory }
    private func requestFile(_ h: EngineHarness) -> URL { directory(h).appending(path: "switch-request.json") }

    /// The conversation's plugin reporting, as it does every half minute; `answers` is false for a
    /// plugin from before requests at a switch.
    private func reportLive(_ h: EngineHarness, at date: Date? = nil, answers: Bool = true) throws {
        var report: [String: Any] = ["sessionID": session, "updatedAt": Int64((date ?? h.clock.now()).timeIntervalSince1970 * 1000)]
        if answers { report["switchRequests"] = true }
        try AtomicFile.write(JSONSerialization.data(withJSONObject: report), to: directory(h).appending(path: "sessions/\(session).json"))
    }

    private func answer(_ h: EngineHarness, id: Int, status: String, tokensAfter: Int? = nil, error: String? = nil) throws {
        var fields: [String: Any] = ["id": id, "sessionID": session, "status": status, "tokensBefore": 400_000]
        fields["tokensAfter"] = tokensAfter
        fields["error"] = error
        try AtomicFile.write(JSONSerialization.data(withJSONObject: fields), to: directory(h).appending(path: "switch-result.json"))
    }

    private func appendUsage(_ h: EngineHarness, tokens: Int) throws {
        let transcript = try XCTUnwrap(h.world.cliSessions.first { $0.cliSessionID == session }?.transcriptFile)
        var contents = try AtomicFile.read(transcript)
        contents.append(10)
        contents.append(try JSONSerialization.data(withJSONObject: ["type": "assistant",
            "sessionId": session, "message": ["usage": ["cache_read_input_tokens": tokens - 100, "output_tokens": 100]]]))
        try AtomicFile.write(contents, to: transcript)
    }
}
