import Foundation

public struct ClaudeInstance: Equatable, Hashable, Sendable {
    public var pid: Int32
    /// Profile directory this main process was launched with. A main process
    /// with no user-data-dir argument uses the default profile directory.
    public var profileDirectory: URL
    /// True when argv contained `--user-data-dir=<path>` or the two-token form
    /// `--user-data-dir <path>`. We always pass that flag, so `false` means
    /// someone else opened Claude on the default profile. `profileDirectory`
    /// alone cannot show that: both cases resolve to the same directory.
    public var hasExplicitProfileFlag: Bool
    public var startedAt: Date
    public var executableURL: URL

    public init(
        pid: Int32,
        profileDirectory: URL,
        hasExplicitProfileFlag: Bool,
        startedAt: Date,
        executableURL: URL
    ) {
        self.pid = pid
        self.profileDirectory = profileDirectory
        self.hasExplicitProfileFlag = hasExplicitProfileFlag
        self.startedAt = startedAt
        self.executableURL = executableURL
    }
}

/// Which profiles live Claude processes use, for a caller about to move a profile folder.
public struct ProfilesInUse: Equatable, Sendable {
    public var profiles: [URL]
    /// A live bundle process tied to no profile, such as a helper whose main is gone.
    public var unattributed: Bool

    public init(profiles: [URL] = [], unattributed: Bool = false) {
        self.profiles = profiles
        self.unattributed = unattributed
    }
}

public enum QuitOutcome: Equatable, Sendable {
    /// The process table already showed no main instance.
    case alreadyStopped
    /// Every main instance exited after a normal quit.
    case quit
    /// At least one main instance needed SIGTERM after the normal quit.
    case quitAfterSignal
    /// At least one main instance needed a forced termination.
    case quitAfterForce
}

public struct LaunchEvent: Equatable, Sendable {
    public var pid: Int32
    public var profileDirectory: URL
    /// True when the new process's argv contained `--user-data-dir` in either
    /// form. Auto-correct treats a launch with this flag clear as someone else
    /// opening the default account. Our own launches always set it.
    public var hasExplicitProfileFlag: Bool

    public init(pid: Int32, profileDirectory: URL, hasExplicitProfileFlag: Bool) {
        self.pid = pid
        self.profileDirectory = profileDirectory
        self.hasExplicitProfileFlag = hasExplicitProfileFlag
    }
}

public enum ClaudeProcessError: Error, Equatable, Sendable {
    /// The process table could not be read. Callers must not treat this as "not running".
    case processTableUnavailable
    /// The close did not finish. `closedProfiles` lists only profiles proven to have no
    /// Desktop-owned process left, so a caller may reopen them; it is empty whenever that
    /// cannot be proven. `names` are the executable names of what was left, and `stall` why the
    /// close stopped, both for the log.
    case stillRunning(pids: [Int32], closedProfiles: [URL] = [], names: [String] = [], stall: CloseStall = .unknown)
    case launchFailed
    /// The instance started by a failed launch has not been confirmed closed.
    case launchCleanupFailed
    /// The deep link was not `local_` plus 1–64 of `[A-Za-z0-9-]`. Nothing was launched.
    case invalidDeepLink

    /// Why a close stopped before every process had ended.
    public enum CloseStall: Equatable, Sendable {
        /// A Claude main process started again while the close ran.
        case reopened
        /// Forcing the rest was not allowed: a Code task was running.
        case notForced
        /// Processes were still there after they were forced to quit.
        case survivedForce
        /// The close used up its time.
        case outOfTime
        /// Not recorded.
        case unknown
    }
}

/// Quits and launches Claude Desktop main processes.
///
/// Helpers, crashpad, and `Claude Helper*.app` are not main instances. Closing
/// may own them through the documented bundle/descendant rules, but a helper
/// without a profile flag must never be reported as a default-profile instance.
/// The profile path and `hasExplicitProfileFlag`
/// are taken from the exact argument vector, including both `--user-data-dir=<path>`
/// and the two-token form. The flag is true only when one of those forms is present.
public protocol ClaudeProcessControlling: Sendable {
    /// Success is the full set of main instances. Throws
    /// `ClaudeProcessError.processTableUnavailable` when the table cannot be read.
    func runningInstances() async throws -> [ClaudeInstance]

    /// Success is whether any live process from the Claude bundle is left, main or helper, other
    /// than the detached crash reporter. Helpers and the tasks under them can outlive their main
    /// process, so an empty `runningInstances()` does not mean Claude is fully closed. Throws
    /// `ClaudeProcessError.processTableUnavailable` when the table cannot be read.
    func hasAnyProcess() async throws -> Bool

    /// Success is every profile a live process from the Claude bundle still uses: a main
    /// instance's own, a helper's by its flags or its nearest main ancestor's. Helpers and the
    /// tasks under them can outlive their main process. `unattributed` means a live bundle process
    /// names no profile at all, so it may be using any. The detached crash reporter does not count.
    /// Throws `ClaudeProcessError.processTableUnavailable` when the table cannot be read.
    func profilesInUse() async throws -> ProfilesInUse

    /// Success means no main instance and no surviving process of the closing set is left.
    ///
    /// `timeout` is the whole budget. The closing set is recorded when the close begins:
    /// every main instance plus every descendant of a process inside the Claude bundle,
    /// each identified by pid, start time and executable; nothing outside it is ever
    /// signalled. `beforeForce` runs before any forced step, and when it returns false
    /// nothing is forced and the close fails. `immediately` skips Claude's own quit and the
    /// signal after it and forces the closing set at once, for a close the person already
    /// confirmed: Claude's quit would ask them again. A main instance that appears during the
    /// close stops it at once and is never signalled. Throws `stillRunning` (with the
    /// profiles proven closed) or `processTableUnavailable`.
    func quitAll(timeout: Duration, immediately: Bool,
                 beforeForce: @escaping @Sendable () async -> Bool) async throws -> QuitOutcome

    /// Closes exactly this main instance and its descendants, preserving other instances.
    func quit(instance: ClaudeInstance, timeout: Duration,
              beforeForce: @escaping @Sendable () async -> Bool) async throws -> QuitOutcome

    /// Success is a main instance observed for `profile`.
    ///
    /// The user-data-dir argument is always explicit, including for the default
    /// profile, and the returned instance has `hasExplicitProfileFlag == true`.
    /// A non-nil deep link is delivered to that same new instance; if that launch
    /// fails, the adapter falls back to a plain launch that still passes the flag.
    /// An invalid link throws `invalidDeepLink` and launches nothing. Throws
    /// `launchFailed` when no main instance for `profile` appears in time; `launchCleanupFailed`
    /// means the new instance has not been confirmed closed, so restoring a previous account is unsafe.
    func launch(profile: URL, deepLink: URL?) async throws -> ClaudeInstance
}

public extension ClaudeProcessControlling {
    /// Lets Claude quit by itself first.
    func quitAll(timeout: Duration, beforeForce: @escaping @Sendable () async -> Bool) async throws -> QuitOutcome {
        try await quitAll(timeout: timeout, immediately: false, beforeForce: beforeForce)
    }

    /// Closes without a pre-force check. Operations that may interrupt a Code task pass
    /// their own `beforeForce`; this form is for callers that already accepted that.
    func quitAll(timeout: Duration) async throws -> QuitOutcome {
        try await quitAll(timeout: timeout, beforeForce: { true })
    }
}

/// Reports each new Claude main-process launch.
///
/// Success is one event per launch. The stream finishes when monitoring stops.
/// A helper or crashpad process is never an event. `hasExplicitProfileFlag` is
/// false only when that process was started without `--user-data-dir`.
public protocol ClaudeLaunchMonitoring: Sendable {
    func launches() -> AsyncStream<LaunchEvent>
}
