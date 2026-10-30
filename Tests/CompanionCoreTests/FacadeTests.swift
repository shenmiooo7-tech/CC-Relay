import XCTest
@testable import CompanionCore

final class FacadeTests: XCTestCase {
    func testFakeRecordsActionsAndPushesSnapshots() async throws {
        let facade = FakeCompanionFacade()
        let stream = facade.snapshots()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .empty())

        let folder = try ProfileFolder("Claude_Kxm2")
        var updated = CompanionSnapshot.empty()
        updated.claudeRunning = true
        updated.currentFolder = folder
        updated.banners = [.historyImportPaused(folder: folder, issue: .interrupted)]
        facade.push(updated)
        let second = await iterator.next()
        XCTAssertEqual(second, updated)

        await facade.perform(.addAccount)
        await facade.perform(.switchTo(folder: folder))
        await facade.perform(.refreshQuota(folder: nil))
        XCTAssertEqual(
            facade.recordedActions(),
            [.addAccount, .switchTo(folder: folder), .refreshQuota(folder: nil)]
        )
    }

    func testUtilityReceiptsAreExplicitAndIndependentOfSnapshots() async {
        let facade = FakeCompanionFacade()
        facade.enqueueReceipt(.quotaRefresh(updated: 1, requested: 3))
        facade.enqueueReceipt(.failed)
        let refresh = await facade.performWithReceipt(.refreshQuota(folder: nil))
        let backups = await facade.performWithReceipt(.openBackupsFolder)
        let unscripted = await facade.performWithReceipt(.openBackupsFolder)
        XCTAssertEqual(refresh, .quotaRefresh(updated: 1, requested: 3))
        XCTAssertEqual(backups, .failed)
        XCTAssertEqual(unscripted, .unreported)
        XCTAssertEqual(facade.recordedActions(), [.refreshQuota(folder: nil), .openBackupsFolder, .openBackupsFolder])
    }

    func testSwitchImprovementResultsRoundTrip() throws {
        let folder = try ProfileFolder("Claude_Kxm2")
        let finishedAt = Date(timeIntervalSince1970: 1_792_832_402)
        let results = [
            OperationResult(id: UUID(), finishedAt: finishedAt,
                            outcome: .switched(to: folder, warnings: [.notCompactedFirst])),
            OperationResult(id: UUID(), finishedAt: finishedAt,
                            outcome: .failed(operation: .switchTo(folder), reason: .returnedToPreviousAccount)),
        ]
        for result in results {
            XCTAssertEqual(try StableJSON.decode(OperationResult.self, from: StableJSON.encode(result)), result)
        }
    }

    func testSnapshotAndActionRoundTrip() async throws {
        let folder = try ProfileFolder("Claude")
        let other = try ProfileFolder("Claude_204")
        let resultID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let snapshot = CompanionSnapshot(
            accounts: [
                AccountSummary(
                    folder: folder,
                    displayName: "201",
                    status: .signedIn,
                    email: "ada@example.com",
                    plan: "Pro",
                    channel: .appStore,
                    quotaFreshness: .fresh,
                    duplicateOf: other
                ),
            ],
            currentFolder: folder,
            claudeRunning: true,
            operation: .switching(target: other, step: .syncingSessions, completedSteps: [.closingClaude]),
            lastResult: OperationResult(
                id: resultID,
                finishedAt: Date(timeIntervalSince1970: 1_792_832_402.345),
                outcome: .failed(operation: .switchTo(other), reason: .couldNotOpenClaude)
            ),
            taskGuardPrompt: TaskGuardPrompt(target: other, busyCount: 1, unknown: false, isWaiting: true),
            banners: [.foundAccount(folder: other)],
            pendingAdd: PendingAddState(folder: other, phase: .waitingForSignIn),
            settings: Settings(language: .zhHans),
            appVersion: "0.1.0"
        )
        let decoded = try StableJSON.decode(CompanionSnapshot.self, from: StableJSON.encode(snapshot))
        XCTAssertEqual(decoded, snapshot)

        for action in [CompanionAction.rename(folder: other, name: "工作"), .openRecoveryFolder] {
            XCTAssertEqual(try StableJSON.decode(CompanionAction.self, from: StableJSON.encode(action)), action)
        }
    }
}
