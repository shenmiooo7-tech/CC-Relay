import CompanionCore
import Foundation

/// A plugin report identifies a candidate, not an account. The OS ancestry,
/// registry lifetime and current profile configuration establish its ownership.
public struct LiveNativeRuntimeInspector: NativeRuntimeInspecting {
    private let paths: AppPaths
    private let checkAccess: @Sendable () throws -> Void
    private let readProcesses: @Sendable () throws -> [ProcessEntry]
    private let readArguments: @Sendable (ProcessEntry) throws -> [String]
    private let readRegistry: @Sendable (Int32) throws -> Data
    private let readConfiguration: @Sendable (URL) throws -> ProfileConfiguration

    public init(paths: AppPaths) {
        self.init(paths: paths,
            checkAccess: { try SafetyTripwire.assertLiveActionsAllowed() },
            readProcesses: {
                try ProcessTable().closingProcesses().map {
                    ProcessEntry(pid: $0.identity.pid, ppid: $0.parent,
                                 executableURL: $0.identity.executable, startedAt: $0.identity.startedAt)
                }
            },
            readArguments: { expected in
                guard let current = ProcessTable().record(pid: expected.pid), current.ppid == expected.ppid,
                      current.startedAt == expected.startedAt,
                      ProfilePaths.same(current.executableURL, expected.executableURL) else {
                    throw NativeInspectionError.changedProcess
                }
                return current.argv
            },
            readRegistry: { pid in
                let file = paths.claudeCLIHome.appending(path: "sessions/\(pid).json")
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber, size.int64Value <= 262_144 else {
                    throw NativeInspectionError.invalidRegistry
                }
                let data = try AtomicFile.read(file)
                guard data.count <= 262_144 else { throw NativeInspectionError.invalidRegistry }
                return data
            },
            readConfiguration: { try ProfileConfigReader().read(profile: $0) })
    }

    /// Injection is internal so tests never read live processes, profiles or credentials.
    init(paths: AppPaths, checkAccess: @escaping @Sendable () throws -> Void = {},
         readProcesses: @escaping @Sendable () throws -> [ProcessEntry],
         readArguments: @escaping @Sendable (ProcessEntry) throws -> [String],
         readRegistry: @escaping @Sendable (Int32) throws -> Data,
         readConfiguration: @escaping @Sendable (URL) throws -> ProfileConfiguration) {
        self.paths = paths; self.checkAccess = checkAccess; self.readProcesses = readProcesses
        self.readArguments = readArguments; self.readRegistry = readRegistry
        self.readConfiguration = readConfiguration
    }

    public func sessions(profile: URL) async -> [NativeProcessSession] {
        do {
            try checkAccess()
            guard profile.isFileURL else { return [] }
            let first = try processMap()
            let candidates = first.values.compactMap { process -> Candidate? in
                try? candidate(process, in: first, profile: profile)
            }
            let second = try processMap()
            return candidates.compactMap { candidate in
                guard let registry = try? recheck(candidate, in: second, profile: profile) else { return nil }
                return NativeProcessSession(sessionID: registry.sessionId, pid: candidate.process.pid,
                                            startedAt: candidate.process.startedAt,
                                            busy: registry.status != "idle" || Self.hasShellChild(candidate.process, in: second))
            }.sorted { $0.pid < $1.pid }
        } catch { return [] }
    }

    public func validate(_ report: NativeRuntimeReport, profile: URL, account: AccountIdentity) async -> Bool {
        do {
            try checkAccess()
            guard profile.isFileURL, report.version == 1, report.pid > 1,
                  Self.validID(report.sessionID), Self.validID(report.instanceID),
                  report.reportedAt.isFinite, report.reportedAt > 0,
                  try configurationMatches(profile, account: account) else { return false }
            let first = try processMap()
            guard let process = first[report.pid],
                  // procStart is only second-resolution. An old report must not
                  // validate a reused PID born later in that same second.
                  report.reportedAt >= process.startedAt.timeIntervalSince1970 * 1000,
                  let candidate = try candidate(process, in: first, profile: profile),
                  candidate.registry.sessionId == report.sessionID,
                  Self.normalized(candidate.registry.procStart) == Self.normalized(report.procStart)
            else { return false }
            let registry = try recheck(candidate, in: processMap(), profile: profile)
            let accountMatches = try configurationMatches(profile, account: account)
            return registry.sessionId == report.sessionID &&
                Self.normalized(registry.procStart) == Self.normalized(report.procStart) &&
                accountMatches
        } catch { return false }
    }

    private func processMap() throws -> [Int32: ProcessEntry] {
        var result: [Int32: ProcessEntry] = [:]
        for entry in try readProcesses() {
            guard result[entry.pid] == nil else { throw NativeInspectionError.changedProcess }
            result[entry.pid] = entry
        }
        return result
    }

    private func candidate(_ process: ProcessEntry, in processes: [Int32: ProcessEntry], profile: URL) throws -> Candidate? {
        guard process.pid > 1, process.executableURL.lastPathComponent == "claude" else { return nil }
        let registry = try checkedRegistry(process)
        let main = paths.claudeAppPath.appending(path: "Contents/MacOS/Claude")
        var chain: [ProcessEntry] = [], visited = Set<Int32>(), current: ProcessEntry? = process
        while let entry = current, visited.insert(entry.pid).inserted {
            chain.append(entry)
            if ProfilePaths.same(entry.executableURL, main) {
                guard try mainOwns(entry, profile: profile) else { return nil }
                return Candidate(process: process, registry: registry, chain: chain, main: entry)
            }
            guard let parent = processes[entry.ppid], parent.startedAt <= entry.startedAt else { return nil }
            current = parent
        }
        return nil
    }

    private func recheck(_ candidate: Candidate, in processes: [Int32: ProcessEntry], profile: URL) throws -> Registry {
        for previous in candidate.chain {
            guard let current = processes[previous.pid], Self.sameProcess(current, previous) else {
                throw NativeInspectionError.changedProcess
            }
        }
        guard try mainOwns(candidate.main, profile: profile) else { throw NativeInspectionError.changedProcess }
        let registry = try checkedRegistry(candidate.process)
        guard registry.sessionId == candidate.registry.sessionId,
              Self.normalized(registry.procStart) == Self.normalized(candidate.registry.procStart) else {
            throw NativeInspectionError.invalidRegistry
        }
        return registry
    }

    private func checkedRegistry(_ process: ProcessEntry) throws -> Registry {
        let registry = try JSONDecoder().decode(Registry.self, from: readRegistry(process.pid))
        guard registry.pid == process.pid, Self.validID(registry.sessionId),
              registry.pidDomain == "darwin", registry.entrypoint == "claude-desktop",
              // These are the host's live registry states. Waiting for a permission decision
              // or running its shell does not change process/account ownership or revoke a
              // continuation; PID, lifetime, ancestry and session checks still all apply.
              ["busy", "shell", "idle", "waiting"].contains(registry.status),
              Self.normalized(registry.procStart) == Self.normalized(TaskGuardEvaluator.registryStartTime(process.startedAt)) else {
            throw NativeInspectionError.invalidRegistry
        }
        return registry
    }

    private func mainOwns(_ main: ProcessEntry, profile: URL) throws -> Bool {
        let explicit = try ClaudeArguments.profileDirectory(in: readArguments(main))
        let actual = explicit ?? paths.claudeProfilesRoot.appending(path: "Claude")
        return ProfilePaths.same(actual, profile)
    }

    private func configurationMatches(_ profile: URL, account: AccountIdentity) throws -> Bool {
        let current = try readConfiguration(profile)
        return current.accountUUID == account.accountUUID && current.activeOrganizationUUID == account.activeOrganizationUUID
    }

    private static func sameProcess(_ a: ProcessEntry, _ b: ProcessEntry) -> Bool {
        a.pid == b.pid && a.ppid == b.ppid && a.startedAt == b.startedAt && ProfilePaths.same(a.executableURL, b.executableURL)
    }

    private static func hasShellChild(_ parent: ProcessEntry, in processes: [Int32: ProcessEntry]) -> Bool {
        guard let current = processes[parent.pid], sameProcess(current, parent) else { return false }
        return processes.values.contains { child in
            child.ppid == parent.pid && child.startedAt >= current.startedAt &&
                ["sh", "bash", "zsh", "fish"].contains(child.executableURL.lastPathComponent)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func validID(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private struct Candidate {
        let process: ProcessEntry
        let registry: Registry
        let chain: [ProcessEntry]
        let main: ProcessEntry
    }

    private struct Registry: Decodable {
        let pid: Int32
        let sessionId: String
        let procStart: String
        let pidDomain: String
        let entrypoint: String
        let status: String
    }
}

private enum NativeInspectionError: Error { case changedProcess, invalidRegistry }
