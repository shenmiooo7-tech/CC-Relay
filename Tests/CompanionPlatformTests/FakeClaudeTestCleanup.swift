import Darwin
import Foundation
import XCTest
@testable import CompanionPlatform

/// Register before launching: teardown must not depend on launch returning an
/// instance, argv remaining readable, or the main still parenting its helpers.
struct FakeClaudeTestCleanup {
    let root: URL

    func stop(file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        var known: [Int32: ClosingIdentity] = [:]
        repeat {
            do {
                let processes = try ProcessTable().closingProcesses().filter { owns($0.identity.executable) }
                for process in processes { known[process.identity.pid] = process.identity }
                for process in processes.reversed() {
                    guard ProcessTable().closingProcess(pid: process.identity.pid)?.identity == process.identity else { continue }
                    _ = Darwin.kill(process.identity.pid, SIGKILL)
                }
                for identity in known.values where stillExists(identity) {
                    var status: Int32 = 0
                    // Foundation may have reaped a direct child already. Helpers are
                    // reaped by their parent or launchd; ECHILD is expected for those.
                    _ = waitpid(identity.pid, &status, WNOHANG)
                }
                if processes.isEmpty && !known.values.contains(where: stillExists) { return }
            } catch {
                XCTFail("Could not enumerate sandbox test processes: \(error)", file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        XCTFail("Sandbox test processes survived SIGKILL", file: file, line: line)
    }

    private func stillExists(_ identity: ClosingIdentity) -> Bool {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else {
            // libproc hides unreaped zombies on some macOS versions. A zero
            // signal checks existence without sending a termination request.
            return Darwin.kill(identity.pid, 0) == 0
        }
        let started = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
        return started == identity.startedAt
    }

    private func owns(_ executable: URL) -> Bool {
        // Paths arrive as /var/… (resolved URLs) or /private/var/… (raw process table); accept both.
        var prefixes = [root.standardizedFileURL.resolvingSymlinksInPath().path + "/"]
        if let resolved = Darwin.realpath(root.path, nil) {
            prefixes.append(String(cString: resolved) + "/")
            free(resolved)
        }
        return prefixes.contains { $0 != "//" && executable.path.hasPrefix($0) } &&
            ["FakeClaude", "FakeClaudeHelper"].contains(executable.lastPathComponent)
    }
}

/// Foundation reaps Process children automatically. posix_spawn lets a regression
/// fixture deliberately keep an exited FakeClaude unreaped until its defer runs.
struct UnreapedFakeClaude {
    let pid: Int32

    init(executable: URL, profile: URL, environment: [String: String] = [:]) throws {
        var spawned: Int32 = 0
        let arguments = [executable.path, "--user-data-dir=\(profile.path)"].map { strdup($0) } + [nil]
        let variables = ProcessInfo.processInfo.environment.merging(environment, uniquingKeysWith: { _, value in value })
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in arguments + variables { free(pointer) }
        }
        let status = arguments.withUnsafeBufferPointer { argv in
            variables.withUnsafeBufferPointer { env in
                posix_spawn(&spawned, executable.path, nil, nil,
                            UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
        pid = spawned
    }

    var isZombie: Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
    }

    func terminate() { _ = Darwin.kill(pid, SIGTERM) }

    func stop() {
        var info = siginfo_t()
        // Confirm it is still our unreaped child before signalling a numeric PID.
        guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else { return }
        if !isZombie { _ = Darwin.kill(pid, SIGKILL) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }
}
