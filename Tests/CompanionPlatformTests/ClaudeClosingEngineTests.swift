import CompanionCore
import Foundation
import XCTest
@testable import CompanionPlatform

final class ClaudeClosingEngineTests: XCTestCase, @unchecked Sendable {
    func testScopedClosePreservesOtherMainsAndTheirDescendants() async throws {
        let world = ClosingWorld()
        let selected = world.main(10)
        world.edit {
            $0.processes = [selected, world.helper(11, parent: 10), world.main(20), world.helper(21, parent: 20)]
            $0.arguments[10] = ["--user-data-dir=/profiles/a"]
            $0.arguments[20] = ["--user-data-dir=/profiles/b"]
            $0.normalExits = [10]
        }
        let instance = ClaudeInstance(pid: 10, profileDirectory: URL(fileURLWithPath: "/profiles/a"), hasExplicitProfileFlag: false,
            startedAt: selected.identity.startedAt, executableURL: selected.identity.executable)
        _ = try await world.engine.close(timeout: .seconds(28), instance: instance, beforeForce: { true })
        XCTAssertEqual(world.commands.map(\.pid), [10, 11])
        XCTAssertEqual(world.remainingPIDs, [20, 21])
    }

    func testScopedCloseRefusesAReusedIdentity() async throws {
        let world = ClosingWorld()
        world.edit { $0.processes = [world.main(10)] }
        let stale = ClaudeInstance(pid: 10, profileDirectory: URL(fileURLWithPath: "/profiles/a"), hasExplicitProfileFlag: false,
            startedAt: Date(timeIntervalSince1970: 999), executableURL: URL(fileURLWithPath: world.mainPath))
        let outcome = try await world.engine.close(timeout: .seconds(28), instance: stale, beforeForce: { true })
        XCTAssertEqual(outcome, .alreadyStopped)
        XCTAssertTrue(world.commands.isEmpty)
    }

    func testSelectionIncludesBundleRootsAndAllDescendantsButNotZombiesOrUnrelatedProcesses() async throws {
        let world = ClosingWorld()
        world.edit {
            $0.processes = [world.main(10), world.helper(11, parent: 1),
                           world.outside(12, parent: 11), world.outside(13, parent: 12),
                           world.outside(14, parent: 1), world.helper(15, parent: 1, zombie: true),
                           world.outside(16, parent: 15), world.process(17, parent: 1, path: "/fixture/Claude.app/Contents-other/helper")]
            $0.arguments[11] = ["--user-data-dir", "/profiles/b"]
        }
        let outcome = try await world.engine.close(timeout: .seconds(28), beforeForce: { true })
        XCTAssertEqual(outcome, .quitAfterForce)
        XCTAssertEqual(world.commands.map(\.pid), [10, 10, 10, 11, 12, 13])
        XCTAssertEqual(world.commands.map(\.kind), [.normal, .term, .force, .force, .force, .force])
        XCTAssertEqual(world.remainingPIDs, [14, 15, 16, 17])
        XCTAssertEqual(world.commands.filter { $0.kind == .term }.map(\.time), [20])
        XCTAssertEqual(world.commands.filter { $0.kind == .force }.map(\.time), [25, 25, 25, 25])
    }

    func testAttributionUsesBothFlagsDefaultCrashpadAndNearestAncestor() async throws {
        let world = ClosingWorld()
        world.edit {
            $0.processes = [world.main(10), world.main(20),
                           world.helper(30, parent: 1), world.outside(31, parent: 30),
                           world.main(40), world.helper(41, parent: 40),
                           world.outside(42, parent: 41)]
            $0.arguments[10] = ["--user-data-dir=/profiles/a"]
            $0.arguments[20] = []
            $0.arguments[30] = ["--database=/profiles/crash/Crashpad"]
            $0.arguments[40] = ["--user-data-dir", "/profiles/stays"]
            $0.arguments[41] = ["--user-data-dir", "/profiles/helper"]
            $0.normalExits = [10, 20]
            $0.onSleep = { state in state.processes.removeAll { [30, 31, 41].contains($0.identity.pid) } }
        }
        let error = await failure(world, beforeForce: { false })
        XCTAssertEqual(error, .stillRunning(pids: [40, 42], closedProfiles: world.profiles("a", "crash", "default"),
                                               names: ["Claude", "worker"], stall: .notForced))
        XCTAssertFalse(world.commands.contains { $0.kind == .force })
    }

    func testAnUnattributableSurvivorPreventsPartialRecovery() async throws {
        let world = ClosingWorld()
        world.edit {
            $0.processes = [world.main(10), world.helper(11, parent: 1)]
            $0.arguments[10] = ["--user-data-dir=/profiles/a"]
            $0.normalExits = [10]
        }
        let error = await failure(world, beforeForce: { false })
        XCTAssertEqual(error, .stillRunning(pids: [11], closedProfiles: [], names: ["helper"], stall: .notForced))
    }

    func testUnreadableOrMalformedMainArgumentsDoNotImplyDefaultProfile() async throws {
        for arguments: [String]? in [nil, ["--user-data-dir="]] {
            let world = ClosingWorld()
            world.edit {
                $0.processes = [world.main(10), world.main(20)]
                $0.arguments[10] = ["--user-data-dir=/profiles/a"]
                $0.arguments[20] = arguments
                if arguments == nil { $0.unreadableArguments = [20] }
                $0.normalExits = [10]
            }
            let error = await failure(world, beforeForce: { false })
            XCTAssertEqual(error, .stillRunning(pids: [20], closedProfiles: [], names: ["Claude"], stall: .notForced))
        }
    }

    func testIdentityIsRecheckedBeforeNormalTermAndForceRequests() async throws {
        for phase: ClosingWorld.Command.Kind in [.normal, .term, .force] {
            for changeExecutable in [false, true] {
                let world = ClosingWorld()
                world.edit {
                    $0.processes = [world.main(10), world.main(20)]
                    $0.onRead = { state in
                        let threshold: Double = phase == .normal ? 0 : phase == .term ? 20 : 25
                        // Each phase reads once in poll, then again immediately before a request.
                        let trigger = phase == .normal ? state.reads == 2 : state.time == threshold && state.readsAtTime == 2
                        guard trigger else { return }
                        state.processes.removeAll { $0.identity.pid == 10 }
                        state.processes.append(world.process(10, parent: 1,
                            path: changeExecutable ? "/elsewhere/replacement" : world.mainPath,
                            startedAt: Date(timeIntervalSince1970: 2)))
                    }
                }
                _ = await failure(world, beforeForce: { true })
                XCTAssertFalse(world.commands.contains { $0.pid == 10 && $0.kind == phase })
            }
        }
    }

    func testOwnedForkThatExecsAHelperBeforeConfirmationIsClosedAsItsOriginalDescendant() async throws {
        let world = ClosingWorld()
        world.edit {
            $0.processes = [world.main(10)]
            $0.arguments[10] = ["--user-data-dir=/profiles/a"]
            $0.onSleep = { state in
                if state.time == 0.25 {
                    state.processes.append(world.process(50, parent: 10, path: world.mainPath))
                } else if state.time >= 0.3, state.processes.contains(where: { $0.identity.pid == 10 }) {
                    state.processes = [world.outside(50, parent: 1)]
                }
            }
        }
        let outcome = try await world.engine.close(timeout: .seconds(28), beforeForce: { true })
        XCTAssertEqual(outcome, .quitAfterForce)
        XCTAssertEqual(world.commands.map(\.pid), [10, 50])
        XCTAssertEqual(world.commands.map(\.kind), [.normal, .force])
        XCTAssertTrue(world.remainingPIDs.isEmpty)
    }

    func testOwnedForkThatExitsBeforeConfirmationIsNotAReopenedApplication() async throws {
        let world = ClosingWorld()
        world.edit {
            $0.processes = [world.main(10)]
            $0.onSleep = { state in
                if state.time == 0.25 { state.processes.append(world.process(50, parent: 10, path: world.mainPath)) }
                else if state.time >= 0.3 { state.processes = [] }
            }
        }
        let outcome = try await world.engine.close(timeout: .seconds(28), beforeForce: { true })
        XCTAssertEqual(outcome, .quit)
        XCTAssertEqual(world.commands.map(\.pid), [10])
    }

    func testAnOwnedChildThatRemainsAMainStillStopsClosingBeforeAnyFurtherSignal() async throws {
        let world = ClosingWorld()
        world.edit {
            $0.processes = [world.main(10)]
            $0.onSleep = { state in
                if state.time == 0.25 { state.processes.append(world.process(50, parent: 10, path: world.mainPath)) }
            }
        }
        let error = await failure(world)
        XCTAssertEqual(error, .stillRunning(pids: [10, 50], names: ["Claude"], stall: .reopened))
        XCTAssertEqual(world.commands.map(\.pid), [10])
    }

    func testReusedForkPIDDuringConfirmationNeverAdoptsTheReplacement() async throws {
        let world = ClosingWorld()
        world.edit {
            $0.processes = [world.main(10)]
            $0.onSleep = { state in
                if state.time == 0.25 { state.processes.append(world.process(50, parent: 10, path: world.mainPath)) }
                else if state.time >= 0.3 {
                    state.processes = [world.process(50, parent: 1, path: "/elsewhere/replacement", startedAt: Date(timeIntervalSince1970: 99))]
                }
            }
        }
        _ = try await world.engine.close(timeout: .seconds(28), beforeForce: { true })
        XCTAssertEqual(world.commands.map(\.pid), [10])
        XCTAssertEqual(world.remainingPIDs, [50])
    }

    func testNewMainStopsCloseAndSuppressesRecoveryForItsProfile() async throws {
        let world = ClosingWorld()
        world.edit {
            $0.processes = [world.main(10), world.helper(11, parent: 10)]
            $0.arguments[10] = ["--user-data-dir=/profiles/a"]
            $0.normalExits = [10]
            $0.onSleep = { state in
                if state.time == 0.25 {
                    state.processes.append(world.main(50))
                    state.arguments[50] = ["--user-data-dir=/profiles/a"]
                }
            }
        }
        let error = await failure(world)
        XCTAssertEqual(error, .stillRunning(pids: [11, 50], closedProfiles: [], names: ["Claude", "helper"], stall: .reopened))
        XCTAssertEqual(world.commands.map(\.pid), [10])
        XCTAssertEqual(world.time, 0.25)
    }

    func testNewMainBetweenRequestsStopsBeforeSignallingAnotherOriginalMain() async throws {
        let world = ClosingWorld()
        world.edit {
            $0.processes = [world.main(10), world.main(20)]
            $0.onRead = { state in
                if state.reads == 3 { state.processes.append(world.main(30)) }
            }
        }
        let error = await failure(world)
        XCTAssertEqual(error, .stillRunning(pids: [10, 20, 30], names: ["Claude"], stall: .reopened))
        XCTAssertEqual(world.commands.map(\.pid), [10])
    }

    func testNewMainAndLateChildInSamePollBothAppearInFailure() async throws {
        let world = ClosingWorld()
        world.edit {
            $0.processes = [world.main(10)]
            $0.onSleep = { state in
                if state.time == 0.25 {
                    state.processes += [world.main(20), world.outside(11, parent: 10)]
                }
            }
        }
        let error = await failure(world)
        XCTAssertEqual(error, .stillRunning(pids: [10, 11, 20], names: ["Claude", "worker"], stall: .reopened))
        XCTAssertEqual(world.commands.map(\.pid), [10])
    }

    func testHasProcessesSeesLiveBundleProcessesWithoutAMain() throws {
        let world = ClosingWorld()
        world.edit { $0.processes = [world.outside(11, parent: 1), world.helper(15, parent: 1, zombie: true)] }
        XCTAssertFalse(try world.engine.hasProcesses())
        world.edit { $0.processes.append(world.helper(10, parent: 1)) }
        XCTAssertTrue(try world.engine.hasProcesses())
        let reporter = "/fixture/Claude.app/Contents/Frameworks/" + ClaudeClosingEngine.crashReporter
        world.edit { $0.processes = [world.process(30, parent: 1, path: reporter)] }
        XCTAssertFalse(try world.engine.hasProcesses())
        world.edit { $0.processes = [world.main(20)] }
        XCTAssertTrue(try world.engine.hasProcesses())
        world.edit { $0.unreadableAtRead = $0.reads + 1 }
        XCTAssertThrowsError(try world.engine.hasProcesses()) { error in
            XCTAssertEqual(error as? ClaudeProcessError, .processTableUnavailable)
        }
        XCTAssertTrue(world.commands.isEmpty)
    }

    func testProfilesInUseNameLeftoversByTheirFlagsOrMainAndFlagTheRest() throws {
        let world = ClosingWorld()
        let reporter = "/fixture/Claude.app/Contents/Frameworks/" + ClaudeClosingEngine.crashReporter
        world.edit {
            $0.processes = [world.main(10), world.helper(11, parent: 10), world.helper(20, parent: 1),
                           world.outside(21, parent: 20), world.process(30, parent: 1, path: reporter),
                           world.helper(40, parent: 1, zombie: true)]
            $0.arguments[10] = ["--user-data-dir=/profiles/a"]
            $0.arguments[20] = ["--user-data-dir", "/profiles/b"]
            $0.arguments[30] = ["--database=/profiles/c/Crashpad"]
        }
        XCTAssertEqual(try world.engine.profilesInUse(), ProfilesInUse(profiles: world.profiles("a", "b")))
        // A helper whose main is gone and that names no profile may be using any of them.
        world.edit { $0.processes.append(world.helper(50, parent: 1)) }
        XCTAssertEqual(try world.engine.profilesInUse(), ProfilesInUse(profiles: world.profiles("a", "b"), unattributed: true))
        world.edit { $0.unreadableAtRead = $0.reads + 1 }
        XCTAssertThrowsError(try world.engine.profilesInUse()) { error in
            XCTAssertEqual(error as? ClaudeProcessError, .processTableUnavailable)
        }
        XCTAssertTrue(world.commands.isEmpty)
    }

    func testHelperOnlySnapshotHasNoNormalOrTermTargets() async throws {
        let world = ClosingWorld()
        world.edit {
            $0.processes = [world.helper(10, parent: 1), world.outside(11, parent: 10)]
            $0.arguments[10] = ["--database=/profiles/a/Crashpad"]
        }
        let outcome = try await world.engine.close(timeout: .seconds(28), beforeForce: { true })
        XCTAssertEqual(outcome, .quitAfterForce)
        XCTAssertEqual(world.commands.map(\.kind), [.force, .force])
        XCTAssertEqual(world.commands.map(\.time), [5, 5])
    }

    func testLingeringMemberGetsFiveSecondsAfterMainExitsAtTwoSeconds() async throws {
        let world = ClosingWorld()
        world.edit {
            $0.processes = [world.main(10), world.outside(11, parent: 10)]
            $0.onSleep = { state in
                if state.time == 2 { state.processes.removeAll { $0.identity.pid == 10 } }
            }
        }
        let outcome = try await world.engine.close(timeout: .seconds(28), beforeForce: { true })
        XCTAssertEqual(outcome, .quitAfterForce)
        XCTAssertEqual(world.commands.map(\.kind), [.normal, .force])
        XCTAssertEqual(world.commands.map(\.time), [0, 7])
        XCTAssertEqual(world.time, 7.25)
    }

    func testGraceWithoutAnotherSignalKeepsNormalQuitOutcome() async throws {
        let world = ClosingWorld()
        world.edit {
            $0.processes = [world.main(10), world.outside(11, parent: 10)]
            $0.normalExits = [10]
            $0.onSleep = { state in
                if state.time == 1 { state.processes.removeAll() }
            }
        }
        let outcome = try await world.engine.close(timeout: .seconds(28), beforeForce: { XCTFail(); return true })
        XCTAssertEqual(outcome, .quit)
        XCTAssertEqual(world.commands.map(\.kind), [.normal])
    }

    func testWhatEndsWhileTheTasksAreCheckedBeforeForcingIsAClose() async throws {
        let world = ClosingWorld()
        world.edit {
            $0.processes = [world.main(10), world.helper(11, parent: 1)]
            $0.arguments[10] = ["--user-data-dir=/profiles/a"]
            $0.arguments[11] = ["--user-data-dir=/profiles/a"]
            $0.normalExits = [10]
        }
        // The last helper exits while the task check runs; nothing is left that would need forcing.
        let outcome = try await world.engine.close(timeout: .seconds(28), beforeForce: {
            world.edit { $0.processes.removeAll() }
            return false
        })
        XCTAssertEqual(outcome, .quit)
        XCTAssertFalse(world.commands.contains { $0.kind == .force })
    }

    func testLateChildJoinsAndKeepsAttributionAfterMainExitAndReparenting() async throws {
        let world = ClosingWorld()
        world.edit {
            $0.processes = [world.main(10)]
            $0.arguments[10] = ["--user-data-dir=/profiles/a"]
            $0.onSleep = { state in
                if state.time == 0.25 { state.processes.append(world.outside(11, parent: 10)) }
                if state.time == 0.5 {
                    state.processes = [world.outside(11, parent: 1)]
                }
            }
        }
        let error = await failure(world, beforeForce: { false })
        XCTAssertEqual(error, .stillRunning(pids: [11], closedProfiles: [], names: ["worker"], stall: .notForced))
        XCTAssertEqual(world.commands.map(\.kind), [.normal])
        XCTAssertEqual(world.time, 5.5)
    }

    func testLateDescendantDuringForceIsAlsoForced() async throws {
        let world = ClosingWorld()
        world.edit {
            $0.processes = [world.main(10)]
            $0.forceExits = false
            $0.onSleep = { state in
                if state.time == 25.25 { state.processes.append(world.outside(11, parent: 10)) }
            }
        }
        let error = await failure(world)
        XCTAssertEqual(world.commands.filter { $0.kind == .force }.map(\.pid), [10, 11])
        guard case .stillRunning(_, _, _, let stall)? = error else { return XCTFail("expected a close that did not finish") }
        XCTAssertEqual(stall, .survivedForce)
    }

    func testBeforeForceFalseMakesNoForceRequestsAndReportsOnlyClosedProfiles() async throws {
        let world = ClosingWorld()
        world.edit {
            $0.processes = [world.main(10), world.main(20)]
            $0.arguments[10] = ["--user-data-dir=/profiles/a"]
            $0.arguments[20] = ["--user-data-dir=/profiles/b"]
            $0.normalExits = [10]
        }
        let error = await failure(world, beforeForce: { false })
        XCTAssertEqual(error, .stillRunning(pids: [20], closedProfiles: world.profiles("a"), names: ["Claude"], stall: .notForced))
        XCTAssertEqual(world.commands.map(\.kind), [.normal, .normal, .term])
    }

    func testBudgetCapsEveryPhaseAndCallbackCannotAuthorizeSignalsAfterDeadline() async throws {
        for budget in [0.0, 0.1, 20, 21, 25, 25.5, 28] {
            let world = ClosingWorld()
            world.edit { $0.processes = [world.main(10)]; $0.forceExits = false }
            _ = await failure(world, timeout: .seconds(budget))
            XCTAssertEqual(world.time, budget, accuracy: 0.0001)
            XCTAssertTrue(world.commands.allSatisfy { $0.time < budget })
        }
        let world = ClosingWorld()
        world.edit { $0.processes = [world.main(10)] }
        let error = await failure(world, beforeForce: {
            world.edit { $0.time = 29 }
            return true
        })
        XCTAssertEqual(error, .stillRunning(pids: [10], names: ["Claude"], stall: .outOfTime))
        XCTAssertFalse(world.commands.contains { $0.kind == .force })
    }

    func testNormalSignalAndAlreadyStoppedOutcomes() async throws {
        let empty = ClosingWorld()
        let stopped = try await empty.engine.close(timeout: .zero, beforeForce: { XCTFail(); return true })
        XCTAssertEqual(stopped, .alreadyStopped)
        for signal in [false, true] {
            let world = ClosingWorld()
            world.edit {
                $0.processes = [world.main(10)]
                if signal { $0.termExits = [10] } else { $0.normalExits = [10] }
            }
            let outcome = try await world.engine.close(timeout: .seconds(28), beforeForce: { XCTFail(); return true })
            XCTAssertEqual(outcome, signal ? .quitAfterSignal : .quit)
        }
    }

    func testUnreadableTableInitiallyOrAtPollThrowsUnavailable() async throws {
        for read in [1, 3] {
            let world = ClosingWorld()
            world.edit { $0.processes = [world.main(10)]; $0.unreadableAtRead = read }
            let error = await failure(world)
            XCTAssertEqual(error, .processTableUnavailable)
        }
    }

    private func failure(_ world: ClosingWorld, timeout: Duration = .seconds(28),
                         beforeForce: @escaping @Sendable () async -> Bool = { true }) async -> ClaudeProcessError? {
        do {
            _ = try await world.engine.close(timeout: timeout, beforeForce: beforeForce)
            return nil
        } catch { return error as? ClaudeProcessError }
    }
}

private final class ClosingWorld: CompanionCore.Clock, @unchecked Sendable {
    struct Command: Sendable {
        enum Kind: Sendable { case normal, term, force }
        let pid: Int32
        let kind: Kind
        let time: Double
    }

    struct State {
        var processes: [ClosingProcess] = []
        var arguments: [Int32: [String]] = [:]
        var unreadableArguments: Set<Int32> = []
        var commands: [Command] = []
        var normalExits: Set<Int32> = []
        var termExits: Set<Int32> = []
        var forceExits = true
        var time: Double = 0
        var reads = 0
        var readsAtTime = 0
        var unreadableAtRead: Int?
        var onRead: (@Sendable (inout State) -> Void)?
        var onSleep: (@Sendable (inout State) -> Void)?
    }

    let mainPath = "/fixture/Claude.app/Contents/MacOS/Claude"
    private let lock = NSLock()
    private var state = State()

    var engine: ClaudeClosingEngine {
        ClaudeClosingEngine(mainExecutable: URL(fileURLWithPath: mainPath), defaultProfile: profiles("default")[0],
            isBundleExecutable: { $0.path.hasPrefix("/fixture/Claude.app/Contents/") },
            readTable: { try self.readTable() }, readArguments: { identity in
                try self.edit { state in
                    if state.unreadableArguments.contains(identity.pid) { throw ProcessTableError.unavailable }
                    if let arguments = state.arguments[identity.pid] { return arguments }
                    return []
                }
            }, normalQuit: { self.record($0, kind: .normal) },
            normalQuitOutcome: .quit,
            signal: { identity, signal, _ in self.record(identity, kind: signal == .force ? .force : .term) }, clock: self)
    }

    var commands: [Command] { edit { $0.commands } }
    var remainingPIDs: [Int32] { edit { $0.processes.map { $0.identity.pid }.sorted() } }
    var time: Double { edit { $0.time } }

    func edit<T>(_ body: (inout State) throws -> T) rethrows -> T { try lock.withLock { try body(&state) } }
    func now() -> Date { Date(timeIntervalSince1970: time) }
    func sleep(for duration: Duration) async throws {
        edit { state in
            state.time += duration.timeInterval
            state.readsAtTime = 0
            let change = state.onSleep
            change?(&state)
        }
    }

    func profiles(_ names: String...) -> [URL] {
        names.map { ProfilePaths.canonical(URL(fileURLWithPath: "/profiles/\($0)")) }.sorted { $0.path < $1.path }
    }

    func main(_ pid: Int32) -> ClosingProcess {
        process(pid, parent: 1, path: mainPath)
    }

    func helper(_ pid: Int32, parent: Int32, zombie: Bool = false) -> ClosingProcess {
        process(pid, parent: parent, path: "/fixture/Claude.app/Contents/Helpers/helper", zombie: zombie)
    }

    func outside(_ pid: Int32, parent: Int32) -> ClosingProcess { process(pid, parent: parent, path: "/tools/worker") }

    func process(_ pid: Int32, parent: Int32, path: String, zombie: Bool = false,
                 startedAt: Date = Date(timeIntervalSince1970: 1)) -> ClosingProcess {
        ClosingProcess(identity: ClosingIdentity(pid: pid, startedAt: startedAt, executable: URL(fileURLWithPath: path)),
                       parent: parent, isZombie: zombie)
    }

    private func readTable() throws -> [ClosingProcess] {
        try edit { state in
            state.reads += 1
            state.readsAtTime += 1
            let change = state.onRead
            change?(&state)
            if state.unreadableAtRead == state.reads { throw ProcessTableError.unavailable }
            return state.processes
        }
    }

    private func record(_ identity: ClosingIdentity, kind: Command.Kind) {
        edit { state in
            state.commands.append(Command(pid: identity.pid, kind: kind, time: state.time))
            if kind == .force && state.forceExits || kind == .normal && state.normalExits.contains(identity.pid)
                || kind == .term && state.termExits.contains(identity.pid) {
                state.processes.removeAll { $0.identity == identity }
            }
        }
    }
}
