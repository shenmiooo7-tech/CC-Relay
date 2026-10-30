import Foundation
import XCTest
import CompanionCore
@testable import CompanionUI

@MainActor
final class AccountRecoveryUITests: XCTestCase {
    func testTheCurrentSignedOutAccountCanRequestSignIn() async throws {
        var snapshot = PanelFixtures.mainSnapshot()
        let current = try XCTUnwrap(snapshot.currentFolder)
        let index = try XCTUnwrap(snapshot.accounts.firstIndex { $0.folder == current })
        snapshot.accounts[index].status = .signedOut
        snapshot.claudeRunning = false
        let facade = FakeCompanionFacade(snapshot: snapshot)
        let model = try await makeModel(facade)
        await model.select(current.name)
        XCTAssertEqual(facade.recordedActions(), [.switchTo(folder: current)])
    }

    func testSettingsListDismissedAccountsAndAddBackRegistersOnlyListedOnes() async throws {
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.ignoredFolders = [try ProfileFolder("Claude_206")]
        let facade = FakeCompanionFacade(snapshot: snapshot)
        let model = try await makeModel(facade)
        XCTAssertEqual(model.state.settings.ignoredAccounts, [IgnoredAccountRow(id: "Claude_206", name: "Claude_206")])
        await model.addIgnoredAccount("Claude_other")
        await model.addIgnoredAccount("Claude_206")
        XCTAssertEqual(facade.recordedActions(), [.addFoundAccount(folder: try ProfileFolder("Claude_206"))])

        let plain = try await makeModel(FakeCompanionFacade(snapshot: PanelFixtures.mainSnapshot()))
        XCTAssertTrue(plain.state.settings.ignoredAccounts.isEmpty)
    }

    private func makeModel(_ facade: any CompanionFacade) async throws -> PanelViewModel {
        let model = PanelViewModel(facade: facade, clock: ManualClock(now: PanelFixtures.now),
                                   timeZone: PanelFixtures.timeZone, preferredLanguages: ["zh-Hans"])
        let applied = await model.waitUntilApplied()
        XCTAssertTrue(applied)
        return model
    }
}
