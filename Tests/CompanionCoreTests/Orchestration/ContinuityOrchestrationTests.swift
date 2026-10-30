import Foundation
import XCTest
@testable import CompanionCore

@MainActor
final class ContinuityOrchestrationTests: XCTestCase {
    func testColdLaunchOfRememberedAccountStillRequestsItsConversation() async throws {
        let h = try await EngineHarness(running: [])
        await h.start()
        await h.engine.perform(.switchTo(folder: try h.folder("Claude")))
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        XCTAssertNotNil(h.process.recordedLaunches().first?.deepLink)
        await h.cleanup()
    }

    func testConfirmedConversationReportsSwitchBeforeBackgroundConfirmation() async throws {
        let h = try await EngineHarness()
        await h.start()
        let target = try h.profile("Claude_204")
        let file = try h.sessionFile(target, id: "local_" + SandboxFixture.ID.liveSession)
        h.process.onLaunch { _, deepLink in
            guard deepLink != nil else { return }
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
            record["lastFocusedAt"] = Int(h.clock.now().timeIntervalSince1970 * 1000) + 1
            try AtomicFile.write(JSONSerialization.data(withJSONObject: record), to: file)
        }
        await h.engine.perform(.switchTo(folder: target.folder))
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.outcome, .switched(to: target.folder, warnings: []))
        XCTAssertNotNil(h.process.recordedLaunches().first?.deepLink)
        await h.cleanup()
    }

    func testConfirmationTimeoutUpgradesSameResultWithoutRelaunch() async throws {
        let h = try await EngineHarness()
        await h.start()
        let target = try h.folder("Claude_204")
        await h.engine.perform(.switchTo(folder: target))
        let resultID = await h.snapshot().lastResult?.id
        let warned = await eventually {
            guard case .switched(_, let warnings) = await h.snapshot().lastResult?.outcome else { return false }
            return warnings.contains(.conversationNotReopened)
        }
        XCTAssertTrue(warned)
        let snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.lastResult?.id, resultID)
        XCTAssertEqual(h.process.recordedLaunches().count, 1)
        await h.cleanup()
    }

    func testAReminderAfterTheSuccessNoticeClosedIsShownOnItsOwn() async throws {
        let h = try await EngineHarness()
        await h.start()
        let target = try h.folder("Claude_204")
        await h.engine.perform(.switchTo(folder: target))
        let switched = await h.snapshot().lastResult?.id
        let first = try XCTUnwrap(switched)
        // The panel closes a clean success notice after two seconds; the check takes up to 90.
        await h.engine.perform(.dismissResult(id: first))
        let warned = await eventually {
            guard case .switched(let folder, let warnings) = await h.snapshot().lastResult?.outcome else { return false }
            return folder == target && warnings == [.conversationNotReopened]
        }
        XCTAssertTrue(warned)
        let shown = await h.snapshot().lastResult?.id
        XCTAssertNotEqual(shown, first)
        XCTAssertEqual(h.process.recordedLaunches().count, 1)
        await h.cleanup()
    }

    func testEachTargetValidationFailureIsOnlyAWarning() async throws {
        let mutations: [@Sendable (EngineHarness) throws -> Void] = [
            { h in
                let target = try h.profile("Claude_204")
                try FileManager.default.removeItem(at: h.sessionFile(target, id: "local_" + SandboxFixture.ID.liveSession))
            },
            { h in try Self.mutateTarget(h) { $0["cliSessionId"] = "different" } },
            { h in try Self.mutateTarget(h) { $0["isArchived"] = true } },
            { h in try Self.mutateTarget(h) { $0["cwd"] = "/nonexistent/project" } },
            { h in try Self.mutateTarget(h) { $0["transcriptUnavailable"] = true } },
            { h in
                for record in h.world.cliSessions where record.cliSessionID == SandboxFixture.ID.liveSession {
                    try FileManager.default.removeItem(at: record.transcriptFile)
                }
            }
        ]
        for mutation in mutations {
            let h = try await EngineHarness(autoSync: false)
            let source = try h.profile("Claude"), target = try h.profile("Claude_204")
            let sourceFile = try h.sessionFile(source, id: "local_" + SandboxFixture.ID.liveSession)
            try AtomicFile.write(AtomicFile.read(sourceFile), to: h.sessionFile(target, id: "local_" + SandboxFixture.ID.liveSession))
            try mutation(h)
            await h.start()
            await h.engine.perform(.switchTo(folder: target.folder))
            let snapshot = await h.snapshot()
            guard case .switched(_, let warnings) = snapshot.lastResult?.outcome else { XCTFail("expected completed switch"); await h.cleanup(); continue }
            XCTAssertTrue(warnings.contains(.conversationNotReopened))
            XCTAssertNil(h.process.recordedLaunches().first?.deepLink)
            await h.cleanup()
        }
    }

    private nonisolated static func mutateTarget(_ h: EngineHarness, body: (inout [String: Any]) -> Void) throws {
        let file = try h.sessionFile(h.profile("Claude_204"), id: "local_" + SandboxFixture.ID.liveSession)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
        body(&record)
        try AtomicFile.write(JSONSerialization.data(withJSONObject: record), to: file)
    }
}
