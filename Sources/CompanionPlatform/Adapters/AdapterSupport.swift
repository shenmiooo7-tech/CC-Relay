import CompanionCore
import Foundation

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

enum InstanceMapping {
    static func instance(_ record: ProcessRecord, mainExecutable: URL, defaultProfile: URL) throws -> ClaudeInstance? {
        guard record.executableURL.standardizedFileURL == mainExecutable.standardizedFileURL else { return nil }
        let explicit = try ClaudeArguments.profileDirectory(in: record.argv)
        return ClaudeInstance(pid: record.pid, profileDirectory: ProfilePaths.canonical(explicit ?? defaultProfile),
                              hasExplicitProfileFlag: explicit != nil, startedAt: record.startedAt,
                              executableURL: record.executableURL)
    }

    static func event(_ instance: ClaudeInstance) -> LaunchEvent {
        LaunchEvent(pid: instance.pid, profileDirectory: ProfilePaths.canonical(instance.profileDirectory),
                    hasExplicitProfileFlag: instance.hasExplicitProfileFlag)
    }
}

enum DeepLinkValidation {
    static func validate(_ url: URL?) throws {
        guard let url else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "claude", components.host == "code", components.path == "/continue",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil, let items = components.queryItems, items.count == 1,
              items[0].name == "session", let id = items[0].value,
              id.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil
        else { throw ClaudeProcessError.invalidDeepLink }
    }
}

struct AdapterPolling: Sendable {
    let clock: any CompanionCore.Clock
    let interval: Duration

    init(clock: any CompanionCore.Clock = SystemClock(), interval: Duration = .milliseconds(250)) {
        self.clock = clock
        self.interval = interval
    }

    func until(_ deadline: Date, isolation: isolated (any Actor)? = #isolation,
               condition: () async throws -> Bool) async throws -> Bool {
        while true {
            try Task.checkCancellation()
            if try await condition() { return true }
            let remaining = deadline.timeIntervalSince(clock.now())
            if remaining <= 0 { return false }
            try await clock.sleep(for: .seconds(min(interval.timeInterval, remaining)))
        }
    }
}

public enum SandboxAdapterError: Error, Equatable, Sendable {
    case outsideSandbox
    case invalidExecutable
    case invalidState
}

struct SandboxBoundary: Sendable {
    let root: URL

    func check(_ url: URL) throws {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.isFileURL, base != "/", candidate.hasPrefix(base + "/") else {
            throw SandboxAdapterError.outsideSandbox
        }
        // Foundation does not resolve a dangling final symlink. Reject links within a sandbox
        // rather than following a future target that might later become a real user path.
        var current = url.standardizedFileURL
        let lexicalRoot = root.standardizedFileURL.path
        while current.path != lexicalRoot, current.path != "/" {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw SandboxAdapterError.outsideSandbox
            }
            current.deleteLastPathComponent()
        }
    }
}
