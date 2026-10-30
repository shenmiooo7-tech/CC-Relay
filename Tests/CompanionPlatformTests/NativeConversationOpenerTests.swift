import CompanionCore
import Foundation
import XCTest
@testable import CompanionPlatform

@MainActor
final class NativeConversationOpenerTests: XCTestCase {
    func testDeliversTheLinkWhenTheTargetIsTheOnlyRunningDesktop() async throws {
        let world = try ConversationOpenerWorld()
        try await world.opener().open(profile: world.profile, account: world.account, desktopSessionID: "local_original-session")
        XCTAssertEqual(world.edit { $0.deliveries }, [.init(url: "claude://code/continue?session=local_original-session", profile: world.profile.path)])
        XCTAssertEqual(world.edit { $0.processReads }, 2)
        XCTAssertEqual(world.edit { $0.configReads }, 2)
    }

    func testAnotherRunningDesktopLeavesTheConversationToBeOpenedByHand() async throws {
        let world = try ConversationOpenerWorld()
        world.edit {
            $0.processes.append(world.main(pid: 200))
            $0.arguments[200] = [world.executable.path, "--user-data-dir=/fixture/another-profile"]
        }
        await expectError(world, .ambiguousTarget)
        XCTAssertTrue(world.edit { $0.deliveries.isEmpty }, "the system could hand the link to the other account's window")
    }

    func testInvalidSessionIDsAreNeverDelivered() async throws {
        for id in ["", "local_", "remote_abc", "local_abc&other=1", "local_a/b", "local_" + String(repeating: "a", count: 65)] {
            let world = try ConversationOpenerWorld()
            await expectError(world, .invalidSession, session: id)
            XCTAssertTrue(world.edit { $0.deliveries.isEmpty })
        }
    }

    func testNoDesktopOrAnotherProfileIsNotATarget() async throws {
        let missing = try ConversationOpenerWorld()
        missing.edit { $0.processes = [] }
        await expectError(missing, .targetNotRunning)
        let executable = try ConversationOpenerWorld()
        executable.edit {
            $0.processes = [ProcessEntry(pid: 100, ppid: 1, executableURL: URL(fileURLWithPath: "/other/Claude"), startedAt: executable.birth)]
        }
        await expectError(executable, .targetNotRunning)
        let profile = try ConversationOpenerWorld()
        profile.edit { $0.arguments[100] = [profile.executable.path, "--user-data-dir=/other/profile"] }
        await expectError(profile, .targetNotRunning)
        XCTAssertTrue(profile.edit { $0.deliveries.isEmpty })
    }

    func testAccountOrOrganizationMismatchIsNeverDelivered() async throws {
        for configuration in [try ConversationOpenerWorld.configuration(account: "other", org: "org-one"),
                              try ConversationOpenerWorld.configuration(account: "account-one", org: "other")] {
            let world = try ConversationOpenerWorld()
            world.edit { $0.configuration = configuration }
            await expectError(world, .identityChanged)
            XCTAssertTrue(world.edit { $0.deliveries.isEmpty })
        }
    }

    func testChangesBetweenTheTwoChecksPreventDelivery() async throws {
        for replacement in [
            [ProcessEntry(pid: 100, ppid: 1, executableURL: ConversationOpenerWorld.paths.claudeAppPath.appending(path: "Contents/MacOS/Claude"), startedAt: ConversationOpenerWorld.epoch.addingTimeInterval(0.001))],
            [ProcessEntry(pid: 100, ppid: 99, executableURL: ConversationOpenerWorld.paths.claudeAppPath.appending(path: "Contents/MacOS/Claude"), startedAt: ConversationOpenerWorld.epoch)],
        ] {
            let world = try ConversationOpenerWorld()
            world.edit { $0.secondProcesses = replacement }
            await expectError(world, .identityChanged)
            XCTAssertTrue(world.edit { $0.deliveries.isEmpty })
        }
        let appeared = try ConversationOpenerWorld()
        appeared.edit { $0.secondProcesses = $0.processes + [appeared.main(pid: 300)]; $0.arguments[300] = [appeared.executable.path] }
        await expectError(appeared, .ambiguousTarget)
        let profile = try ConversationOpenerWorld()
        profile.edit { $0.secondArguments[100] = [profile.executable.path, "--user-data-dir=/another/profile"] }
        await expectError(profile, .targetNotRunning)
        let account = try ConversationOpenerWorld()
        let changed = try ConversationOpenerWorld.configuration(account: "changed", org: "org-one")
        account.edit { $0.secondConfiguration = changed }
        await expectError(account, .identityChanged)
        XCTAssertTrue(account.edit { $0.deliveries.isEmpty })
    }

    func testDeliveryFailureIsReportedWithoutRetry() async throws {
        let world = try ConversationOpenerWorld()
        world.edit { $0.deliveryFailure = NSError(domain: NSCocoaErrorDomain, code: 260) }
        await expectError(world, .deliveryFailed(260))
        XCTAssertEqual(world.edit { $0.deliveries.count }, 1)
    }

    func testPublicLiveAdapterIsBlockedByTheTestSafetyTripwire() async throws {
        let world = try ConversationOpenerWorld()
        do {
            try await LiveNativeConversationOpener(paths: ConversationOpenerWorld.paths)
                .open(profile: world.profile, account: world.account, desktopSessionID: "local_original")
            XCTFail("A test process must not open links in real applications")
        } catch { XCTAssertTrue(error is SafetyRefusal) }
    }

    private func expectError(_ world: ConversationOpenerWorld, _ expected: NativeConversationOpenError,
                             session: String = "local_original") async {
        do {
            try await world.opener().open(profile: world.profile, account: world.account, desktopSessionID: session)
            XCTFail("Expected \(expected)")
        } catch { XCTAssertEqual(error as? NativeConversationOpenError, expected) }
    }
}

private final class ConversationOpenerWorld: @unchecked Sendable {
    static let paths = AppPaths.sandbox(root: URL(fileURLWithPath: "/fixture/native-opener"))
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000.125)
    var birth: Date { Self.epoch }
    var executable: URL { Self.paths.claudeAppPath.appending(path: "Contents/MacOS/Claude") }
    var profile: URL { Self.paths.claudeProfilesRoot.appending(path: "Claude_target") }
    let account = AccountIdentity(accountUUID: "account-one", activeOrganizationUUID: "org-one")
    private let lock = NSLock()
    private var state: State

    init() throws {
        state = State(configuration: try Self.configuration(account: "account-one", org: "org-one"))
        state.processes = [main(pid: 100)]
        state.arguments[100] = [executable.path, "--user-data-dir=\(profile.path)"]
    }

    func edit<T>(_ body: (inout State) throws -> T) rethrows -> T { try lock.withLock { try body(&state) } }

    func main(pid: Int32) -> ProcessEntry {
        ProcessEntry(pid: pid, ppid: 1, executableURL: executable, startedAt: birth)
    }

    func opener() -> LiveNativeConversationOpener {
        LiveNativeConversationOpener(paths: Self.paths, readProcesses: { [self] in
            edit { value in
                value.processReads += 1
                return value.processReads > 1 ? value.secondProcesses ?? value.processes : value.processes
            }
        }, readArguments: { [self] process in
            try edit { value in
                value.argumentReads[process.pid, default: 0] += 1
                guard let args = value.argumentReads[process.pid, default: 0] > 1
                        ? value.secondArguments[process.pid] ?? value.arguments[process.pid]
                        : value.arguments[process.pid] else { throw NativeConversationOpenError.identityChanged }
                return args
            }
        }, readConfiguration: { [self] _ in
            edit { value in
                value.configReads += 1
                return value.configReads > 1 ? value.secondConfiguration ?? value.configuration : value.configuration
            }
        }, deliver: { [self] url, profile in
            try edit { value in
                value.deliveries.append(.init(url: url.absoluteString, profile: profile.path))
                if let error = value.deliveryFailure { throw error }
            }
        })
    }

    static func configuration(account: String, org: String) throws -> ProfileConfiguration {
        try ProfileConfigReader().parse(JSONSerialization.data(withJSONObject: [
            "lastKnownAccountUuid": account, "dxt:allowlistLastUpdated:\(org)": "2026-10-27T00:00:00.000Z",
        ]))
    }

    struct Delivery: Equatable { let url: String; let profile: String }
    struct State {
        var configuration: ProfileConfiguration
        var secondConfiguration: ProfileConfiguration?
        var processes: [ProcessEntry] = []
        var secondProcesses: [ProcessEntry]?
        var arguments: [Int32: [String]] = [:]
        var secondArguments: [Int32: [String]] = [:]
        var argumentReads: [Int32: Int] = [:]
        var processReads = 0, configReads = 0
        var deliveries: [Delivery] = []
        var deliveryFailure: NSError?
    }
}
