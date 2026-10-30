import Darwin
import Foundation

private let userDataDirFlag = "--user-data-dir"
private let quitDelayVariable = "FAKE_CLAUDE_QUIT_DELAY_MS"
private let ignoreTermVariable = "FAKE_CLAUDE_IGNORE_TERM"

private struct ParsedArguments {
    var profilePath: String?
    var urls: [String] = []
    var role = "main"
}

private struct InstanceRecord: Encodable {
    var pid: Int32
    var startedAt: String
    var argv: [String]
}

private final class Shutdown: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private let stateDirectory: URL
    private let delayMilliseconds: Int
    private let role: String
    private let family: HelperFamily

    init(stateDirectory: URL, delayMilliseconds: Int, role: String, family: HelperFamily) {
        self.stateDirectory = stateDirectory
        self.delayMilliseconds = delayMilliseconds
        self.role = role
        self.family = family
    }

    func perform() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        if delayMilliseconds > 0 {
            Thread.sleep(forTimeInterval: Double(delayMilliseconds) / 1000)
        }

        family.stop()
        let events = stateDirectory.appending(path: role == "main" ? "events.log" : "\(role)-events.log")
        let instance = stateDirectory.appending(path: role == "main" ? "instance.json" : "\(role).json")
        do {
            try append(text: "quit \(iso8601Now())\n", to: events)
            if FileManager.default.fileExists(atPath: instance.path) {
                try FileManager.default.removeItem(at: instance)
            }
        } catch {
            fputs("FakeClaude: could not record shutdown: \(error)\n", stderr)
            exit(1)
        }
        exit(0)
    }
}

/// Helper modes are confined to an explicitly supplied sandbox. The helper uses
/// a different executable path so it cannot be mistaken for another main instance.
private final class HelperFamily: @unchecked Sendable {
    private let child: Process?
    private let orphan: Bool

    init(profile: URL, role: String, environment: [String: String]) throws {
        orphan = environment["FAKE_CLAUDE_ORPHAN_CHILD"] == "1"
        let spawn = role == "main" ? environment["FAKE_CLAUDE_SPAWN_CHILD"] == "1"
            : role == "child" && environment["FAKE_CLAUDE_KEEP_GRANDCHILD"] == "1"
        guard spawn else { child = nil; return }
        guard let rootPath = environment["FAKE_CLAUDE_SANDBOX_ROOT"] else { throw CocoaError(.fileWriteNoPermission) }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let state = profile.appending(path: ".fake-claude", directoryHint: .isDirectory)
        let helperFolder = role == "main" ? source.deletingLastPathComponent().appending(path: "Helpers", directoryHint: .isDirectory)
            : source.deletingLastPathComponent()
        let target = helperFolder.appending(path: "FakeClaudeHelper")
        guard root.path != "/", [profile, state, source, target].allSatisfy({
            $0.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/")
        }) else { throw CocoaError(.fileWriteNoPermission) }
        if role == "main", !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.createDirectory(at: helperFolder, withIntermediateDirectories: true)
            let staged = helperFolder.appending(path: "helper-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: source, to: staged)
            defer { try? FileManager.default.removeItem(at: staged) }
            guard Darwin.rename(staged.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        let nextRole = role == "main" ? "child" : "grandchild"
        let process = Process()
        process.executableURL = target
        process.arguments = ["--user-data-dir=\(profile.path)", "--fake-role=\(nextRole)"]
        process.currentDirectoryURL = root
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        child = process
        let ready = state.appending(path: "\(nextRole).json")
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline {
            if let data = try? Data(contentsOf: ready),
               let record = try? JSONDecoder().decode(HelperReadiness.self, from: data),
               record.pid == process.processIdentifier { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        throw CocoaError(.fileReadUnknown)
    }

    func stop() {
        guard !orphan, let child, child.isRunning else { return }
        child.terminate()
        let deadline = Date().addingTimeInterval(0.5)
        while child.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
    }

    private struct HelperReadiness: Decodable { let pid: Int32 }
}

private func main() {
    let parsed = parse(arguments: CommandLine.arguments)
    guard let profilePath = parsed.profilePath, !profilePath.isEmpty else {
        fputs("FakeClaude: expected --user-data-dir=<path>\n", stderr)
        exit(2)
    }

    let profile = URL(fileURLWithPath: profilePath, isDirectory: true)
    let environment = ProcessInfo.processInfo.environment
    guard validSandbox(profile: profile, role: parsed.role, environment: environment) else {
        fputs("FakeClaude: helper mode requires sandbox paths\n", stderr)
        exit(2)
    }
    if environment["FAKE_CLAUDE_SANDBOX_ROOT"] != nil,
       FileManager.default.fileExists(atPath: profile.appending(path: ".fake-claude/fail-launch").path) {
        exit(3)
    }
    let stateDirectory = profile.appending(path: ".fake-claude", directoryHint: .isDirectory)
    do {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        if !parsed.urls.isEmpty {
            let lines = parsed.urls.map { $0 + "\n" }.joined()
            try append(text: lines, to: stateDirectory.appending(path: "deeplinks.log"))
        }
    } catch {
        fputs("FakeClaude: could not prepare the profile: \(error)\n", stderr)
        exit(1)
    }

    let family: HelperFamily
    do { family = try HelperFamily(profile: profile, role: parsed.role, environment: environment) }
    catch { fputs("FakeClaude: could not prepare helpers\n", stderr); exit(1) }
    let delay = parsed.role == "main" ? Int(environment[quitDelayVariable] ?? "") ?? 0 : 0
    let ignoreTerm = environment[ignoreTermVariable] == "1" ||
        (parsed.role != "main" && environment["FAKE_CLAUDE_CHILD_IGNORE_TERM"] == "1")
    let shutdown = Shutdown(stateDirectory: stateDirectory, delayMilliseconds: max(0, delay), role: parsed.role, family: family)
    let sources = installSignalHandlers(ignoreTerm: ignoreTerm, shutdown: shutdown)
    let parentWatcher = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "fake-claude.parent"))
    let originalParent = getppid()
    if parsed.role != "main", environment["FAKE_CLAUDE_ORPHAN_CHILD"] != "1" {
        parentWatcher.schedule(deadline: .now(), repeating: .milliseconds(50))
        parentWatcher.setEventHandler { if getppid() != originalParent { shutdown.perform() } }
        parentWatcher.resume()
    } else { parentWatcher.cancel(); parentWatcher.resume() }

    let record = InstanceRecord(
        pid: ProcessInfo.processInfo.processIdentifier,
        startedAt: iso8601Now(),
        argv: CommandLine.arguments
    )
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        let filename = parsed.role == "main" ? "instance.json" : "\(parsed.role).json"
        try data.write(to: stateDirectory.appending(path: filename), options: .atomic)
    } catch {
        fputs("FakeClaude: could not write instance.json: \(error)\n", stderr)
        exit(1)
    }

    withExtendedLifetime((sources, family, parentWatcher)) {
        Thread.sleep(until: .distantFuture)
    }
}

private func validSandbox(profile: URL, role: String, environment: [String: String]) -> Bool {
    let helperMode = role != "main" || ["FAKE_CLAUDE_SPAWN_CHILD", "FAKE_CLAUDE_KEEP_GRANDCHILD",
        "FAKE_CLAUDE_ORPHAN_CHILD", "FAKE_CLAUDE_CHILD_IGNORE_TERM"].contains { environment[$0] == "1" }
    guard helperMode || environment["FAKE_CLAUDE_SANDBOX_ROOT"] != nil else { return true }
    guard let rootPath = environment["FAKE_CLAUDE_SANDBOX_ROOT"], rootPath.hasPrefix("/"),
          ["main", "child", "grandchild"].contains(role) else { return false }
    let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath().path
    guard root != "/", profile.path.hasPrefix("/") else { return false }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
    return [profile, profile.appending(path: ".fake-claude"), executable].allSatisfy {
        $0.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root + "/")
    }
}

/// Electron-style: `--user-data-dir=<path>` or `--user-data-dir <path>`.
/// Flags we do not understand are skipped. Everything else is a deep link.
private func parse(arguments: [String]) -> ParsedArguments {
    var parsed = ParsedArguments()
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        if argument == userDataDirFlag {
            let next = index + 1
            if next < arguments.count {
                parsed.profilePath = arguments[next]
                index = next
            }
        } else if argument.hasPrefix(userDataDirFlag + "=") {
            parsed.profilePath = String(argument.dropFirst(userDataDirFlag.count + 1))
        } else if argument.hasPrefix("--fake-role=") {
            parsed.role = String(argument.dropFirst("--fake-role=".count))
        } else if argument.hasPrefix("-"), argument.count > 1 {
            // Unknown switch. Leave the following token alone; it may be a URL.
        } else if !argument.isEmpty {
            parsed.urls.append(argument)
        }
        index += 1
    }
    if parsed.profilePath == nil {
        parsed.profilePath = ProcessInfo.processInfo.environment["FAKE_CLAUDE_DEFAULT_PROFILE"]
    }
    return parsed
}

private func installSignalHandlers(ignoreTerm: Bool, shutdown: Shutdown) -> [DispatchSourceSignal] {
    let queue = DispatchQueue(label: "fake-claude.signals")
    var sources: [DispatchSourceSignal] = []

    // DispatchSource only observes a signal after the default terminate action is ignored.
    if ignoreTerm {
        _ = Darwin.signal(SIGTERM, SIG_IGN)
    } else {
        sources.append(makeSource(signal: SIGTERM, queue: queue, shutdown: shutdown))
    }
    sources.append(makeSource(signal: SIGINT, queue: queue, shutdown: shutdown))
    return sources
}

private func makeSource(
    signal: Int32,
    queue: DispatchQueue,
    shutdown: Shutdown
) -> DispatchSourceSignal {
    _ = Darwin.signal(signal, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signal, queue: queue)
    source.setEventHandler {
        shutdown.perform()
    }
    source.resume()
    return source
}

/// Appends a log line. A temp-file rename would drop a line written while shutdown runs.
private func append(text: String, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

private func iso8601Now() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
}

main()
