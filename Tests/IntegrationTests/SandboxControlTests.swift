import CompanionCore
import CompanionPlatform
import Foundation
import XCTest
@testable import CCRelay

@MainActor
final class SandboxControlTests: XCTestCase {
    private func harness() throws -> IntegrationHarness {
        let h = try IntegrationHarness()
        addTeardownBlock { await h.cleanup() }
        return h
    }

    func testSignInCommandCompletesPendingAccountThroughFixtureCookieAndHTTP() async throws {
        let h = try harness()
        try await h.start(launch: nil)
        await h.engine.perform(.addAccount)
        let folder = try require((await h.snapshot()).pendingAdd?.folder)
        let result = try control(h, ["sign-in", folder.name, "explorer@example.com"])
        expectEqual(result.status, 0)
        expectEqual(result.output, "Signed in \(folder.name).\n")
        let config = try ProfileConfigReader().read(profile: h.directory(folder.name))
        expectTrue(UUID(uuidString: try require(config.accountUUID)) != nil)
        expectTrue(UUID(uuidString: try require(config.activeOrganizationUUID)) != nil)
        let cookie = try require(SandboxSessionCookieReader(root: h.root).sessionCookie(profile: h.directory(folder.name)))
        expectEqual(cookie.databaseVersion, 24)
        expectNil(cookie.plaintextValue)
        let plaintext = try await ChromiumCookieDecryptor().open(cookie, password: ChromiumCookieEncryptor.fixturePassword)
        expectEqual(plaintext, "sandbox-" + folder.name)
        await h.engine.checkPendingSignIns()
        let account = try require((await h.snapshot()).accounts.first { $0.folder == folder })
        expectEqual(account.displayName, "explorer")
        expectEqual(account.email, "explorer@example.com")
        expectTrue(try h.state().pendingSignIns.isEmpty)
    }

    func testSignInUsesDefaultEmailAndRefusesAnExistingAccount() async throws {
        let h = try harness()
        try await h.start(launch: nil)
        expectNotEqual(try control(h, ["sign-in", "Claude"]).status, 0)
        await h.engine.perform(.addAccount)
        let folder = try require((await h.snapshot()).pendingAdd?.folder)
        expectEqual(try control(h, ["sign-in", folder.name]).status, 0)
        let signedConfig = try Data(contentsOf: h.directory(folder.name).appendingPathComponent("config.json"))
        expectNotEqual(try control(h, ["sign-in", folder.name, "again@example.com"]).status, 0)
        expectEqual(try Data(contentsOf: h.directory(folder.name).appendingPathComponent("config.json")), signedConfig)
        await h.engine.checkPendingSignIns()
        expectEqual((await h.snapshot()).accounts.first { $0.folder == folder }?.email, "sandbox.user@example.com")
    }

    func testTaskCommandsDriveBusyWaitThenIdleSwitch() async throws {
        let h = try harness()
        try await h.start()
        expectEqual(try control(h, ["task", "busy"]).output, "Task busy.\n")
        let work = Task { await h.engine.perform(.switchTo(folder: try h.folder("Claude_204"))) }
        try await waitFor { (await h.snapshot()).taskGuardPrompt?.busyCount == 1 }
        await h.engine.perform(.taskGuard(.waitThenSwitch))
        try await waitFor { (await h.snapshot()).taskGuardPrompt?.isWaiting == true }
        expectEqual(try control(h, ["task", "idle"]).output, "Task idle.\n")
        try await work.value
        expectEqual((await h.snapshot()).currentFolder?.name, "Claude_204")
    }

    func testOpenDefaultAndStatusExposeFlaglessLaunchBeforeAutomaticCorrection() async throws {
        let h = try harness()
        let result = try control(h, ["open-default"])
        expectEqual(result.status, 0)
        expectTrue(result.output.hasPrefix("Default launch requested (pid "))
        let status = try decodedStatus(control(h, ["status"]))
        expectTrue(status.pendingSignIns.isEmpty)
        expectEqual(status.runningInstances.map(\.folder), ["Claude"])
        expectEqual(status.runningInstances.map(\.hasExplicitProfileFlag), [false])
        try await h.start(launch: nil)
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        expectEqual(try control(h, ["open-default"]).status, 0)
        try await waitFor { (await h.snapshot()).banners.contains(.autoCorrected(to: try h.folder("Claude_204"))) }
        let corrected = try decodedStatus(control(h, ["status"]))
        expectTrue(corrected.runningInstances.allSatisfy { $0.folder == "Claude_204" && $0.hasExplicitProfileFlag })
    }

    func testStatusListsPendingSignInAndRunningTarget() async throws {
        let h = try harness()
        try await h.start(launch: nil)
        await h.engine.perform(.addAccount)
        let pending = try require((await h.snapshot()).pendingAdd?.folder)
        let status = try decodedStatus(control(h, ["status"]))
        expectEqual(status.pendingSignIns, [pending.name])
        expectEqual(status.runningInstances.map(\.folder), [pending.name])
        expectEqual(status.runningInstances.map(\.hasExplicitProfileFlag), [true])
    }

    func testFailLaunchCommandTriggersRecoveryAndCanBeDisabled() async throws {
        let h = try harness()
        try await h.start()
        expectEqual(try control(h, ["fail-launch", "Claude_204", "on"]).output, "Launch failure on for Claude_204.\n")
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        expectEqual((await h.snapshot()).lastResult?.outcome,
            .failed(operation: .switchTo(try h.folder("Claude_204")), reason: .returnedToPreviousAccount))
        expectEqual(try control(h, ["fail-launch", "Claude_204", "off"]).output, "Launch failure off for Claude_204.\n")
        await h.engine.perform(.switchTo(folder: try h.folder("Claude_204")))
        expectEqual((await h.snapshot()).currentFolder?.name, "Claude_204")
    }

    func testEveryCommandRefusesAnUngeneratedRootWithoutWritingIt() async throws {
        let h = try harness()
        let manifest = h.root.appendingPathComponent("sandbox.json")
        try FileManager.default.moveItem(at: manifest, to: h.root.appendingPathComponent("saved-manifest.json"))
        let before = try FileManager.default.subpathsOfDirectory(atPath: h.root.path).sorted()
        for command in [["sign-in", "Claude"], ["task", "busy"], ["open-default"],
                        ["fail-launch", "Claude", "on"], ["status"]] {
            let result = try control(h, command)
            expectNotEqual(result.status, 0)
            expectTrue(result.output.contains("expected a generated sandbox"))
        }
        expectEqual(try FileManager.default.subpathsOfDirectory(atPath: h.root.path).sorted(), before)
        expectTrue(try await h.services.processes.runningInstances().isEmpty)
    }

    func testCommandsRefuseSymlinkEscapesAndInvalidArguments() throws {
        let h = try harness()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("sandbox-control-outside-\(UUID().uuidString)")
        try AtomicFile.write(Data("keep".utf8), to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let taskState = h.root.appendingPathComponent("task-state.json")
        try FileManager.default.moveItem(at: taskState, to: h.root.appendingPathComponent("saved-task-state.json"))
        try FileManager.default.createSymbolicLink(at: taskState, withDestinationURL: outside)
        expectNotEqual(try control(h, ["task", "busy"]).status, 0)
        expectEqual(try Data(contentsOf: outside), Data("keep".utf8))
        for command in [["fail-launch", "../escape", "on"], ["task", "maybe"],
                        ["status", "extra"], ["open-default", "extra"], ["sign-in"], ["unknown"]] {
            expectNotEqual(try control(h, command).status, 0)
        }
    }

    private func control(_ h: IntegrationHarness, _ arguments: [String]) throws -> ControlResult {
        let child = Process()
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        child.executableURL = products.appendingPathComponent("CCRelay")
        child.arguments = ["--sandbox-control", h.root.path] + arguments
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        try child.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        expectEqual(text.split(separator: "\n").count, 1)
        return ControlResult(status: child.terminationStatus, output: text)
    }

    private func decodedStatus(_ result: ControlResult) throws -> ControlStatus {
        expectEqual(result.status, 0)
        return try JSONDecoder().decode(ControlStatus.self, from: Data(result.output.utf8))
    }

    private struct ControlResult { let status: Int32; let output: String }
    private struct ControlStatus: Decodable {
        let pendingSignIns: [String]
        let runningInstances: [Instance]
        struct Instance: Decodable { let pid: Int32; let folder: String; let hasExplicitProfileFlag: Bool }
    }
}
