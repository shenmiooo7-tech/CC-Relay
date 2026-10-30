import Foundation
import XCTest
@testable import CompanionCore

/// The current account follows Claude, and a dismissed account can return.
@MainActor
final class AccountTrackingTests: XCTestCase {
    // MARK: Following what Claude has open

    func testFollowingKeepsAnOpenCurrentAccountAndPicksTheNewestFlaggedLaunch() throws {
        let root = URL(fileURLWithPath: "/profiles")
        func directory(_ folder: ProfileFolder) -> URL { root.appending(path: folder.name) }
        func instance(_ name: String, flag: Bool = true, at seconds: TimeInterval) -> ClaudeInstance {
            ClaudeInstance(pid: Int32(seconds), profileDirectory: root.appending(path: name), hasExplicitProfileFlag: flag,
                           startedAt: Date(timeIntervalSince1970: seconds), executableURL: URL(fileURLWithPath: "/Claude"))
        }
        let accounts = try ["Claude", "Claude_204", "Claude_206"].map {
            ManagedAccount(folder: try ProfileFolder($0), displayName: $0, addedAt: Date(timeIntervalSince1970: 0))
        }
        let current = try ProfileFolder("Claude_204")
        func follow(_ running: [ClaudeInstance], flaglessCounts: Bool = false) -> String? {
            AccountFollowing.account(open: running, accounts: accounts, active: current,
                                     flaglessCounts: flaglessCounts, directory: directory)?.name
        }
        XCTAssertNil(follow([instance("Claude_204", at: 1), instance("Claude_206", at: 2)]))
        XCTAssertEqual(follow([instance("Claude_206", at: 2)]), "Claude_206")
        XCTAssertEqual(follow([instance("Claude", at: 3), instance("Claude_206", at: 2)]), "Claude")
        XCTAssertNil(follow([instance("Claude_unmanaged", at: 4)]))
        XCTAssertNil(follow([]))
        // A Dock launch of the default account belongs to auto-correct while it is on.
        XCTAssertNil(follow([instance("Claude", flag: false, at: 5)]))
        XCTAssertEqual(follow([instance("Claude", flag: false, at: 5)], flaglessCounts: true), "Claude")
        // The current account opened from the Dock still counts as open.
        XCTAssertNil(AccountFollowing.account(open: [instance("Claude", flag: false, at: 5), instance("Claude_206", at: 6)],
                                              accounts: accounts, active: try ProfileFolder("Claude"),
                                              flaglessCounts: false, directory: directory))
    }

    func testCurrentAccountFollowsASwitchMadeWithoutThisApp() async throws {
        let h = try await EngineHarness(active: "Claude", running: ["Claude_204"])
        await h.start()
        var snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.currentFolder?.name, "Claude_204")
        var state = try await h.store.load()
        XCTAssertEqual(state.activeFolder?.name, "Claude_204")

        // Another tool opens 208 later: its flagged launch moves the current account without waiting for a scan.
        h.process.setInstances([instance(h, "Claude_Kxm8")])
        await h.engine.handleLaunch(LaunchEvent(pid: 30, profileDirectory: h.world.profileDirectory("Claude_Kxm8"),
                                                hasExplicitProfileFlag: true))
        snapshot = await h.snapshot()
        XCTAssertEqual(snapshot.currentFolder?.name, "Claude_Kxm8")
        state = try await h.store.load()
        XCTAssertEqual(state.activeFolder?.name, "Claude_Kxm8")
        XCTAssertTrue(h.process.recordedQuitTimeouts().isEmpty)
        await h.cleanup()
    }

    func testNothingOpenOrOnlyAnUnmanagedProfileKeepsTheCurrentAccount() async throws {
        let h = try await EngineHarness(active: "Claude_204", running: [])
        await h.start()
        var state = try await h.store.load()
        XCTAssertEqual(state.activeFolder?.name, "Claude_204")
        try h.writeSignIn(folder: h.folder("Claude_206"))
        h.process.setInstances([instance(h, "Claude_206")])
        await h.engine.perform(.panelOpened)
        state = try await h.store.load()
        XCTAssertEqual(state.activeFolder?.name, "Claude_204")
        await h.cleanup()
    }

    // MARK: Dismissed accounts

    func testDismissedAccountIsListedReturnsWhileOpenAndCanBeAddedBack() async throws {
        let h = try await EngineHarness(running: ["Claude"])
        await h.start()
        let found = try h.folder("Claude_206")
        try h.writeSignIn(folder: found)
        await h.engine.perform(.panelOpened)
        var snapshot = await h.snapshot()
        XCTAssertTrue(snapshot.banners.contains(.foundAccount(folder: found)))
        XCTAssertTrue(snapshot.ignoredFolders.isEmpty)

        await h.engine.perform(.dismissFoundAccount(folder: found))
        snapshot = await h.snapshot()
        XCTAssertFalse(snapshot.banners.contains(.foundAccount(folder: found)))
        XCTAssertEqual(snapshot.ignoredFolders, [found])

        // Claude now has the dismissed account open: offer it again. It is not current, since it is not managed.
        h.process.setInstances([instance(h, "Claude_206")])
        await h.engine.perform(.panelOpened)
        snapshot = await h.snapshot()
        XCTAssertTrue(snapshot.banners.contains(.foundAccount(folder: found)))
        XCTAssertEqual(snapshot.currentFolder?.name, "Claude")

        // Dismissed again while open, it stays away until Claude closes it, then returns the next time it opens.
        await h.engine.perform(.dismissFoundAccount(folder: found))
        snapshot = await h.snapshot()
        XCTAssertFalse(snapshot.banners.contains(.foundAccount(folder: found)))
        await h.engine.perform(.panelOpened)
        snapshot = await h.snapshot()
        XCTAssertFalse(snapshot.banners.contains(.foundAccount(folder: found)))
        h.process.setInstances([])
        await h.engine.perform(.panelOpened)
        h.process.setInstances([instance(h, "Claude_206")])
        await h.engine.perform(.panelOpened)
        snapshot = await h.snapshot()
        XCTAssertTrue(snapshot.banners.contains(.foundAccount(folder: found)))

        await h.engine.perform(.addFoundAccount(folder: found))
        snapshot = await h.snapshot()
        XCTAssertTrue(snapshot.ignoredFolders.isEmpty)
        XCTAssertTrue(snapshot.accounts.contains { $0.folder == found })
        // Added and open, it is now the account Claude shows.
        XCTAssertEqual(snapshot.currentFolder, found)
        await h.cleanup()
    }

    private func instance(_ h: EngineHarness, _ name: String) -> ClaudeInstance {
        ClaudeInstance(pid: 40, profileDirectory: h.world.profileDirectory(name), hasExplicitProfileFlag: true,
                       startedAt: h.clock.now(), executableURL: h.world.paths.claudeAppPath)
    }
}
