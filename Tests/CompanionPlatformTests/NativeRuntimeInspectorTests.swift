import CompanionCore
import Foundation
import XCTest
@testable import CompanionPlatform

@MainActor
final class NativeRuntimeInspectorTests: XCTestCase {
    func testAllNativeLiveRegistryStatesPreserveRuntimeOwnership() async throws {
        for status in ["idle", "busy", "shell", "waiting"] {
            let world = try NativeInspectorWorld()
            let registry = try world.registry(status: status)
            world.edit { $0.registries[200] = registry }
            let inspector = world.inspector()
            let valid = await inspector.validate(world.report(), profile: world.profile, account: world.account)
            XCTAssertTrue(valid, status)
            let sessions = await inspector.sessions(profile: world.profile)
            XCTAssertEqual(sessions.map(\.pid), [200], status)
            XCTAssertEqual(sessions.map(\.busy), [status != "idle"], status)
        }
    }

    func testPermissionWaitBeginningDuringValidationDoesNotMakeTheProcessDisappear() async throws {
        let world = try NativeInspectorWorld()
        let busy = try world.registry(status: "busy"), waiting = try world.registry(status: "waiting")
        world.edit { $0.registries[200] = busy; $0.secondRegistries[200] = waiting }
        let valid = await world.inspector().validate(world.report(), profile: world.profile, account: world.account)
        XCTAssertTrue(valid)
    }

    func testEnumeratesIdleAndBusyDesktopSessionsInTheRequestedProfile() async throws {
        let world = try NativeInspectorWorld()
        let busy = world.cli(pid: 201, parent: 110, born: world.birth.addingTimeInterval(0.1))
        let busyRegistry = try world.registry(pid: 201, session: "second-session", born: busy.startedAt, status: "busy")
        world.edit {
            $0.processes.append(busy)
            $0.registries[201] = busyRegistry
        }
        let sessions = await world.inspector().sessions(profile: world.profile)
        XCTAssertEqual(sessions.map(\.pid), [200, 201])
        XCTAssertEqual(sessions.map(\.busy), [false, true])
        XCTAssertEqual(sessions.map(\.sessionID), [world.sessionID, "second-session"])
    }

    func testIdleRuntimeWithADirectShellChildInTheFreshSnapshotCountsAsBusy() async throws {
        for shell in ["sh", "bash", "zsh", "fish"] {
            let world = try NativeInspectorWorld()
            let child = ProcessEntry(pid: 300, ppid: 200, executableURL: URL(fileURLWithPath: "/bin/\(shell)"),
                                     startedAt: world.birth.addingTimeInterval(0.1))
            world.edit { $0.secondProcesses = $0.processes + [child] }
            let sessions = await world.inspector().sessions(profile: world.profile)
            XCTAssertEqual(sessions.map(\.pid), [200])
            XCTAssertEqual(sessions.map(\.busy), [true], shell)
        }
    }

    func testIdleRuntimeDoesNotInheritAStaleOrUnrelatedShellChild() async throws {
        let stale = try NativeInspectorWorld()
        stale.edit {
            $0.secondProcesses = $0.processes
            $0.processes.append(ProcessEntry(pid: 300, ppid: 200, executableURL: URL(fileURLWithPath: "/bin/zsh"),
                                            startedAt: stale.birth.addingTimeInterval(0.1)))
        }
        let staleSessions = await stale.inspector().sessions(profile: stale.profile)
        XCTAssertEqual(staleSessions.map(\.busy), [false], "An exited shell in the first scan is not current work")
        for parent: Int32 in [110, 999] {
            let world = try NativeInspectorWorld()
            world.edit {
                $0.processes.append(ProcessEntry(pid: 300, ppid: parent, executableURL: URL(fileURLWithPath: "/bin/zsh"),
                                                startedAt: world.birth.addingTimeInterval(0.1)))
            }
            let sessions = await world.inspector().sessions(profile: world.profile)
            XCTAssertEqual(sessions.map(\.busy), [false])
        }
        let reusedParent = try NativeInspectorWorld()
        reusedParent.edit {
            $0.processes.append(ProcessEntry(pid: 300, ppid: 200, executableURL: URL(fileURLWithPath: "/bin/zsh"),
                                            startedAt: reusedParent.birth.addingTimeInterval(-1)))
        }
        let invalidBirth = await reusedParent.inspector().sessions(profile: reusedParent.profile)
        XCTAssertEqual(invalidBirth.map(\.busy), [false], "A shell older than the parent lifetime cannot establish ownership")
    }

    func testValidReportRequiresTheCurrentAccountAndOrganization() async throws {
        let world = try NativeInspectorWorld()
        let accepted = await world.inspector().validate(world.report(), profile: world.profile, account: world.account)
        XCTAssertTrue(accepted)
        for identity in [AccountIdentity(accountUUID: "other-account", activeOrganizationUUID: "org-one"),
                         AccountIdentity(accountUUID: world.account.accountUUID, activeOrganizationUUID: "other-org"),
                         AccountIdentity(accountUUID: world.account.accountUUID)] {
            let rejected = await world.inspector().validate(world.report(), profile: world.profile, account: identity)
            XCTAssertFalse(rejected)
        }
    }

    func testOldSourceRuntimeCannotClaimTheSameSessionUnderAnotherProfile() async throws {
        let world = try NativeInspectorWorld()
        let targetProfile = world.paths.claudeProfilesRoot.appending(path: "Claude_target")
        let main = world.main(pid: 101, born: world.birth.addingTimeInterval(-1))
        let cli = world.cli(pid: 201, parent: 101, born: world.birth.addingTimeInterval(1))
        let registry = try world.registry(pid: 201, session: world.sessionID, born: cli.startedAt)
        world.edit {
            $0.processes += [main, cli]
            $0.arguments[101] = [main.executableURL.path, "--user-data-dir", targetProfile.path]
            $0.registries[201] = registry
        }
        let old = await world.inspector().validate(world.report(), profile: targetProfile, account: world.account)
        XCTAssertFalse(old, "The shared CLI session ID does not establish target-account ownership")
        var newReport = world.report()
        newReport.pid = 201
        newReport.instanceID = "new-runtime"
        newReport.procStart = TaskGuardEvaluator.registryStartTime(cli.startedAt)
        let new = await world.inspector().validate(newReport, profile: targetProfile, account: world.account)
        XCTAssertTrue(new)
        let targetSessions = await world.inspector().sessions(profile: targetProfile)
        XCTAssertEqual(targetSessions.map(\.pid), [201])
    }

    func testWrongRegistryLifetimeDomainEntrypointAndSessionAreRejected() async throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["pid"] = 999 },
            { $0["procStart"] = "Mon Jan 1 00:00:00 2024" },
            { $0["pidDomain"] = "linux" },
            { $0.removeValue(forKey: "pidDomain") },
            { $0["entrypoint"] = "cli" },
            { $0["sessionId"] = "another-session" },
            { $0["status"] = "stopped" },
            { $0["status"] = "unknown" },
        ]
        for mutation in mutations {
            let world = try NativeInspectorWorld()
            var registry = try XCTUnwrap(JSONSerialization.jsonObject(with: world.registry()) as? [String: Any])
            mutation(&registry)
            let data = try JSONSerialization.data(withJSONObject: registry)
            world.edit { $0.registries[200] = data }
            let accepted = await world.inspector().validate(world.report(), profile: world.profile, account: world.account)
            XCTAssertFalse(accepted, String(describing: registry))
        }
    }

    func testAProcessOrAncestorReusedDuringInspectionIsRejected() async throws {
        for changedPID: Int32 in [100, 110, 200] {
            let world = try NativeInspectorWorld()
            world.edit { state in
                state.secondProcesses = state.processes.map { process in
                    guard process.pid == changedPID else { return process }
                    return ProcessEntry(pid: process.pid, ppid: process.ppid, executableURL: process.executableURL,
                                        startedAt: process.startedAt.addingTimeInterval(0.5))
                }
            }
            let accepted = await world.inspector().validate(world.report(), profile: world.profile, account: world.account)
            XCTAssertFalse(accepted, "PID \(changedPID) changed lifetime during inspection")
        }
    }

    func testOldReportCannotValidateAPIDReusedWithinTheSameSecond() async throws {
        let world = try NativeInspectorWorld()
        var oldReport = world.report()
        oldReport.reportedAt = world.birth.addingTimeInterval(0.1).timeIntervalSince1970 * 1000
        let replacement = world.cli(pid: 200, parent: 110, born: world.birth.addingTimeInterval(0.2))
        XCTAssertEqual(TaskGuardEvaluator.registryStartTime(world.birth), TaskGuardEvaluator.registryStartTime(replacement.startedAt))
        let registry = try world.registry(born: replacement.startedAt)
        world.edit {
            $0.processes.removeAll { $0.pid == 200 }
            $0.processes.append(replacement)
            $0.registries[200] = registry
        }
        let accepted = await world.inspector().validate(oldReport, profile: world.profile, account: world.account)
        XCTAssertFalse(accepted)
    }

    func testUnrelatedOrOrphanedCLIAndParentCyclesAreNotDesktopSessions() async throws {
        for parent: Int32 in [1, 999, 200] {
            let world = try NativeInspectorWorld()
            world.edit {
                $0.processes.removeAll { $0.pid == 200 }
                $0.processes.append(world.cli(pid: 200, parent: parent, born: world.birth))
            }
            let inspector = world.inspector()
            let sessions = await inspector.sessions(profile: world.profile)
            let accepted = await inspector.validate(world.report(), profile: world.profile, account: world.account)
            XCTAssertTrue(sessions.isEmpty)
            XCTAssertFalse(accepted)
        }
    }

    func testMainArgumentsMustIdentifyTheProfileAndOnlyFlaglessDefaultIsAccepted() async throws {
        for arguments in [["Claude", "--user-data-dir=/wrong/profile"],
                          ["Claude", "--user-data-dir=relative"],
                          ["Claude", "--user-data-dir"], ["Claude"]] {
            let world = try NativeInspectorWorld()
            world.edit { $0.arguments[100] = arguments }
            let accepted = await world.inspector().validate(world.report(), profile: world.profile, account: world.account)
            XCTAssertFalse(accepted)
        }
        let defaultWorld = try NativeInspectorWorld()
        defaultWorld.edit { $0.arguments[100] = ["Claude"] }
        let accepted = await defaultWorld.inspector().validate(defaultWorld.report(),
            profile: defaultWorld.paths.claudeProfilesRoot.appending(path: "Claude"), account: defaultWorld.account)
        XCTAssertTrue(accepted)
    }

    func testProfileOrRegistryChangedDuringInspectionInvalidatesTheReport() async throws {
        let changedAccount = try NativeInspectorWorld.configuration(account: "new-login", organization: "org-one")
        let accountWorld = try NativeInspectorWorld()
        accountWorld.edit { $0.secondConfiguration = changedAccount }
        let changedLogin = await accountWorld.inspector().validate(accountWorld.report(), profile: accountWorld.profile,
                                                                  account: accountWorld.account)
        XCTAssertFalse(changedLogin)

        let sessionWorld = try NativeInspectorWorld()
        let nextRegistry = try sessionWorld.registry(session: "different-conversation")
        sessionWorld.edit { $0.secondRegistries[200] = nextRegistry }
        let changedSession = await sessionWorld.inspector().validate(sessionWorld.report(), profile: sessionWorld.profile,
                                                                     account: sessionWorld.account)
        XCTAssertFalse(changedSession)
    }

    func testPublicLiveAdapterRefusesInTheTestProcess() async throws {
        let world = try NativeInspectorWorld()
        let inspector = LiveNativeRuntimeInspector(paths: world.paths)
        let sessions = await inspector.sessions(profile: world.profile)
        let accepted = await inspector.validate(world.report(), profile: world.profile, account: world.account)
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertFalse(accepted)
    }
}

private final class NativeInspectorWorld: @unchecked Sendable {
    let paths = AppPaths.sandbox(root: URL(fileURLWithPath: "/fixture/native-runtime-inspector"))
    let birth = Date(timeIntervalSince1970: 1_700_000_000.125)
    let sessionID = "same-conversation"
    let account = AccountIdentity(accountUUID: "account-one", activeOrganizationUUID: "org-one")
    var profile: URL { paths.claudeProfilesRoot.appending(path: "Claude_source") }
    private let lock = NSLock()
    private var state: State

    init() throws {
        state = State(configuration: try Self.configuration(account: "account-one", organization: "org-one"))
        let parent = main(pid: 100, born: birth.addingTimeInterval(-3))
        state.processes = [parent,
                           ProcessEntry(pid: 110, ppid: 100,
                                        executableURL: paths.claudeAppPath.appending(path: "Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"),
                                        startedAt: birth.addingTimeInterval(-2)),
                           cli(pid: 200, parent: 110, born: birth)]
        state.arguments[100] = [parent.executableURL.path, "--user-data-dir=\(profile.path)"]
        state.registries[200] = try registry()
    }

    func edit(_ update: (inout State) -> Void) { lock.withLock { update(&state) } }

    func inspector() -> LiveNativeRuntimeInspector {
        LiveNativeRuntimeInspector(paths: paths, readProcesses: { [self] in
            lock.withLock {
                state.processReads += 1
                return state.processReads > 1 ? state.secondProcesses ?? state.processes : state.processes
            }
        }, readArguments: { [self] entry in
            try lock.withLock {
                guard let arguments = state.arguments[entry.pid] else { throw NativeInspectorFixtureError.missing }
                return arguments
            }
        }, readRegistry: { [self] pid in
            try lock.withLock {
                state.registryReads[pid, default: 0] += 1
                let data = state.registryReads[pid, default: 0] > 1 ? state.secondRegistries[pid] ?? state.registries[pid] : state.registries[pid]
                guard let data else { throw NativeInspectorFixtureError.missing }
                return data
            }
        }, readConfiguration: { [self] _ in
            lock.withLock {
                state.configurationReads += 1
                return state.configurationReads > 1 ? state.secondConfiguration ?? state.configuration : state.configuration
            }
        })
    }

    func main(pid: Int32, born: Date) -> ProcessEntry {
        ProcessEntry(pid: pid, ppid: 1, executableURL: paths.claudeAppPath.appending(path: "Contents/MacOS/Claude"), startedAt: born)
    }

    func cli(pid: Int32, parent: Int32, born: Date) -> ProcessEntry {
        ProcessEntry(pid: pid, ppid: parent,
                     executableURL: profile.appending(path: "claude-code/2.1.308/hash/claude.app/Contents/MacOS/claude"),
                     startedAt: born)
    }

    func report() -> NativeRuntimeReport {
        NativeRuntimeReport(sessionID: sessionID, instanceID: "runtime-one", pid: 200,
                            procStart: TaskGuardEvaluator.registryStartTime(birth),
                            reportedAt: birth.addingTimeInterval(2).timeIntervalSince1970 * 1000)
    }

    func registry(pid: Int32 = 200, session: String? = nil, born: Date? = nil, status: String = "idle") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["pid": pid, "sessionId": session ?? sessionID,
            "procStart": TaskGuardEvaluator.registryStartTime(born ?? birth), "pidDomain": "darwin",
            "entrypoint": "claude-desktop", "status": status])
    }

    static func configuration(account: String, organization: String) throws -> ProfileConfiguration {
        try ProfileConfigReader().parse(JSONSerialization.data(withJSONObject: [
            "lastKnownAccountUuid": account,
            "dxt:allowlistLastUpdated:\(organization)": "2026-10-27T00:00:00.000Z",
        ]))
    }

    struct State {
        var processes: [ProcessEntry] = []
        var secondProcesses: [ProcessEntry]?
        var arguments: [Int32: [String]] = [:]
        var registries: [Int32: Data] = [:]
        var secondRegistries: [Int32: Data] = [:]
        var registryReads: [Int32: Int] = [:]
        var processReads = 0
        var configuration: ProfileConfiguration
        var secondConfiguration: ProfileConfiguration?
        var configurationReads = 0
    }
}

private enum NativeInspectorFixtureError: Error { case missing }
