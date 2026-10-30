import CompanionCore
import Darwin
import Foundation
import XCTest
@testable import CompanionPlatform

@MainActor
final class SandboxProcessControllerTests: XCTestCase {
    private func binary(in directory: PlatformTestDirectory) throws -> URL {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let folder = directory.root.appendingPathComponent("application with spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let binary = folder.appendingPathComponent("FakeClaude")
        try FileManager.default.copyItem(at: products.appendingPathComponent("FakeClaude"), to: binary)
        return binary
    }

    func testLaunchDetectDeepLinkMonitorAndGracefulQuit() async throws {
        let directory = try PlatformTestDirectory()
        defer { FakeClaudeTestCleanup(root: directory.root).stop(); directory.remove() }
        let executable = try binary(in: directory)
        let controller = SandboxClaudeProcessController(root: directory.root, fakeClaudeExecutable: executable)
        let stream = SandboxLaunchMonitor(root: directory.root, fakeClaudeExecutable: executable).launches()
        let eventTask = Task { try await nextEvent(stream) }
        defer { eventTask.cancel() }
        let profile = directory.root.appendingPathComponent("profile with spaces", isDirectory: true)
        try AtomicFile.write(Data("{\"pid\":-1}".utf8), to: profile.appendingPathComponent(".fake-claude/instance.json"))
        let link = URL(string: "claude://code/continue?session=local_fixture-123")!
        let instance: ClaudeInstance
        do { instance = try await controller.launch(profile: profile, deepLink: link) }
        catch { eventTask.cancel(); throw error }
        let event = try await eventTask.value
        XCTAssertEqual(event.pid, instance.pid)
        XCTAssertTrue(event.hasExplicitProfileFlag)
        XCTAssertEqual(instance.profileDirectory, ProfilePaths.canonical(profile))
        XCTAssertTrue(instance.hasExplicitProfileFlag)
        let record = try XCTUnwrap(ProcessTable().record(pid: instance.pid))
        XCTAssertEqual(record.startedAt, instance.startedAt)
        XCTAssertEqual(record.executableURL.standardizedFileURL, executable.resolvingSymlinksInPath().standardizedFileURL)
        let detected = try await controller.runningInstances()
        XCTAssertEqual(detected.map(\.pid), [instance.pid])
        let links = try String(contentsOf: profile.appendingPathComponent(".fake-claude/deeplinks.log"), encoding: .utf8)
        XCTAssertEqual(links, link.absoluteString + "\n")
        let outcome = try await controller.quitAll(timeout: .seconds(15))
        XCTAssertEqual(outcome, .quitAfterSignal)
        let remaining = try await controller.runningInstances()
        XCTAssertTrue(remaining.isEmpty)
        let again = try await controller.quitAll(timeout: .seconds(1))
        XCTAssertEqual(again, .alreadyStopped)
    }

    func testIgnoreTermRequiresForceQuit() async throws {
        let directory = try PlatformTestDirectory()
        defer { FakeClaudeTestCleanup(root: directory.root).stop(); directory.remove() }
        let controller = SandboxClaudeProcessController(root: directory.root, fakeClaudeExecutable: try binary(in: directory),
                                                       environment: ["FAKE_CLAUDE_IGNORE_TERM": "1"], clock: AcceleratedSandboxClock())
        let profile = directory.root.appendingPathComponent("profile")
        _ = try await controller.launch(profile: profile, deepLink: nil)
        let outcome = try await controller.quitAll(timeout: .seconds(90))
        XCTAssertEqual(outcome, .quitAfterForce)
        let remaining = try await controller.runningInstances()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.appendingPathComponent(".fake-claude/events.log").path))
    }

    func testLaunchVerificationTimeoutAndInvalidLinkLeaveNoChild() async throws {
        let directory = try PlatformTestDirectory()
        defer { FakeClaudeTestCleanup(root: directory.root).stop(); directory.remove() }
        let executable = directory.root.appendingPathComponent("FakeClaude")
        try AtomicFile.write(Data("#!/bin/sh\nexit 0\n".utf8), to: executable, permissions: 0o700)
        let controller = SandboxClaudeProcessController(root: directory.root, fakeClaudeExecutable: executable,
                                                       verificationTimeout: .milliseconds(100))
        let profile = directory.root.appendingPathComponent("profile")
        do { _ = try await controller.launch(profile: profile, deepLink: nil); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? ClaudeProcessError, .launchFailed) }
        do {
            _ = try await controller.launch(profile: profile, deepLink: URL(string: "claude://invalid")!)
            XCTFail("Expected invalid link")
        } catch { XCTAssertEqual(error as? ClaudeProcessError, .invalidDeepLink) }
        let instances = try await controller.runningInstances()
        XCTAssertTrue(instances.isEmpty)
    }

    func testMonitorDetectsExternalLaunchWithNoEffectiveProfileFlag() async throws {
        let directory = try PlatformTestDirectory()
        defer { FakeClaudeTestCleanup(root: directory.root).stop(); directory.remove() }
        let executable = try binary(in: directory)
        let profile = AppPaths.sandbox(root: directory.root).claudeProfilesRoot.appendingPathComponent("Claude", isDirectory: true)
        let stream = SandboxLaunchMonitor(root: directory.root, fakeClaudeExecutable: executable).launches()
        let receiver = Task { try await nextEvent(stream) }
        let child = Process()
        child.executableURL = executable
        // FakeClaude requires a storage argument. After -- it is positional to the production argv parser.
        child.arguments = ["--", "--user-data-dir=\(profile.path)"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            receiver.cancel()
            if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        let event = try await receiver.value
        XCTAssertEqual(event.pid, child.processIdentifier)
        XCTAssertEqual(event.profileDirectory, ProfilePaths.canonical(profile))
        XCTAssertFalse(event.hasExplicitProfileFlag)
    }

    func testSandboxControllerRefusesExecutableOrProfileOutsideRoot() async throws {
        let directory = try PlatformTestDirectory()
        defer { FakeClaudeTestCleanup(root: directory.root).stop(); directory.remove() }
        let controller = SandboxClaudeProcessController(root: directory.root, fakeClaudeExecutable: URL(fileURLWithPath: "/outside/FakeClaude"))
        do { _ = try await controller.launch(profile: directory.root.appendingPathComponent("profile"), deepLink: nil); XCTFail() }
        catch { XCTAssertEqual(error as? SandboxAdapterError, .outsideSandbox) }
    }

    func testZeroQuitBudgetDoesNotSignalTheChild() async throws {
        let directory = try PlatformTestDirectory()
        defer { FakeClaudeTestCleanup(root: directory.root).stop(); directory.remove() }
        let executable = try binary(in: directory)
        let controller = SandboxClaudeProcessController(root: directory.root, fakeClaudeExecutable: executable)
        let instance = try await controller.launch(profile: directory.root.appendingPathComponent("profile"), deepLink: nil)
        do { _ = try await controller.quitAll(timeout: .zero); XCTFail("Expected exhausted budget") }
        catch { XCTAssertEqual(error as? ClaudeProcessError, .stillRunning(pids: [instance.pid], names: ["FakeClaude"], stall: .outOfTime)) }
        let remaining = try await controller.runningInstances()
        XCTAssertEqual(remaining.map(\.pid), [instance.pid])
        _ = try await controller.quitAll(timeout: .seconds(15))
    }

    func testLaunchVerificationAcceptsEitherDirectoryURLFormBeforeAndAfterCreation() async throws {
        let directory = try PlatformTestDirectory()
        defer { FakeClaudeTestCleanup(root: directory.root).stop(); directory.remove() }
        let executable = try binary(in: directory)
        let controller = SandboxClaudeProcessController(root: directory.root, fakeClaudeExecutable: executable,
                                                       verificationTimeout: .seconds(30))
        for createdBeforeLaunch in [false, true] {
            for directoryHint in [false, true] {
                let path = directory.root.appendingPathComponent("profile-\(createdBeforeLaunch)-\(directoryHint)").path
                let profile = URL(fileURLWithPath: path, isDirectory: directoryHint)
                XCTAssertEqual(profile.absoluteString.hasSuffix("/"), directoryHint)
                if createdBeforeLaunch {
                    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
                }
                let instance = try await controller.launch(profile: profile, deepLink: nil)
                XCTAssertTrue(ProfilePaths.same(instance.profileDirectory, profile))
                XCTAssertEqual(instance.profileDirectory, ProfilePaths.canonical(profile))
                let detected = try await controller.runningInstances()
                XCTAssertEqual(detected.first?.profileDirectory, ProfilePaths.canonical(profile))
                _ = try await controller.quitAll(timeout: .seconds(15))
            }
        }
    }

    func testZombieFakeClaudeDoesNotMakeRunningInstancesUnavailable() async throws {
        let directory = try PlatformTestDirectory()
        defer { FakeClaudeTestCleanup(root: directory.root).stop(); directory.remove() }
        let executable = try binary(in: directory)
        let profile = directory.root.appendingPathComponent("zombie")
        let child = try UnreapedFakeClaude(executable: executable, profile: profile)
        defer { child.stop() }
        try await waitForReadiness(pid: child.pid, profile: profile)
        child.terminate()
        try await waitForZombie(child)

        let controller = SandboxClaudeProcessController(root: directory.root, fakeClaudeExecutable: executable)
        let instances = try await controller.runningInstances()
        XCTAssertTrue(instances.isEmpty)
        XCTAssertTrue(child.isZombie)
    }

    func testLaunchSucceedsWhileOldInstanceExitsAndRemainsUnreaped() async throws {
        let directory = try PlatformTestDirectory()
        defer { FakeClaudeTestCleanup(root: directory.root).stop(); directory.remove() }
        let executable = try binary(in: directory)
        let oldProfile = directory.root.appendingPathComponent("exiting")
        let old = try UnreapedFakeClaude(executable: executable, profile: oldProfile,
                                        environment: ["FAKE_CLAUDE_QUIT_DELAY_MS": "100"])
        defer { old.stop() }
        try await waitForReadiness(pid: old.pid, profile: oldProfile)
        old.terminate()
        let controller = SandboxClaudeProcessController(root: directory.root, fakeClaudeExecutable: executable)
        let profile = directory.root.appendingPathComponent("new")
        let instance = try await controller.launch(profile: profile, deepLink: nil)
        try await waitForZombie(old)
        let instances = try await controller.runningInstances()
        XCTAssertEqual(instances.map(\.pid), [instance.pid])
        XCTAssertTrue(ProfilePaths.same(instance.profileDirectory, profile))
    }

    func testTeardownKillsAndReapsIgnoringMainAndHelpersWhenWorkThrows() async throws {
        enum Interrupted: Error { case fixture }
        let directory = try PlatformTestDirectory()
        defer { FakeClaudeTestCleanup(root: directory.root).stop(); directory.remove() }
        let executable = try binary(in: directory)
        let controller = SandboxClaudeProcessController(root: directory.root, fakeClaudeExecutable: executable,
            environment: ["FAKE_CLAUDE_IGNORE_TERM": "1", "FAKE_CLAUDE_SPAWN_CHILD": "1", "FAKE_CLAUDE_KEEP_GRANDCHILD": "1"])
        var launchedPID: Int32?
        do {
            defer { FakeClaudeTestCleanup(root: directory.root).stop() }
            let instance = try await controller.launch(profile: directory.root.appendingPathComponent("interrupted"), deepLink: nil)
            launchedPID = instance.pid
            throw Interrupted.fixture
        } catch Interrupted.fixture {}
        let pid = try XCTUnwrap(launchedPID)
        XCTAssertNil(ProcessTable().closingProcess(pid: pid))
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
        let remaining = try ProcessTable().closingProcesses().filter {
            $0.identity.executable.path.hasPrefix(directory.root.resolvingSymlinksInPath().path + "/")
        }
        XCTAssertTrue(remaining.isEmpty)
    }

    private func waitForReadiness(pid: Int32, profile: URL) async throws {
        struct Ready: Decodable { let pid: Int32 }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let data = try? Data(contentsOf: profile.appendingPathComponent(".fake-claude/instance.json")),
               let ready = try? JSONDecoder().decode(Ready.self, from: data), ready.pid == pid { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("FakeClaude did not become ready")
        throw ClaudeProcessError.launchFailed
    }

    private func waitForZombie(_ child: UnreapedFakeClaude) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if child.isZombie { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("FakeClaude did not exit")
        throw ClaudeProcessError.launchFailed
    }
}

private func nextEvent(_ stream: AsyncStream<LaunchEvent>) async throws -> LaunchEvent {
    try await withThrowingTaskGroup(of: LaunchEvent.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            guard let event = await iterator.next() else { throw CancellationError() }
            return event
        }
        group.addTask {
            try await Task.sleep(for: .seconds(30))
            throw ClaudeProcessError.launchFailed
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
