import CompanionCore
import Foundation
import XCTest
@testable import CompanionPlatform

final class ClaudeLaunchEngineTests: XCTestCase {
    func testFailedLaunchWaitsForAnAsynchronousForcedExit() async throws {
        let world = LaunchWorld()
        world.edit { $0.exitsOnTerminate = false; $0.forceDelay = 2 }
        await XCTAssertLaunchError(world, .launchFailed)
        XCTAssertFalse(world.edit { $0.running })
        XCTAssertEqual(world.edit { $0.time }, 42)
    }

    func testUnconfirmedForcedExitReportsCleanupFailure() async throws {
        let world = LaunchWorld()
        world.edit { $0.exitsOnTerminate = false; $0.refusesForce = true }
        await XCTAssertLaunchError(world, .launchCleanupFailed)
        XCTAssertTrue(world.edit { $0.running })
        XCTAssertEqual(world.edit { $0.time }, 43)
    }

    func testVerifiedLaunchReturnsTheNewInstanceAndClosesNothing() async throws {
        let world = LaunchWorld()
        world.edit { $0.appearsWithFlag = true }
        let instance = try await world.engine.launch(profile: world.target, deepLink: nil)
        XCTAssertEqual(instance.pid, world.launchedPID)
        XCTAssertEqual(world.edit { $0.commands }, [])
    }

    func testTargetThatNeverAppearsIsClosedBeforeTheFailure() async throws {
        let world = LaunchWorld()
        await XCTAssertLaunchError(world, .launchFailed)
        XCTAssertEqual(world.edit { $0.commands }, ["terminate"])
        XCTAssertGreaterThanOrEqual(world.edit { $0.time }, 30)
    }

    func testTargetThatIgnoresTheQuitIsForcedAfterTheGrace() async throws {
        let world = LaunchWorld()
        world.edit { $0.exitsOnTerminate = false }
        await XCTAssertLaunchError(world, .launchFailed)
        XCTAssertEqual(world.edit { $0.commands }, ["terminate", "force"])
        XCTAssertGreaterThanOrEqual(world.edit { $0.time }, 40)
    }

    func testUnreadableProcessTableAfterTheOpenStillClosesIt() async throws {
        let world = LaunchWorld()
        world.edit { $0.tableFailsAfterOpen = true }
        await XCTAssertLaunchError(world, .processTableUnavailable)
        XCTAssertEqual(world.edit { $0.commands }, ["terminate"])
    }

    func testInstanceThatWasAlreadyRunningIsNeverClosed() async throws {
        let world = LaunchWorld()
        world.edit { $0.instances = [world.instance(pid: world.launchedPID, flag: true, profile: world.other)] }
        await XCTAssertLaunchError(world, .launchFailed)
        XCTAssertEqual(world.edit { $0.commands }, [])
    }

    func testInstanceWithoutTheProfileFlagIsNotTheTargetAndIsClosed() async throws {
        let world = LaunchWorld()
        world.edit { $0.appearsWithFlag = false }
        await XCTAssertLaunchError(world, .launchFailed)
        XCTAssertEqual(world.edit { $0.commands }, ["terminate"])
    }

    func testDeepLinkFailureFallsBackToAPlainOpen() async throws {
        let world = LaunchWorld()
        world.edit { $0.failingOpens = 1; $0.appearsWithFlag = true }
        let link = try XCTUnwrap(URL(string: "claude://code/continue?session=local_abc"))
        _ = try await world.engine.launch(profile: world.target, deepLink: link)
        XCTAssertEqual(world.edit { $0.opens }, [link, nil])

        let failing = LaunchWorld()
        failing.edit { $0.failingOpens = 2 }
        do {
            _ = try await failing.engine.launch(profile: failing.target, deepLink: link)
            XCTFail("expected a failure")
        } catch { XCTAssertEqual(error as? ClaudeProcessError, .launchFailed) }
        XCTAssertEqual(failing.edit { $0.commands }, [])
    }

    private func XCTAssertLaunchError(_ world: LaunchWorld, _ expected: ClaudeProcessError,
                                      file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await world.engine.launch(profile: world.target, deepLink: nil)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ClaudeProcessError, expected, file: file, line: line)
        }
    }
}

/// A process table, an opener and a clock in one place. Time moves only when the engine sleeps.
private final class LaunchWorld: CompanionCore.Clock, @unchecked Sendable {
    struct State {
        var time: Double = 0
        var instances: [ClaudeInstance] = []
        var opens: [URL?] = []
        var failingOpens = 0
        /// nil: the opened app never shows as a main instance.
        var appearsWithFlag: Bool?
        var tableFailsAfterOpen = false
        var opened = false
        var running = false
        var exitsOnTerminate = true
        var forceDelay: Double = 0
        var forceExitAt: Double?
        var refusesForce = false
        var commands: [String] = []
    }

    let launchedPID: Int32 = 500
    let target = URL(fileURLWithPath: "/profiles/Claude_204")
    let other = URL(fileURLWithPath: "/profiles/Claude")
    private let lock = NSLock()
    private var state = State()

    var engine: ClaudeLaunchEngine {
        ClaudeLaunchEngine(open: { link in try self.open(link) }, instances: { try self.table() },
                           polling: AdapterPolling(clock: self, interval: .seconds(1)))
    }

    func edit<T>(_ body: (inout State) throws -> T) rethrows -> T { try lock.withLock { try body(&state) } }
    func now() -> Date { Date(timeIntervalSince1970: edit { $0.time }) }
    func sleep(for duration: Duration) async throws {
        edit { state in
            state.time += duration.timeInterval
            if let exitAt = state.forceExitAt, state.time >= exitAt { state.running = false }
        }
    }

    func instance(pid: Int32, flag: Bool, profile: URL) -> ClaudeInstance {
        ClaudeInstance(pid: pid, profileDirectory: profile, hasExplicitProfileFlag: flag,
                       startedAt: Date(timeIntervalSince1970: 1),
                       executableURL: URL(fileURLWithPath: "/fixture/Claude.app/Contents/MacOS/Claude"))
    }

    private func open(_ link: URL?) throws -> LaunchedApp {
        try edit { state in
            state.opens.append(link)
            if state.failingOpens > 0 { state.failingOpens -= 1; throw ClaudeProcessError.launchFailed }
            state.opened = true
            state.running = true
            if let flag = state.appearsWithFlag {
                state.instances.append(instance(pid: launchedPID, flag: flag, profile: target))
            }
        }
        let pid = launchedPID
        return LaunchedApp(
            pid: pid,
            isTerminated: { self.edit { !$0.running } },
            terminate: { self.edit { state in
                state.commands.append("terminate")
                if state.exitsOnTerminate { state.running = false }
            } },
            forceTerminate: { self.edit { state in
                state.commands.append("force")
                if !state.refusesForce {
                    if state.forceDelay == 0 { state.running = false }
                    else { state.forceExitAt = state.time + state.forceDelay }
                }
            } })
    }

    private func table() throws -> [ClaudeInstance] {
        try edit { state in
            if state.opened && state.tableFailsAfterOpen { throw ClaudeProcessError.processTableUnavailable }
            return state.instances
        }
    }
}
