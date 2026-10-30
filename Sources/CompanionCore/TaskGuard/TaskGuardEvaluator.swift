import Foundation

public struct ProcessEntry: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let executableURL: URL
    public let startedAt: Date

    public init(pid: Int32, ppid: Int32, executableURL: URL, startedAt: Date) {
        self.pid = pid
        self.ppid = ppid
        self.executableURL = executableURL
        self.startedAt = startedAt
    }
}

public enum TaskGuardEvaluator {
    public static func evaluate(
        processes: [ProcessEntry],
        claudeMainExecutable: URL,
        registryLoader: (Int32) throws -> Data?
    ) -> TaskActivity {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let children = Dictionary(grouping: processes, by: \.ppid)
        var busy: [CodeTaskInfo] = []
        var unknown: String?
        for process in processes where process.executableURL.lastPathComponent == "claude" {
            guard isHosted(process, byPID: byPID, main: claudeMainExecutable) else { continue }
            let data: Data
            do {
                guard let loaded = try registryLoader(process.pid) else {
                    unknown = unknown ?? TaskUnknownReason.registryUnreadable
                    continue
                }
                data = loaded
            } catch {
                unknown = unknown ?? TaskUnknownReason.registryUnreadable
                continue
            }
            guard let record = try? JSONDecoder().decode(Registry.self, from: data),
                  record.pid == process.pid,
                  normalized(record.procStart) == normalized(registryStartTime(process.startedAt)),
                  record.entrypoint == "claude-desktop"
            else {
                unknown = unknown ?? TaskUnknownReason.registryMismatch
                continue
            }
            let reason: CodeTaskBusyReason?
            switch record.status {
            case "busy", "shell", "waiting": reason = .statusBusy
            case "idle":
                reason = children[process.pid]?.first { shells.contains($0.executableURL.lastPathComponent) }
                    .map { .shellChild(pid: $0.pid) }
            default:
                unknown = unknown ?? TaskUnknownReason.registryMismatch
                continue
            }
            if let reason {
                busy.append(CodeTaskInfo(pid: process.pid, sessionID: record.sessionId,
                                         workingDirectory: record.cwd, reason: reason))
            }
        }
        if !busy.isEmpty { return .busy(busy) }
        if let unknown { return .unknown(unknown) }
        return .idle
    }

    /// Registry procStart uses ps lstart in UTC, including C-locale weekday/month names.
    public static func registryStartTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.string(from: date)
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "fish"]

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isHosted(_ process: ProcessEntry, byPID: [Int32: ProcessEntry], main: URL) -> Bool {
        let main = main.standardizedFileURL
        let contents = main.deletingLastPathComponent().deletingLastPathComponent().path + "/"
        func belongsToDesktop(_ executable: URL) -> Bool {
            let path = executable.standardizedFileURL.path
            return path == main.path || path.hasPrefix(contents)
        }
        // A bundle helper can outlive the main process. Closing still owns its descendants,
        // so their task records must remain part of both the initial and pre-force checks.
        if belongsToDesktop(process.executableURL) { return true }
        var visited: Set<Int32> = [process.pid]
        var parent = process.ppid
        while parent > 1, visited.insert(parent).inserted, let entry = byPID[parent] {
            if belongsToDesktop(entry.executableURL) { return true }
            parent = entry.ppid
        }
        return false
    }

    private struct Registry: Decodable {
        let pid: Int32
        let procStart: String
        let entrypoint: String
        let status: String
        let sessionId: String?
        let cwd: String?
    }
}
