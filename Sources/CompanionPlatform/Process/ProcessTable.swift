import Darwin
import Foundation
import CompanionCore

public struct ProcessRecord: Equatable, Sendable {
    public let pid: pid_t
    public let ppid: pid_t
    public let executableURL: URL
    public let argv: [String]
    public let startedAt: Date

    public init(pid: pid_t, ppid: pid_t, executableURL: URL, argv: [String], startedAt: Date) {
        self.pid = pid
        self.ppid = ppid
        self.executableURL = executableURL
        self.argv = argv
        self.startedAt = startedAt
    }
}

public enum ProcessTableError: Error, Sendable { case unavailable }

/// A best-effort, read-only snapshot. Inaccessible and disappearing processes are omitted.
public struct ProcessTable: Sendable {
    public init() {}

    public func processes() -> [ProcessRecord] {
        processes(matching: { _ in true })
    }

    public func processes(matching predicate: (URL) -> Bool) -> [ProcessRecord] {
        (try? scan(matching: predicate, requireReadableMatches: false)) ?? []
    }

    /// Adapters use the throwing form so a failed scan cannot authorize a write.
    public func checkedProcesses(matching predicate: (URL) -> Bool) throws -> [ProcessRecord] {
        try scan(matching: predicate, requireReadableMatches: true)
    }

    private func scan(matching predicate: (URL) -> Bool, requireReadableMatches: Bool) throws -> [ProcessRecord] {
        guard let capacity = argumentBufferCapacity() else { throw ProcessTableError.unavailable }
        var arguments = [UInt8](repeating: 0, count: capacity)
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return try allPIDs().compactMap { pid in
            guard let before = bsdInfo(pid: pid), Self.hasReadableLifetime(before),
                  let executable = executableURL(pid: pid, buffer: &path), predicate(executable) else { return nil }
            var argumentError: Int32 = 0
            if let result = record(pid: pid, executable: executable, arguments: &arguments, argumentError: &argumentError) { return result }
            if requireReadableMatches {
                // KERN_PROCARGS2 can return EINVAL before a spawned image's argv
                // becomes readable. Give that window a bounded retry, preserving
                // identity checks and the failure for persistently unreadable argv.
                let retryDeadline = ContinuousClock.now.advanced(by: .milliseconds(250))
                repeat {
                    if argumentError == EINVAL { Thread.sleep(forTimeInterval: 0.005) }
                    guard let retry = bsdInfo(pid: pid), Self.hasReadableLifetime(retry),
                          before.pbi_start_tvsec == retry.pbi_start_tvsec,
                          before.pbi_start_tvusec == retry.pbi_start_tvusec,
                          executableURL(pid: pid, buffer: &path)?.standardizedFileURL == executable.standardizedFileURL
                    else { return nil }
                    if let result = record(pid: pid, executable: executable, arguments: &arguments, argumentError: &argumentError) { return result }
                } while argumentError == EINVAL && ContinuousClock.now < retryDeadline
            }
            // An unreaped exit may still have a path, but cannot supply argv. Only
            // an unchanged, live match can turn an argv failure into a table failure.
            if requireReadableMatches,
               executableURL(pid: pid, buffer: &path)?.standardizedFileURL == executable.standardizedFileURL,
               let after = bsdInfo(pid: pid), Self.hasReadableLifetime(after),
               before.pbi_start_tvsec == after.pbi_start_tvsec,
               before.pbi_start_tvusec == after.pbi_start_tvusec {
                throw ProcessTableError.unavailable
            }
            return nil
        }
    }

    /// The task guard needs ancestry and start times, but no command arguments.
    public func entries() throws -> [ProcessEntry] {
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return try allPIDs().compactMap { pid in
            guard let executable = executableURL(pid: pid, buffer: &path), let info = bsdInfo(pid: pid) else { return nil }
            return ProcessEntry(pid: pid, ppid: pid_t(info.pbi_ppid), executableURL: executable, startedAt: startDate(info))
        }
    }

    /// Closing needs ancestry even when another user's argv cannot be read.
    /// Argument access is deferred to the selected bundle processes only.
    func closingProcesses() throws -> [ClosingProcess] {
        try allPIDs().compactMap { closingProcess(pid: $0) }
    }

    func closingProcess(pid: pid_t) -> ClosingProcess? {
        guard let before = bsdInfo(pid: pid), before.pbi_status != SZOMB else { return nil }
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard let executable = executableURL(pid: pid, buffer: &path),
              let after = bsdInfo(pid: pid), after.pbi_status != SZOMB,
              before.pbi_start_tvsec == after.pbi_start_tvsec,
              before.pbi_start_tvusec == after.pbi_start_tvusec else { return nil }
        return ClosingProcess(identity: ClosingIdentity(pid: pid, startedAt: startDate(after), executable: executable),
                              parent: pid_t(after.pbi_ppid), isZombie: false)
    }

    func closingArguments(_ identity: ClosingIdentity) throws -> [String] {
        guard let record = record(pid: identity.pid), record.startedAt == identity.startedAt,
              record.executableURL.standardizedFileURL == identity.executable else { throw ProcessTableError.unavailable }
        return record.argv
    }

    private func allPIDs() throws -> [pid_t] {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { throw ProcessTableError.unavailable }
        var capacity = Int(estimatedCount) + 32
        for _ in 0..<3 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes {
                proc_listallpids($0.baseAddress, Int32($0.count))
            }
            guard count > 0 else { throw ProcessTableError.unavailable }
            if Int(count) >= capacity {
                capacity *= 2
                continue
            }
            return Array(pids.prefix(Int(count)).filter { $0 > 0 })
        }
        throw ProcessTableError.unavailable
    }

    public func record(pid: pid_t) -> ProcessRecord? {
        guard let capacity = argumentBufferCapacity() else { return nil }
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard let executable = executableURL(pid: pid, buffer: &path) else { return nil }
        var arguments = [UInt8](repeating: 0, count: capacity)
        var argumentError: Int32 = 0
        return record(pid: pid, executable: executable, arguments: &arguments, argumentError: &argumentError)
    }

    private func executableURL(pid: pid_t, buffer path: inout [UInt8]) -> URL? {
        guard pid > 0 else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro unavailable to Swift.
        let pathLength = path.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard pathLength > 0, Int(pathLength) <= path.count,
              let end = path.firstIndex(of: 0), end > 0,
              let executable = String(bytes: path[..<end], encoding: .utf8)
        else { return nil }
        return URL(fileURLWithPath: executable)
    }

    private func record(pid: pid_t, executable: URL, arguments bytes: inout [UInt8], argumentError: inout Int32) -> ProcessRecord? {
        argumentError = 0
        guard let before = bsdInfo(pid: pid), Self.hasReadableLifetime(before) else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = bytes.count
        let status = bytes.withUnsafeMutableBytes {
            sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0)
        }
        argumentError = status == 0 ? 0 : errno
        let parsed = status == 0 && size <= bytes.count ? Self.parseArguments(Data(bytes.prefix(size))) : nil
        let after = bsdInfo(pid: pid)
        guard status == 0, size <= bytes.count,
              let argv = parsed,
              let after, Self.hasReadableLifetime(after),
              before.pbi_start_tvsec == after.pbi_start_tvsec,
              before.pbi_start_tvusec == after.pbi_start_tvusec
        else { return nil }

        return ProcessRecord(
            pid: pid,
            ppid: pid_t(after.pbi_ppid),
            executableURL: executable,
            argv: argv,
            startedAt: startDate(after)
        )
    }

    private func startDate(_ info: proc_bsdinfo) -> Date {
        Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    private static func hasReadableLifetime(_ info: proc_bsdinfo) -> Bool {
        info.pbi_status != SZOMB && info.pbi_flags & UInt32(PROC_FLAG_INEXIT) == 0
    }

    private func bsdInfo(pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return info
    }

    private func argumentBufferCapacity() -> Int? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var capacity: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, UInt32(mib.count), &capacity, &size, nil, 0) == 0,
              capacity > 0, capacity <= 16 * 1_024 * 1_024 else { return nil }
        return Int(capacity)
    }

    /// KERN_PROCARGS2 contains argc, the executable path, padding, argv, then environment.
    static func parseArguments(_ data: Data) -> [String]? {
        let headerSize = MemoryLayout<Int32>.size
        guard data.count > headerSize else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, Int(argc) <= data.count - headerSize else { return nil }
        let bytes = [UInt8](data)
        guard let pathEnd = bytes[headerSize...].firstIndex(of: 0) else { return nil }
        var cursor = pathEnd + 1
        while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }

        var arguments: [String] = []
        for _ in 0..<argc {
            guard cursor < bytes.count,
                  let end = bytes[cursor...].firstIndex(of: 0),
                  let argument = String(bytes: bytes[cursor..<end], encoding: .utf8)
            else { return nil }
            arguments.append(argument)
            cursor = end + 1
        }
        // Stop at argc even if the following bytes look like more arguments.
        return arguments
    }
}
