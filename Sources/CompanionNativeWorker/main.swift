import CompanionCore
import Darwin
import Foundation

// A command is executed once in an orphaned worker. Native Bash/Monitor clients only stream
// its output. No credential or environment snapshot is written to disk.
private struct Spec: Codable {
    var version: Int
    var jobID: String
    var sessionID: String
    var kind: String
    var command: String
    var ownerPID: Int32
    var procStart: String
    var deadlineAt: Double?
}
private struct Identity: Codable {
    var pid: Int32
    var start: Double
    var executable: String
    var parent: Int32
}
private struct Launch: Codable {
    var owner: Identity
    var client: Identity
    var cwd: String
    var shell: String
}
private struct State: Codable {
    var version = 1
    var executionProtocol = 3
    var jobID: String
    var sessionID: String
    var status: String
    var worker: Identity
    var child: Identity?
    var owner: Identity
    var client: Identity
    var createdAt: Double
    var updatedAt: Double
    var exitCode: Int32?
}
private struct Adoption: Codable {
    var version = 1
    var requestID: String
    var operationID: String
    var instanceID: String
    var owner: Identity
    var client: Identity
}
private struct Handoff: Codable {
    var version: Int
    var jobID: String
    var sessionID: String
    var operationID: String
    var sourcePID: Int32
    var sourceStartedAt: Double
    var expiresAt: Double
    var targetPID: Int32?
    var targetStartedAt: Double?
    var requestID: String?
    var targetInstanceID: String?
}
private struct Active: Decodable {
    struct Source: Decodable { var pid: Int32; var startedAt: Double }
    var version: Int; var operationID: String; var ready: Bool
    var createdAt: Double?; var sourceProcesses: [Source]?
}
private struct Ticket: Decodable {
    var version: Int; var requestID: String; var operationID: String; var sessionID: String
    var phase: String; var pid: Int32?; var instanceID: String?; var expiresAt: Double
    var runtimeError: String?; var sourceUserStopped: Bool?
    var requiredCapability: String?
}
private struct Receipt: Decodable {
    var revoked: Bool?
    var version: Int?; var requestID: String?; var operationID: String?; var sessionID: String?
    var instanceID: String?; var pid: Int32?
}
private struct Location: Codable { var version = 1; var jobID: String; var directory: String; var control: String }
private enum WorkerError: Error { case invalid, denied, unavailable, alreadyStarted }

private func now() -> Double { Date().timeIntervalSince1970 * 1000 }
private func valid(_ id: String) -> Bool { (1...128).contains(id.utf8.count) && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 } }
private func identity(_ pid: Int32) -> Identity? {
    var info = proc_bsdinfo()
    guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
          info.pbi_status != SZOMB else { return nil }
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    return Identity(pid: pid, start: (Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000) * 1000,
                    executable: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), parent: Int32(info.pbi_ppid))
}
private func same(_ old: Identity) -> Bool {
    guard let current = identity(old.pid) else { return false }
    return abs(current.start - old.start) < 0.01 && current.executable == old.executable
}
private func ancestor(_ pid: Int32) -> Identity? {
    var current = identity(getpid()), seen = Set<Int32>()
    while let node = current, seen.insert(node.pid).inserted {
        if node.pid == pid { return node }
        current = identity(node.parent)
    }
    return nil
}
private func read<T: Decodable>(_ url: URL, limit: Int64 = 1_048_576) throws -> T {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= limit else { throw WorkerError.invalid }
    return try JSONDecoder().decode(T.self, from: AtomicFile.read(url))
}
private func write<T: Encodable>(_ value: T, _ url: URL) throws { try AtomicFile.write(JSONEncoder().encode(value), to: url) }

private func monitorInput(_ path: String, requestID: String, taskID: String) throws -> Data {
    let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
    let root = home.appending(path: "Library/Application Support/CC-Relay/NativeRecovery")
    let file = URL(fileURLWithPath: path).standardizedFileURL
    guard valid(requestID), valid(taskID),
          file.deletingLastPathComponent().resolvingSymlinksInPath().path == root.appending(path: "requests").resolvingSymlinksInPath().path else {
        throw WorkerError.invalid
    }
    let request: NativeRecoveryRequest = try read(file, limit: 4_000_000)
    let active: NativeRecoveryOperation = try read(root.appending(path: "active.json"))
    let receipt: Receipt = try read(root.appending(path: "results/" + requestID + ".json"), limit: 4_000_000)
    guard request.version == 1, request.requestID == requestID,
          file.lastPathComponent == request.sessionID + ".json", request.requiredCapability == "native-recovery-v6",
          request.phase == "armed", request.runtimeError == nil, !request.sourceUserStopped, request.expiresAt > now(),
          active.version == 1, active.ready, active.operationID == request.operationID,
          active.targetProfile == request.targetProfile, active.targetAccountID == request.targetAccountID,
          receipt.version == 1, receipt.requestID == requestID, receipt.operationID == request.operationID,
          receipt.sessionID == request.sessionID, receipt.instanceID == request.instanceID,
          receipt.pid == request.pid, receipt.revoked != true,
          let pid = request.pid, let caller = ancestor(pid), let started = request.runtimeStartedAt,
          abs(caller.start - started) < 0.01,
          request.work.cliSessionID == request.sessionID,
          let tasks = request.sourceActiveTasks else { throw WorkerError.denied }
    let matches = tasks.filter { $0.id == taskID && $0.kind == .monitor && $0.jobID == nil }
    guard matches.count == 1, let task = matches.first else { throw WorkerError.invalid }
    return try NativeWorkCapture(paths: .live(home: home)).monitorInput(work: request.work, task: task)
}

private func directory(_ value: String, create: Bool = false) throws -> URL {
    let url = URL(fileURLWithPath: value).standardizedFileURL
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    let root = URL(fileURLWithPath: home).appending(path: "Library/Application Support/CC-Relay/NativeRecovery/commands")
    let temporary = URL(fileURLWithPath: "/private/tmp/cc-relay-native-\(getuid())").standardizedFileURL
    let isControl = url.deletingLastPathComponent().resolvingSymlinksInPath().path == root.standardizedFileURL.resolvingSymlinksInPath().path
    guard valid(url.lastPathComponent) else { throw WorkerError.invalid }
    if create {
        guard isControl else { throw WorkerError.invalid }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: temporary.path) {
            do { try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            catch { if !FileManager.default.fileExists(atPath: temporary.path) { throw error } }
        }
    }
    var info = stat()
    if lstat(temporary.path, &info) != 0 || info.st_mode & S_IFMT != S_IFDIR || info.st_uid != getuid() || info.st_mode & 0o077 != 0 { throw WorkerError.invalid }
    if create {
        let parent = temporary.appending(path: UUID().uuidString)
        let physical = parent.appending(path: url.lastPathComponent)
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let location = Location(jobID: url.lastPathComponent, directory: physical.path, control: url.path)
        try write(location, url.appending(path: "location.json")); try write(location, physical.appending(path: "location.json"))
        return physical
    }
    let location: Location = try read(url.appending(path: "location.json"))
    let physical = URL(fileURLWithPath: location.directory).standardizedFileURL
    let control = URL(fileURLWithPath: location.control).standardizedFileURL
    guard location.version == 1, location.jobID == url.lastPathComponent,
          control.deletingLastPathComponent().resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path,
          physical.deletingLastPathComponent().deletingLastPathComponent().path == temporary.path,
          physical.resolvingSymlinksInPath().path == physical.path,
          physical.lastPathComponent == location.jobID,
          (isControl ? control.path == url.path : physical.path == url.path),
          lstat(physical.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw WorkerError.invalid }
    return physical
}
private func spec(_ dir: URL) throws -> Spec {
    let value: Spec = try read(dir.appending(path: "spec.json"))
    guard value.version == 1, value.jobID == dir.lastPathComponent, valid(value.sessionID),
          ["bash", "monitor"].contains(value.kind), !value.command.isEmpty, value.command.utf8.count <= 262_144,
          !value.command.utf8.contains(0) else { throw WorkerError.invalid }
    return value
}
private func spawn(_ executable: String, arguments: [String], cwd: String?, stdout: String, stderr: String, group: Bool) throws -> Int32 {
    var actions: posix_spawn_file_actions_t?, attrs: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attrs) == 0 else { throw WorkerError.unavailable }
    defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attrs) }
    guard posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) == 0,
          posix_spawn_file_actions_addopen(&actions, 1, stdout, O_CREAT | O_WRONLY | O_APPEND, 0o600) == 0,
          posix_spawn_file_actions_addopen(&actions, 2, stderr, O_CREAT | O_WRONLY | O_APPEND, 0o600) == 0 else { throw WorkerError.unavailable }
    if let cwd { guard posix_spawn_file_actions_addchdir_np(&actions, cwd) == 0 else { throw WorkerError.unavailable } }
    let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | (group ? POSIX_SPAWN_SETPGROUP : 0))
    guard posix_spawnattr_setflags(&attrs, flags) == 0 else { throw WorkerError.unavailable }
    if group { guard posix_spawnattr_setpgroup(&attrs, 0) == 0 else { throw WorkerError.unavailable } }
    let pointers = ([executable] + arguments).map { strdup($0) } + [nil]
    defer { for ptr in pointers { free(ptr) } }
    let environment = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) } + [nil]
    defer { for ptr in environment { free(ptr) } }
    var pid: Int32 = 0
    let code = pointers.withUnsafeBufferPointer { buffer in
        environment.withUnsafeBufferPointer { env in
            posix_spawn(&pid, executable, &actions, &attrs, UnsafeMutablePointer(mutating: buffer.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
        }
    }
    guard code == 0 else { throw WorkerError.unavailable }
    return pid
}
private func selfPath() -> String { URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path }
/// Restores the functions and aliases the native shell wrote for this job, read only by the
/// same kind of shell, removes those files, then runs the original text with no positional
/// parameters of its own.
private let shellBootstrap = [
    #"if [ -n "${ZSH_VERSION-}" ]; then cc_relay_native_state=$1.zsh"#,
    #"elif [ -n "${BASH_VERSION-}" ]; then shopt -s expand_aliases 2>/dev/null; cc_relay_native_state=$1.bash"#,
    #"else cc_relay_native_state=; fi"#,
    #"if [ -n "$cc_relay_native_state" ] && [ -f "$cc_relay_native_state" ]; then . "$cc_relay_native_state" >/dev/null 2>&1; fi"#,
    #"rm -f "$1.zsh" "$1.bash"; cc_relay_native_command=$2; shift 2; unset cc_relay_native_state"#,
    #"eval "$cc_relay_native_command""#,
].joined(separator: "; ")
private func state(_ dir: URL) -> State? { try? read(dir.appending(path: "state.json")) }
/// The record as it stands, and whether its worker was seen alive, from one look at it. A
/// record that still says running while its worker is gone is read once more: a worker writes
/// its final state before it exits, so only a lost worker stays running without one.
private func settledState(_ dir: URL) -> (state: State, workerAlive: Bool)? {
    guard let first = state(dir) else { return nil }
    guard ["starting", "running", "stopping"].contains(first.status) else { return (first, false) }
    if same(first.worker) { return (first, true) }
    return state(dir).map { ($0, false) }
}
private func ownershipLock(_ dir: URL, attempts: Int = 1) throws -> Int32 {
    let fd = open(dir.appending(path: "ownership.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw WorkerError.unavailable }
    for attempt in 0..<attempts {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        if attempt + 1 < attempts { usleep(5_000) }
    }
    close(fd); throw WorkerError.unavailable
}
/// Sleeps until a watched file or folder changes, a watched process exits, or a limit passes.
/// The loops below re-check every condition on each wake, so a missed event only costs time.
private final class Wakeups {
    private let queue: Int32
    private var files: [String: Int32] = [:]
    private var processes = Set<Int32>()
    /// Processes whose exit the queue reported. The report can come before the process table
    /// shows the process gone, and no second one follows.
    private var exits = Set<Int32>()

    init() throws {
        queue = kqueue()
        guard queue >= 0 else { throw WorkerError.unavailable }
    }
    deinit { for fd in files.values { close(fd) }; close(queue) }

    func watch(path: String) {
        guard files[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        var change = kevent(ident: UInt(fd), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR),
                            fflags: UInt32(NOTE_WRITE | NOTE_EXTEND | NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB), data: 0, udata: nil)
        if kevent(queue, &change, 1, nil, 0, nil) == 0 { files[path] = fd } else { close(fd) }
    }

    func watch(process pid: Int32) {
        guard pid > 1, !processes.contains(pid), !exits.contains(pid) else { return }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        // A process that already exited cannot be watched; the next check sees it gone.
        if kevent(queue, &change, 1, nil, 0, nil) == 0 { processes.insert(pid) }
    }

    /// Whether the queue reported this process's exit; the process table may still show it.
    func exited(_ pid: Int32) -> Bool { exits.contains(pid) }

    /// Another process now holds `pid`, so an exit reported for it is not this one's.
    func renew(_ pid: Int32) { exits.remove(pid) }

    func wait(milliseconds: Double) {
        let limit = max(10, min(60_000, Int(milliseconds.rounded(.up))))
        var timeout = timespec(tv_sec: limit / 1000, tv_nsec: (limit % 1000) * 1_000_000)
        var events = Array(repeating: kevent(), count: 8)
        let count = kevent(queue, nil, 0, &events, Int32(events.count), &timeout)
        guard count > 0 else { return }
        for event in events.prefix(Int(count)) {
            if event.filter == Int16(EVFILT_PROC) { processes.remove(Int32(event.ident)); exits.insert(Int32(event.ident)) }
            // A replaced file is a new inode: watch the path again on the next call.
            else if event.fflags & UInt32(NOTE_DELETE | NOTE_RENAME) != 0,
                    let path = files.first(where: { $0.value == Int32(event.ident) })?.key {
                close(Int32(event.ident)); files[path] = nil
            }
        }
    }
}
/// The longest a loop sleeps without any event: a backstop, not the way changes are noticed.
private let backstopMilliseconds = 10_000.0
private func handoff(_ dir: URL, _ state: State) -> Handoff? {
    guard let h: Handoff = try? read(dir.appending(path: "handoff.json")), h.version == 1,
          h.jobID == state.jobID, h.sessionID == state.sessionID, h.expiresAt > now(),
          h.sourcePID == state.owner.pid, abs(h.sourceStartedAt - state.owner.start) < 0.01 else { return nil }
    return h
}
private func preparingSwitch(_ dir: URL, _ state: State) -> Bool {
    // A new generation revokes an in-flight old native attachment before per-job permits
    // are written. Keep that body while its verified source CLI is still alive; this
    // reservation alone never permits surviving the CLI's exit or adopting a target.
    guard same(state.owner), let location: Location = try? read(dir.appending(path: "location.json")) else { return false }
    let root = URL(fileURLWithPath: location.control).deletingLastPathComponent().deletingLastPathComponent()
    guard let active: Active = try? read(root.appending(path: "active.json")), active.version == 1, !active.ready,
          let created = active.createdAt, created <= now() + 1_000, now() - created < 300_000 else { return false }
    return active.sourceProcesses?.contains { $0.pid == state.owner.pid && abs($0.startedAt - state.owner.start) < 0.01 } == true
}
private func stopChild(_ child: Identity) {
    // Signal only the original direct child's process group, with the same PID and
    // microsecond birth time. exec may change its executable. Never match command text.
    func owned() -> Bool {
        var info = proc_bsdinfo()
        guard proc_pidinfo(child.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return false }
        let birth = (Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000) * 1000
        // Include an unreaped zombie leader: its PID cannot be reused while this worker
        // owns waitpid, and its still-running process group must receive the final KILL.
        return abs(birth - child.start) < 0.01 && info.pbi_ppid == getpid() && info.pbi_pgid == child.pid
    }
    guard owned() else { return }
    _ = kill(-child.pid, SIGTERM)
    for _ in 0..<20 {
        if groupHasLiveMembers(child.pid) == false { break }
        usleep(25_000)
    }
    // No waitpid runs in this function, and SIGCHLD is not ignored. The verified
    // leader's PID is still reserved even if macOS no longer exposes its zombie's
    // proc info; its original process-group number therefore cannot be reused.
    // One empty look proves nothing: a process the command was starting as the signal
    // went out can show up a moment later and then run on. KILL the group until two
    // looks in a row find it empty.
    var empty = 0
    for _ in 0..<40 where empty < 2 {
        _ = kill(-child.pid, SIGKILL)
        usleep(25_000)
        empty = groupHasLiveMembers(child.pid) == false ? empty + 1 : 0
    }
}
private func groupHasLiveMembers(_ pid: Int32) -> Bool? {
    let estimate = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), nil, 0)
    guard estimate >= 0 else { return nil }
    var capacity = max(16, Int(estimate) / MemoryLayout<Int32>.size + 16)
    for _ in 0..<3 {
        var pids = [Int32](repeating: 0, count: capacity)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), $0.baseAddress, Int32($0.count))
        }
        guard bytes >= 0 else { return nil }
        if Int(bytes) >= pids.count * MemoryLayout<Int32>.size { capacity *= 2; continue }
        for member in pids.prefix(Int(bytes) / MemoryLayout<Int32>.size) where member > 0 {
            var info = proc_bsdinfo()
            if proc_pidinfo(member, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) != MemoryLayout<proc_bsdinfo>.size {
                if errno == ESRCH { continue }
                return nil
            }
            if info.pbi_pgid == pid, info.pbi_status != SZOMB { return true }
        }
        return false
    }
    return nil
}
private func groupEnded(_ pid: Int32) -> Bool {
    // Read only after reaping the leader. No more group signals are sent once its PID can
    // be reused; a group that has not ended yields attention rather than a false stop.
    for _ in 0..<40 {
        if groupHasLiveMembers(pid) == false { return true }
        usleep(20_000)
    }
    return false
}
private func serve(_ dir: URL) throws -> Int32 {
    guard setsid() >= 0 else { throw WorkerError.unavailable }
    // Publish a running controller only after the intermediate launcher has exited. A close
    // that remembers descendants must never enroll a worker still in the source's ancestry.
    for _ in 0..<100 where getppid() != 1 { usleep(1_000) }
    guard getppid() == 1 else { throw WorkerError.unavailable }
    let value = try spec(dir), launch: Launch = try read(dir.appending(path: "launch.json"))
    let fd = open(dir.appending(path: "execution.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw WorkerError.unavailable }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return 0 }
    defer { flock(fd, LOCK_UN) }
    guard !FileManager.default.fileExists(atPath: dir.appending(path: "state.json").path) else { return 0 }
    guard let me = identity(getpid()), same(launch.owner) else { throw WorkerError.denied }
    // Mutable state is not a start journal. Even a missing/corrupt state file after a crash
    // cannot authorize the original side effects again for this job ID.
    let started = open(dir.appending(path: "execution.started").path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
    guard started >= 0 else { throw WorkerError.alreadyStarted }
    guard fsync(started) == 0 else { close(started); throw WorkerError.unavailable }
    close(started)
    var result = State(jobID: value.jobID, sessionID: value.sessionID, status: "starting", worker: me,
                       child: nil, owner: launch.owner, client: launch.client, createdAt: now(), updatedAt: now())
    if FileManager.default.fileExists(atPath: dir.appending(path: "stop.json").path) || (value.deadlineAt.map { $0 <= now() } ?? false) {
        result.status = FileManager.default.fileExists(atPath: dir.appending(path: "stop.json").path) ? "stopped" : "expired"
        try write(result, dir.appending(path: "state.json")); return 0
    }
    // Durable, exclusive start before executing any command. A crashed worker is never replayed.
    try write(result, dir.appending(path: "state.json"))
    let childPID: Int32
    do { childPID = try spawn(launch.shell, arguments: ["-c", shellBootstrap, URL(fileURLWithPath: launch.shell).lastPathComponent,
                                                        dir.appending(path: "shell-state").path, value.command], cwd: launch.cwd,
                              stdout: dir.appending(path: "stdout").path, stderr: dir.appending(path: "stderr").path, group: true) }
    catch { result.status = "attention"; result.updatedAt = now(); try? write(result, dir.appending(path: "state.json")); throw error }
    guard let child = identity(childPID) else {
        // A very short command may already have exited; waitpid below still owns its result.
        result.status = "running"; try write(result, dir.appending(path: "state.json"))
        var code: Int32 = 0; _ = waitpid(childPID, &code, 0)
        result.exitCode = (code & 0x7f) == 0 ? (code >> 8) & 255 : 128 + (code & 0x7f)
        result.status = result.exitCode == 0 ? "completed" : "failed"
        result.updatedAt = now(); try write(result, dir.appending(path: "state.json")); return 0
    }
    result.child = child; result.status = "running"
    do { try write(result, dir.appending(path: "state.json")) }
    catch { stopChild(child); throw error }
    var exitStatus: Int32 = 0, stopReason: String?, stopFailed = false
    // Stop requests, permits and adoptions are files in this folder; owners, clients and the
    // command are processes. Watch them instead of polling.
    let wakeups = try? Wakeups()
    try? FileManager.default.createDirectory(at: dir.appending(path: "adoptions"), withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    wakeups?.watch(process: childPID)
    while waitpid(childPID, &exitStatus, WNOHANG) == 0 {
        var ownershipPending = false
        wakeups?.watch(path: dir.path); wakeups?.watch(path: dir.appending(path: "adoptions").path)
        wakeups?.watch(process: result.owner.pid); wakeups?.watch(process: result.client.pid)
        if FileManager.default.fileExists(atPath: dir.appending(path: "stop.json").path) { stopReason = "stopped" }
        if let deadline = value.deadlineAt, deadline <= now() { stopReason = "expired" }
        if let ownership = try? ownershipLock(dir) {
            // CC-Relay uses this same private lock when it reads owner + writes the next
            // exit permit. Adoption cannot change owner between those two operations.
            if let permit = handoff(dir, result), let requestID = permit.requestID, valid(requestID),
               let adoption: Adoption = try? read(dir.appending(path: "adoptions/\(requestID).json")),
               adoption.version == 1, adoption.requestID == requestID, adoption.operationID == permit.operationID,
               adoption.instanceID == permit.targetInstanceID, same(adoption.owner), same(adoption.client), permit.targetPID == adoption.owner.pid,
               permit.targetStartedAt.map({ abs($0 - adoption.owner.start) < 0.01 }) == true {
                result.owner = adoption.owner; result.client = adoption.client
                wakeups?.renew(result.owner.pid); wakeups?.renew(result.client.pid)
                result.updatedAt = now(); try? write(result, dir.appending(path: "state.json"))
            }
            if (!same(result.owner) || !same(result.client)), handoff(dir, result) == nil, !preparingSwitch(dir, result) { stopReason = "stopped" }
            if stopReason != nil { result.status = "stopping"; result.updatedAt = now(); try? write(result, dir.appending(path: "state.json")) }
            flock(ownership, LOCK_UN); close(ownership)
        } else {
            // The adoption file can wake us while its writer still holds this lock.
            // Unlocking emits no filesystem event, so retry this known contention soon.
            ownershipPending = true
            if (!same(result.owner) || !same(result.client)), handoff(dir, result) == nil, !preparingSwitch(dir, result) {
                stopReason = "stopped"
            }
        }
        if !same(result.owner), handoff(dir, result) == nil { stopReason = "stopped" }
        if let reason = stopReason, !stopFailed {
            stopChild(child)
            var reaped = false
            for _ in 0..<20 {
                if waitpid(childPID, &exitStatus, WNOHANG) == childPID { reaped = true; break }
                usleep(25_000)
            }
            if reaped { result.status = reason; break }
            stopFailed = true; result.status = "attention"; result.updatedAt = now()
            try? write(result, dir.appending(path: "state.json"))
        }
        guard let wakeups else { usleep(100_000); continue }
        // Time limits produce no file or process event: wake for the nearest one.
        var limit = backstopMilliseconds
        if ownershipPending { limit = min(limit, 25) }
        // An exit reported while the process table still shows the process brings no second
        // event: look again soon rather than at the backstop.
        if [result.owner, result.client].contains(where: { wakeups.exited($0.pid) && same($0) }) { limit = min(limit, 25) }
        if let deadline = value.deadlineAt { limit = min(limit, deadline - now()) }
        if let permit = handoff(dir, result) { limit = min(limit, permit.expiresAt - now()) }
        wakeups.wait(milliseconds: limit)
    }
    if let reason = stopReason {
        result.status = !stopFailed && groupEnded(childPID) ? reason : "attention"
    } else {
        result.exitCode = (exitStatus & 0x7f) == 0 ? (exitStatus >> 8) & 255 : 128 + (exitStatus & 0x7f)
        result.status = result.exitCode == 0 ? "completed" : "failed"
    }
    result.updatedAt = now(); try write(result, dir.appending(path: "state.json")); return 0
}
private func start(_ dir: URL) throws {
    let value = try spec(dir)
    if let existing = state(dir) {
        guard existing.sessionID == value.sessionID, existing.status != "starting", same(existing.worker) || ["completed", "failed", "stopped", "expired"].contains(existing.status) else { throw WorkerError.alreadyStarted }
        guard let caller = ancestor(existing.owner.pid), abs(caller.start - existing.owner.start) < 0.01 else { throw WorkerError.denied }
        return
    }
    guard let owner = ancestor(value.ownerPID), TaskGuardEvaluator.registryStartTime(Date(timeIntervalSince1970: owner.start / 1000)).split(whereSeparator: \.isWhitespace) == value.procStart.split(whereSeparator: \.isWhitespace) else { throw WorkerError.denied }
    var current = identity(getppid()), shell = "/bin/bash", seen = Set<Int32>()
    while let node = current, node.pid != owner.pid, seen.insert(node.pid).inserted {
        if ["zsh", "bash", "sh"].contains(URL(fileURLWithPath: node.executable).lastPathComponent) { shell = node.executable; break }
        current = identity(node.parent)
    }
    // Serialize launch creation too; a second client cannot overwrite cwd/owner of a running job.
    let lock = open(dir.appending(path: "launch.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw WorkerError.unavailable }; defer { close(lock) }
    guard flock(lock, LOCK_EX) == 0 else { throw WorkerError.unavailable }; defer { flock(lock, LOCK_UN) }
    if state(dir) != nil { return }
    guard !FileManager.default.fileExists(atPath: dir.appending(path: "launch.json").path),
          !FileManager.default.fileExists(atPath: dir.appending(path: "execution.started").path) else { throw WorkerError.alreadyStarted }
    guard let client = identity(getpid()) else { throw WorkerError.unavailable }
    try write(Launch(owner: owner, client: client, cwd: FileManager.default.currentDirectoryPath, shell: shell), dir.appending(path: "launch.json"))
    let log = dir.appending(path: "worker.log").path
    let detached = try spawn(selfPath(), arguments: ["detach", dir.path], cwd: nil, stdout: log, stderr: log, group: false)
    var status: Int32 = 0; guard waitpid(detached, &status, 0) == detached, status == 0 else { throw WorkerError.unavailable }
    for _ in 0..<100 { if state(dir) != nil { return }; usleep(20_000) }
    throw WorkerError.unavailable
}
private func attach(_ dir: URL, requestID: String?) throws -> Int32 {
    let value = try spec(dir)
    guard var current = state(dir), current.sessionID == value.sessionID else { throw WorkerError.unavailable }
    // Reserve the one output cursor before publishing ownership. A rejected duplicate
    // consumer must not leave a successful adoption behind.
    let consumerLock = value.kind == "monitor" ? open(dir.appending(path: "consumer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600) : -1
    if value.kind == "monitor" {
        guard consumerLock >= 0, flock(consumerLock, LOCK_EX | LOCK_NB) == 0 else { if consumerLock >= 0 { close(consumerLock) }; throw WorkerError.denied }
    }
    defer { if consumerLock >= 0 { flock(consumerLock, LOCK_UN); close(consumerLock) } }
    var clientOwner = current.owner
    if let requestID {
        let ownership = try ownershipLock(dir, attempts: 100)
        defer { flock(ownership, LOCK_UN); close(ownership) }
        guard valid(requestID), let permit: Handoff = try? read(dir.appending(path: "handoff.json")),
              permit.version == 1, permit.jobID == value.jobID, permit.sessionID == value.sessionID,
              permit.expiresAt > now(), permit.requestID == requestID,
              let pid = permit.targetPID, let owner = ancestor(pid), permit.targetStartedAt.map({ abs($0 - owner.start) < 0.01 }) == true else { throw WorkerError.denied }
        let location: Location = try read(dir.appending(path: "location.json"))
        let root = URL(fileURLWithPath: location.control).deletingLastPathComponent().deletingLastPathComponent()
        let active: Active = try read(root.appending(path: "active.json"))
        let ticket: Ticket = try read(root.appending(path: "requests/\(value.sessionID).json"), limit: 4_194_304)
        let receiptFile = root.appending(path: "results/\(requestID).json")
        let receipt: Receipt? = FileManager.default.fileExists(atPath: receiptFile.path) ? try read(receiptFile, limit: 4_194_304) : nil
        guard active.version == 1, active.ready, active.operationID == permit.operationID,
              ticket.requiredCapability == "native-recovery-v6",
              ticket.version == 1, ticket.requestID == requestID, ticket.operationID == permit.operationID,
              ticket.sessionID == value.sessionID, ticket.phase == "armed", ticket.pid == owner.pid,
              ticket.instanceID == permit.targetInstanceID, ticket.expiresAt > now(), ticket.runtimeError == nil,
              ticket.sourceUserStopped != true, receipt?.revoked != true else { throw WorkerError.denied }
        guard let instanceID = permit.targetInstanceID else { throw WorkerError.denied }
        guard let client = identity(getpid()) else { throw WorkerError.unavailable }
        try write(Adoption(requestID: requestID, operationID: permit.operationID, instanceID: instanceID, owner: owner, client: client),
                  dir.appending(path: "adoptions/\(requestID).json"))
        clientOwner = owner
    }
    var offsets: [String: UInt64] = value.kind == "monitor" ? (try? read(dir.appending(path: "cursor.json"))) ?? [:] : [:]
    /// Forwards one bounded chunk; true when more bytes were already waiting behind it.
    @discardableResult func flush(_ name: String, fd: Int32) throws -> Bool {
        let file = dir.appending(path: name)
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let previous = offsets[name]
        var offset = offsets[name] ?? (value.kind == "bash" && size > 262_144 ? size - 262_144 : 0)
        if previous == nil, offset > 0 {
            let note = "[CC-Relay: showing the last 262144 bytes of \(name); complete original output: \(file.path)]\n"
            try FileHandle.standardError.write(contentsOf: Data(note.utf8))
        }
        guard size >= offset else { throw WorkerError.invalid }
        try handle.seek(toOffset: offset)
        if let bytes = try handle.read(upToCount: 262_144), !bytes.isEmpty {
            try bytes.withUnsafeBytes { data in
                var sent = 0
                while sent < data.count {
                    let count = Darwin.write(fd, data.baseAddress!.advanced(by: sent), data.count - sent)
                    if count < 0 { if errno == EINTR { continue }; throw WorkerError.unavailable }
                    sent += count
                }
            }
            offset += UInt64(bytes.count)
        }
        offsets[name] = offset
        if value.kind == "monitor", previous != offset { try write(offsets, dir.appending(path: "cursor.json")) }
        return offset < size
    }
    let wakeups = try? Wakeups()
    while true {
        wakeups?.watch(path: dir.path)
        wakeups?.watch(path: dir.appending(path: "stdout").path); wakeups?.watch(path: dir.appending(path: "stderr").path)
        wakeups?.watch(process: clientOwner.pid); wakeups?.watch(process: current.worker.pid)
        guard same(clientOwner) else { throw WorkerError.denied }
        let outPending = try flush("stdout", fd: 1), errorPending = try flush("stderr", fd: 2)
        let pending = outPending || errorPending
        guard let (next, workerAlive) = settledState(dir) else { throw WorkerError.unavailable }; current = next
        if !["starting", "running"].contains(current.status) {
            // Drain the remaining bounded chunks after the process has closed its streams.
            while true {
                let before = offsets; try flush("stdout", fd: 1); try flush("stderr", fd: 2)
                if before == offsets { break }
            }
            return current.exitCode ?? (current.status == "completed" ? 0 : 1)
        }
        guard workerAlive else { throw WorkerError.alreadyStarted }
        if pending { continue }
        guard let wakeups else { usleep(100_000); continue }
        // Both still show in the process table here; one whose exit was reported leaves it in a
        // moment, with no second event.
        let exiting = wakeups.exited(clientOwner.pid) || wakeups.exited(current.worker.pid)
        wakeups.wait(milliseconds: exiting ? 25 : backstopMilliseconds)
    }
}
@main private enum NativeCommandMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGCHLD, SIG_DFL)
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            guard args.count >= 2 else { throw WorkerError.invalid }
            if args[0] == "artifact-input" {
                guard args.count == 2, valid(args[1]) else { throw WorkerError.invalid }
                let environment = ProcessInfo.processInfo.environment
                let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory())
                let cliHome = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
                do {
                    let input = try NativeWorkCapture(paths: .live(home: home)).artifactRecoveryInput(sessionID: args[1], cliHome: cliHome)
                    print(String(decoding: try JSONEncoder().encode(input), as: UTF8.self))
                } catch NativeWorkCaptureFailure.transcriptMissing {
                    // A brand-new conversation has no old watches. Other read failures stay
                    // failures so the plugin can retry and report them instead of silently skipping.
                    let empty: [String: Any] = ["version": 1, "sessionID": args[1], "branchComplete": true, "artifacts": []]
                    print(String(decoding: try JSONSerialization.data(withJSONObject: empty), as: UTF8.self))
                } catch NativeWorkCaptureFailure.permissionDenied {
                    fputs("Cannot read original Artifact history: permission denied.\n", stderr)
                    exit(125)
                }
                return
            }
            if args[0] == "monitor-input" {
                guard args.count == 4 else { throw WorkerError.invalid }
                let input = try monitorInput(args[1], requestID: args[2], taskID: args[3])
                print(String(decoding: input, as: UTF8.self))
                return
            }
            let dir = try directory(args[1], create: args[0] == "prepare")
            switch args[0] {
            case "prepare": print(String(decoding: try JSONEncoder().encode(["directory": dir.path]), as: UTF8.self))
            case "owner":
                guard let owner = identity(getppid()) else { throw WorkerError.unavailable }
                print(String(decoding: try JSONEncoder().encode(owner), as: UTF8.self))
            case "inspect":
                _ = try spec(dir)
                guard let (settled, workerAlive) = settledState(dir) else { throw WorkerError.unavailable }
                var view = settled
                if ["starting", "running"].contains(view.status) {
                    if !workerAlive { view.status = "attention" }
                    else if let child = view.child {
                        let live = identity(child.pid)
                        if live.map({ abs($0.start - child.start) < 0.01 && $0.parent == view.worker.pid }) != true { view.status = "finalizing" }
                    }
                }
                print(String(decoding: try JSONEncoder().encode(view), as: UTF8.self))
            case "detach":
                let log = dir.appending(path: "worker.log").path
                _ = try spawn(selfPath(), arguments: ["serve", dir.path], cwd: nil, stdout: log, stderr: log, group: false)
            case "serve": exit(try serve(dir))
            case "run": try start(dir); exit(try attach(dir, requestID: nil))
            case "attach": guard args.count == 3 else { throw WorkerError.invalid }; exit(try attach(dir, requestID: args[2]))
            case "stop":
                _ = try spec(dir); try AtomicFile.write(Data("{\"stop\":true}".utf8), to: dir.appending(path: "stop.json"))
                var stopped = false
                for _ in 0..<60 {
                    guard let (current, workerAlive) = settledState(dir) else { throw WorkerError.unavailable }
                    if ["completed", "failed", "stopped", "expired"].contains(current.status) { stopped = true; break }
                    guard current.status != "attention", workerAlive else { throw WorkerError.unavailable }
                    usleep(50_000)
                }
                guard stopped else { throw WorkerError.unavailable }
                print("original command ended")
            default: throw WorkerError.invalid
            }
        } catch {
            fputs("Native command could not be continued: \(error)\n", stderr); exit(125)
        }
    }
}
