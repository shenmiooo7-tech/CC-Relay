import CompanionCore
import Foundation

struct ClosingIdentity: Hashable, Sendable {
    let pid: Int32
    let startedAt: Date
    let executable: URL

    init(pid: Int32, startedAt: Date, executable: URL) {
        self.pid = pid
        self.startedAt = startedAt
        self.executable = executable.standardizedFileURL
    }
}

struct ClosingProcess: Sendable {
    let identity: ClosingIdentity
    let parent: Int32
    let isZombie: Bool
}

enum ClosingSignal: Sendable { case terminate, force }

/// Only the adapters know how to observe or affect the OS. A close owns identities,
/// rather than PIDs, so reparenting preserves ownership and PID reuse does not.
struct ClaudeClosingEngine: Sendable {
    let mainExecutable: URL
    let defaultProfile: URL
    let isBundleExecutable: @Sendable (URL) -> Bool
    let readTable: @Sendable () throws -> [ClosingProcess]
    let readArguments: @Sendable (ClosingIdentity) throws -> [String]
    let normalQuit: @Sendable (ClosingIdentity) async throws -> Void
    let normalQuitOutcome: QuitOutcome
    let signal: @Sendable (ClosingIdentity, ClosingSignal, Bool) async throws -> Void
    let clock: any CompanionCore.Clock
    var reportReopened: @Sendable ([ClosingProcess], [ClosingIdentity]) -> Void = { _, _ in }

    func close(timeout: Duration, instance: ClaudeInstance? = nil, immediately: Bool = false,
               beforeForce: @escaping @Sendable () async -> Bool) async throws -> QuitOutcome {
        if let instance, instance.executableURL.standardizedFileURL != mainExecutable.standardizedFileURL {
            throw ClaudeProcessError.processTableUnavailable
        }
        let selected = instance.map { ClosingIdentity(pid: $0.pid, startedAt: $0.startedAt, executable: $0.executableURL) }
        var session = ClosingSession(engine: self, deadline: clock.now().addingTimeInterval(max(0, timeout.timeInterval)),
                                     selected: selected)
        return try await session.close(immediately: immediately, beforeForce: beforeForce)
    }

    /// Chromium's crash reporter runs detached from the app (its parent is launchd). On its own it
    /// holds no session and runs no task, so it does not make Claude count as open; `close` still
    /// takes it along.
    static let crashReporter = "chrome_crashpad_handler"

    /// The same first step as `close`: there is work when a live bundle process other than the crash
    /// reporter exists. Processes outside the bundle only belong to a close through one of those.
    func hasProcesses() throws -> Bool {
        do {
            return try readTable().contains { process in
                !process.isZombie && isBundleExecutable(process.identity.executable) &&
                    process.identity.executable.lastPathComponent != Self.crashReporter
            }
        } catch { throw ClaudeProcessError.processTableUnavailable }
    }

    /// The profiles the processes `hasProcesses` counts are using, attributed as a close does, and
    /// whether one of them could not be tied to any. Nothing is signalled.
    func profilesInUse() throws -> ProfilesInUse {
        var session = ClosingSession(engine: self, deadline: clock.now(), selected: nil)
        return try session.profilesInUse()
    }
}

private struct ClosingMember {
    let identity: ClosingIdentity
    var profile: URL?
}

private struct ClosingSession {
    let engine: ClaudeClosingEngine
    let deadline: Date
    let selected: ClosingIdentity?
    var observedMains: Set<ClosingIdentity> = []
    var members: [Int32: ClosingMember] = [:]
    var initialMains: Set<ClosingIdentity> = []
    var initialProfiles: Set<URL> = []
    var current: [Int32: ClosingProcess] = [:]
    var argumentCache: [ClosingIdentity: [String]] = [:]
    var outcome = QuitOutcome.quit

    mutating func close(immediately: Bool, beforeForce: @escaping @Sendable () async -> Bool) async throws -> QuitOutcome {
        current = try table()
        observedMains = Set(current.values.filter(isMain).map(\.identity))
        initialMains = Set(observedMains.filter { selected == nil || $0 == selected })
        addDescendants(initial: true)
        initialProfiles = Set(members.values.compactMap(\.profile))
        if members.isEmpty { return .alreadyStopped }
        try requireBudget()

        // Asked to close at once, nothing waits on Claude's own quit and its confirmation.
        if !immediately {
            for identity in initialMains.sorted(by: { $0.pid < $1.pid }) {
                try await send(identity, normal: true)
            }
            _ = try await poll(seconds: 20, mainsOnly: true)
            if survivors().isEmpty { return outcome }
            try requireBudget()
            for member in survivors().filter({ isMain($0) }) {
                try await send(member.identity, normal: false, signal: .terminate)
            }
            // Orphaned helpers receive this grace even when no main survived normal quit.
            if try await poll(seconds: 5) { return outcome }
            try requireBudget()
        }
        let allowed = await beforeForce()
        try await refresh()
        // What ended during the check needs no forcing, whatever the check said.
        if survivors().isEmpty { return outcome }
        guard allowed else { throw failure(.notForced) }
        try requireBudget()

        if try await poll(seconds: 3, forcing: true) { return outcome }
        throw failure(.survivedForce)
    }

    mutating func profilesInUse() throws -> ProfilesInUse {
        current = try table()
        var profiles: Set<URL> = []
        var unattributed = false
        for process in current.values where engine.isBundleExecutable(process.identity.executable) &&
            process.identity.executable.lastPathComponent != ClaudeClosingEngine.crashReporter {
            if let profile = profile(for: process) { profiles.insert(profile) } else { unattributed = true }
        }
        return ProfilesInUse(profiles: profiles.sorted { $0.path < $1.path }, unattributed: unattributed)
    }

    private func isMain(_ process: ClosingProcess) -> Bool {
        process.identity.executable == engine.mainExecutable.standardizedFileURL
    }

    private func table() throws -> [Int32: ClosingProcess] {
        do {
            return Dictionary(try engine.readTable().filter { !$0.isZombie }.map { ($0.identity.pid, $0) },
                              uniquingKeysWith: { _, latest in latest })
        } catch { throw ClaudeProcessError.processTableUnavailable }
    }

    private mutating func refresh() async throws {
        try Task.checkCancellation()
        current = try table()
        var reopened = current.values.filter { isMain($0) && !observedMains.contains($0.identity) }
        // A fork briefly reports its parent's executable before exec. Only children of
        // identities already owned by this close get one short confirmation, with no
        // signals sent in between. Independent or persistent new mains still stop it.
        let forks = reopened.compactMap { process -> ClosingMember? in
            guard let parent = current[process.parent], let owned = members[parent.identity.pid],
                  owned.identity == parent.identity else { return nil }
            return ClosingMember(identity: process.identity, profile: owned.profile)
        }
        if !forks.isEmpty, forks.count == reopened.count, engine.clock.now() < deadline {
            try await engine.clock.sleep(for: .seconds(max(0, min(0.05, deadline.timeIntervalSince(engine.clock.now())))))
            try Task.checkCancellation()
            current = try table()
            for fork in forks {
                guard let child = current[fork.identity.pid], child.identity.startedAt == fork.identity.startedAt,
                      !isMain(child), members[child.identity.pid] == nil else { continue }
                // Keep its proven ancestry if the original parent exited during exec.
                members[child.identity.pid] = ClosingMember(identity: child.identity, profile: fork.profile)
            }
            reopened = current.values.filter { isMain($0) && !observedMains.contains($0.identity) }
        }
        addDescendants(initial: false)
        if !reopened.isEmpty {
            engine.reportReopened(reopened, Array(observedMains))
            throw failure(.reopened)
        }
    }

    private mutating func addDescendants(initial: Bool) {
        var pending = Array(current.values)
        var changed = true
        while changed {
            changed = false
            pending.removeAll { process in
                guard members[process.identity.pid] == nil else { return true }
                // A reopened main must not be admitted even if it is a child of an old member.
                guard !isMain(process) || initialMains.contains(process.identity) else { return true }
                let parent = current[process.parent]
                let ownedParent = parent.map { members[$0.identity.pid]?.identity == $0.identity } ?? false
                let root = selected.map { process.identity == $0 } ?? engine.isBundleExecutable(process.identity.executable)
                guard (initial && root) || ownedParent else { return false }
                members[process.identity.pid] = ClosingMember(identity: process.identity, profile: profile(for: process))
                changed = true
                return true
            }
        }
    }

    private mutating func profile(for process: ClosingProcess) -> URL? {
        var cursor: ClosingProcess? = process
        var visited: Set<Int32> = []
        while let entry = cursor, visited.insert(entry.identity.pid).inserted {
            if engine.isBundleExecutable(entry.identity.executable) {
                let arguments: [String]?
                if let cached = argumentCache[entry.identity] { arguments = cached }
                else {
                    arguments = try? engine.readArguments(entry.identity)
                    argumentCache[entry.identity] = arguments
                }
                if let arguments {
                    do {
                        if let explicit = try ClaudeArguments.profileDirectory(in: arguments) {
                            return ProfilePaths.canonical(explicit)
                        }
                        if isMain(entry) { return ProfilePaths.canonical(engine.defaultProfile) }
                        for argument in arguments.prefix(while: { $0 != "--" }) where argument.hasPrefix("--database=") {
                            let path = String(argument.dropFirst("--database=".count))
                            guard path.hasPrefix("/"), !path.contains("\0") else { continue }
                            let database = URL(fileURLWithPath: path).standardizedFileURL
                            if database.lastPathComponent == "Crashpad" {
                                return ProfilePaths.canonical(database.deletingLastPathComponent())
                            }
                        }
                    } catch {
                        // A malformed flag is not evidence that the default profile is in use.
                    }
                }
            }
            if let known = members[entry.identity.pid], known.identity == entry.identity, let profile = known.profile {
                return profile
            }
            cursor = current[entry.parent]
        }
        return nil
    }

    private func survivors() -> [ClosingProcess] {
        current.values.filter { members[$0.identity.pid]?.identity == $0.identity }.sorted {
            if isMain($0) != isMain($1) { return isMain($0) }
            return $0.identity.pid < $1.identity.pid
        }
    }

    private mutating func failure(_ stall: ClaudeProcessError.CloseStall) -> ClaudeProcessError {
        let remaining = current.values.filter {
            members[$0.identity.pid]?.identity == $0.identity ||
                (isMain($0) && (selected == nil || !observedMains.contains($0.identity)))
        }
        let pids = remaining.map { $0.identity.pid }.sorted()
        let names = Set(remaining.map { $0.identity.executable.lastPathComponent }).sorted()
        var liveProfiles: Set<URL> = []
        for process in remaining {
            let attributed = members[process.identity.pid].flatMap { $0.identity == process.identity ? $0.profile : nil }
                ?? profile(for: process)
            guard let attributed else { return .stillRunning(pids: pids, closedProfiles: [], names: names, stall: stall) }
            liveProfiles.insert(attributed)
        }
        return .stillRunning(pids: pids, closedProfiles: initialProfiles.subtracting(liveProfiles).sorted { $0.path < $1.path },
                             names: names, stall: stall)
    }

    private mutating func requireBudget() throws {
        try Task.checkCancellation()
        guard engine.clock.now() < deadline else { throw failure(.outOfTime) }
    }

    private mutating func send(_ identity: ClosingIdentity, normal: Bool, signal: ClosingSignal = .force) async throws {
        // This read also catches a reopening between requests to two original mains.
        try await refresh()
        guard current[identity.pid]?.identity == identity, members[identity.pid]?.identity == identity else { return }
        try requireBudget()
        if normal {
            try await engine.normalQuit(identity)
            outcome = engine.normalQuitOutcome
        } else {
            try await engine.signal(identity, signal, identity.executable == engine.mainExecutable.standardizedFileURL)
            outcome = signal == .force ? .quitAfterForce : .quitAfterSignal
        }
    }

    private mutating func poll(seconds: TimeInterval, mainsOnly: Bool = false, forcing: Bool = false) async throws -> Bool {
        let until = min(deadline, engine.clock.now().addingTimeInterval(seconds))
        var forced: Set<ClosingIdentity> = []
        while true {
            try await refresh()
            let remainingMembers = survivors()
            if mainsOnly ? !remainingMembers.contains(where: isMain) : remainingMembers.isEmpty { return true }
            let remaining = until.timeIntervalSince(engine.clock.now())
            if remaining <= 0 { return false }
            if forcing {
                for process in survivors() where forced.insert(process.identity).inserted {
                    try await send(process.identity, normal: false)
                }
            }
            let wait = until.timeIntervalSince(engine.clock.now())
            if wait > 0 { try await engine.clock.sleep(for: .seconds(min(0.25, wait))) }
        }
    }
}
