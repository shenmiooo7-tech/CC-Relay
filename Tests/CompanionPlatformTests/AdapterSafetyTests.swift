import CompanionCore
import Foundation
import XCTest
import CompanionPlatform

@MainActor
final class AdapterSafetyTests: XCTestCase {
    private func assertRefused(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Live action escaped the tripwire", file: file, line: line) }
        catch { XCTAssertTrue(error is SafetyRefusal, "\(type(of: error))", file: file, line: line) }
    }

    func testEveryThrowingLiveEntryPointRefusesBeforeAnyEffect() async throws {
        let directory = try PlatformTestDirectory()
        defer { directory.remove() }
        let paths = AppPaths.sandbox(root: directory.root)
        let process = LiveClaudeProcessController(paths: paths)
        await assertRefused { _ = try await process.runningInstances() }
        await assertRefused { _ = try await process.quitAll(timeout: .seconds(1)) }
        let instance = ClaudeInstance(pid: 1, profileDirectory: paths.claudeProfilesRoot.appendingPathComponent("Claude"),
            hasExplicitProfileFlag: false, startedAt: Date(), executableURL: paths.claudeAppURL.appendingPathComponent("Contents/MacOS/Claude"))
        await assertRefused { _ = try await process.quit(instance: instance, timeout: .seconds(1), beforeForce: { true }) }
        await assertRefused { _ = try await process.launch(profile: directory.root, deepLink: nil) }
        await assertRefused { _ = try await LiveSafeStorageKeyProvider().password() }
        await assertRefused { _ = try LiveSessionCookieReader().sessionCookie(profile: directory.root) }
        await assertRefused { _ = try await URLSessionHTTPTransport().send(HTTPRequest(method: "GET", url: URL(string: "https://fixture.invalid")!)) }
        let login = AppServiceLoginItem(paths: paths)
        await assertRefused { _ = try await login.isEnabled }
        await assertRefused { try await login.enable(executable: directory.root.appendingPathComponent("app")) }
        await assertRefused { try await login.disable() }
        await assertRefused { try await FinderRevealer().reveal(directory.root) }
        await assertRefused { _ = try ClaudeVersionReader(paths: paths).versions() }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.root.path), [])
    }

    func testNonthrowingLiveProtocolsFinishOrReturnUnknown() async throws {
        let directory = try PlatformTestDirectory()
        defer { directory.remove() }
        let paths = AppPaths.sandbox(root: directory.root)
        let activity = await LiveCodeTaskInspector(paths: paths).activity()
        XCTAssertEqual(activity, .unknown(TaskUnknownReason.processTableUnavailable))
        var iterator = LiveClaudeLaunchMonitor(paths: paths).launches().makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertNil(event)
    }
}
