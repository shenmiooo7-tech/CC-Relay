import CompanionCore
import CompanionPlatform
import Darwin
import Foundation
import XCTest
@testable import CCRelay

final class IntegrationClock: CompanionCore.Clock, @unchecked Sendable {
    private let origin = Date()
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    private let factor = 4.0

    func now() -> Date {
        lock.withLock { origin.addingTimeInterval(Date().timeIntervalSince(origin) * factor + offset) }
    }
    func advance(_ seconds: TimeInterval) { lock.withLock { offset += seconds } }
    func sleep(for duration: Duration) async throws {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        try await Task.sleep(for: .seconds(seconds / factor))
    }
}

@MainActor
final class IntegrationHarness {
    let root: URL
    let world: SandboxWorld
    let services: AppServices
    let clock: IntegrationClock
    private var external: [Process] = []

    init(environment: [String: String] = [:], autoPoll: Bool = false,
         onQuit: @escaping @Sendable () async -> Void = {}) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cc-relay-integration-\(UUID().uuidString)", isDirectory: true)
        let products = Bundle(for: FullStackTests.self).bundleURL.deletingLastPathComponent()
        world = try SandboxWorldGenerator.generate(at: root, fakeClaude: products.appendingPathComponent("FakeClaude"))
        clock = IntegrationClock()
        services = try AppServices.sandbox(root: world.root, processEnvironment: environment,
            clock: clock, automaticallyPoll: autoPoll, verificationTimeout: .seconds(12), onQuit: onQuit)
    }

    var engine: CompanionEngine { services.engine }
    func folder(_ name: String) throws -> ProfileFolder { try ProfileFolder(name) }
    func directory(_ name: String) -> URL { world.profileDirectory(name) }
    func snapshot() async -> CompanionSnapshot { await engine.currentSnapshot() }

    func start(launch: String? = "Claude") async throws {
        if let launch { _ = try await services.processes.launch(profile: directory(launch), deepLink: nil) }
        await engine.start()
    }

    func state() throws -> CompanionState {
        try StableJSON.decode(CompanionState.self, from: Data(contentsOf: world.paths.companionDataDirectory.appendingPathComponent("state.json")))
    }

    func profiles() throws -> [ProfileSnapshot] {
        try ProfileScanner(paths: world.paths).scan(managed: state().accounts.map(\.folder)).profiles
    }

    func session(_ name: String, id: String) throws -> URL {
        let profile = try require(profiles().first { $0.folder.name == name })
        return profile.url.appendingPathComponent(try require(profile.readableBucket).relativePath).appendingPathComponent(id + ".json")
    }

    func setTasks(busy: Bool) throws {
        let state: [String: Any] = busy ? ["status": "busy", "tasks": [["pid": 12345]]] : ["status": "idle"]
        try writeJSON(state, to: root.appendingPathComponent("task-state.json"))
    }

    func launchFlagless() throws -> Process {
        let child = Process()
        child.executableURL = SandboxWorldGenerator.fakeClaudeExecutable(root: world.root)
        child.arguments = []
        child.currentDirectoryURL = root
        child.environment = ProcessInfo.processInfo.environment.merging([
            "FAKE_CLAUDE_SANDBOX_ROOT": world.root.path,
            "FAKE_CLAUDE_DEFAULT_PROFILE": directory("Claude").path,
        ], uniquingKeysWith: { _, value in value })
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        external.append(child)
        return child
    }

    func cleanup() async {
        await engine.perform(.quitApp)
        // Paths arrive as /var/… (resolved URLs) or /private/var/… (raw process table); accept both.
        let prefixes = [world.root.standardizedFileURL.resolvingSymlinksInPath().path + "/",
                        Self.canonicalPath(world.root) + "/"].filter { $0 != "//" }
        let table = ProcessTable()
        let deadline = Date().addingTimeInterval(8)
        repeat {
            do {
                let owned = try table.checkedProcesses {
                    let path = $0.path
                    return prefixes.contains { path.hasPrefix($0) } && ["FakeClaude", "FakeClaudeHelper"].contains($0.lastPathComponent)
                }
                for process in owned.reversed() {
                    guard let current = table.record(pid: process.pid), current.startedAt == process.startedAt,
                          current.executableURL == process.executableURL else { continue }
                    _ = Darwin.kill(process.pid, SIGKILL)
                }
                if owned.isEmpty {
                    for child in external { child.waitUntilExit() }
                    try FileManager.default.removeItem(at: root)
                    return
                }
            } catch { XCTFail("Sandbox cleanup failed: \(error)"); return }
            try? await Task.sleep(for: .milliseconds(25))
        } while Date() < deadline
        XCTFail("Sandbox processes survived cleanup")
    }

    private static func canonicalPath(_ url: URL) -> String {
        guard let resolved = Darwin.realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

func writeJSON(_ object: Any, to url: URL) throws {
    try AtomicFile.write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: url)
}

@MainActor
func waitFor(_ condition: () async throws -> Bool, timeout: TimeInterval = 10,
             file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    } while Date() < deadline
    XCTFail("Timed out waiting for sandbox state", file: file, line: line)
    throw WaitFailure.timeout
}
private enum WaitFailure: Error { case timeout }
