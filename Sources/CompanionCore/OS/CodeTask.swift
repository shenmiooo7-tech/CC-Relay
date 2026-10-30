import Foundation

public enum CodeTaskBusyReason: Equatable, Sendable, Hashable {
    /// Registry `status` is `busy`.
    case statusBusy
    /// Registry `status` is `idle`, and a direct child is `sh`, `bash`, `zsh`, or `fish`.
    case shellChild(pid: Int32)
}

public struct CodeTaskInfo: Equatable, Sendable, Hashable {
    public var pid: Int32
    public var sessionID: String?
    public var workingDirectory: String?
    public var reason: CodeTaskBusyReason

    public init(
        pid: Int32,
        sessionID: String? = nil,
        workingDirectory: String? = nil,
        reason: CodeTaskBusyReason
    ) {
        self.pid = pid
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.reason = reason
    }
}

public enum TaskActivity: Equatable, Sendable {
    case idle
    case busy([CodeTaskInfo])
    case unknown(String)
}

/// Stable `TaskActivity.unknown` codes. The associated string is one of these,
/// never file contents, a cookie, or a token.
public enum TaskUnknownReason {
    public static let processTableUnavailable = "processTableUnavailable"
    public static let registryUnreadable = "registryUnreadable"
    public static let registryMismatch = "registryMismatch"
    public static let homeUnavailable = "homeUnavailable"
}

/// Answers whether a Desktop-hosted Claude Code turn is in progress.
///
/// `.idle` means every such `claude` process is idle and has no shell child.
/// `.busy` lists the ones that are mid-turn or holding a shell. `.unknown`
/// means the answer cannot be trusted, and callers must not quit Claude.
/// A missing, mismatched, or unreadable registry record is `.unknown`, never `.idle`.
/// This method does not throw.
public protocol CodeTaskInspecting: Sendable {
    func activity() async -> TaskActivity
}
