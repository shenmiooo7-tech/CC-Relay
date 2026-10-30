import Foundation

/// Every switch leaves one line in the log: from where to where, how it ended and how long it
/// took, so success and failure rates can be read off real use. Folder names only, never account
/// names or emails.
enum SwitchLog {
    static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.1f s", max(0, interval))
    }

    /// What a failed close left running and why it stopped, for the end of the line.
    static func closeDetail(_ error: any Error) -> String {
        switch error as? ClaudeProcessError {
        case .stillRunning(let pids, _, let names, let stall)?:
            let count = pids.count == 1 ? "1 process" : "\(pids.count) processes"
            let why = switch stall {
            case .reopened: "; Claude opened again during the close"
            case .notForced: "; not forced while a Code task ran"
            case .survivedForce: "; after a forced quit"
            case .outOfTime: "; the close ran out of time"
            case .unknown: ""
            }
            return " (\(count) still running" + (names.isEmpty ? "" : ": " + names.joined(separator: ", ")) + why + ")"
        case .processTableUnavailable?:
            return " (the process list could not be read)"
        default:
            return ""
        }
    }

    static func warnings(_ warnings: [OperationWarning]) -> String {
        warnings.isEmpty ? "" : "; warnings: " + warnings.map { String(describing: $0) }.joined(separator: ", ")
    }

    /// The compaction before the switch, with its own time: it is not part of the switch's.
    static func compaction(_ record: CompactionRecord) -> String {
        let time = seconds(record.seconds)
        switch record.outcome {
        case .answered(let answer) where answer.outcome == .compacted:
            let after = answer.tokensAfter.map { " -> \($0)" } ?? ""
            return "; compacted first: \(record.tokens)\(after) tokens in \(time)"
        case .answered(let answer):
            return "; not compacted first (\(record.tokens) tokens): \(answer.outcome.rawValue) after \(time)"
                + (answer.error.map { ", \($0)" } ?? "")
        case .skippedByUser:
            return "; compaction first skipped by the user after \(time) (\(record.tokens) tokens)"
        case .cancelled:
            return "; compaction first called off by quitting after \(time) (\(record.tokens) tokens)"
        case .timedOut:
            return "; not compacted first (\(record.tokens) tokens): no answer in \(time)"
        case .unfinished:
            return "; not compacted first (\(record.tokens) tokens): still compacting after \(time)"
        case .notLive:
            return "; not compacted first (\(record.tokens) tokens): the plugin does not report this conversation"
        case .pluginOutdated:
            return "; not compacted first (\(record.tokens) tokens): the plugin in this conversation is too old to ask"
        case .notAsked:
            return "; not compacted first (\(record.tokens) tokens): the request could not be written"
        }
    }
}

/// What one switch went through, for its line in the log.
struct SwitchRecord {
    var source: ProfileFolder?
    /// Nil when the switch stopped before Claude was looked at.
    var claudeWasOpen: Bool?
    /// The task check's answer and the time spent on it: the prompt, and any wait for tasks to end.
    var taskCheck: (permission: TaskGuardPermission, seconds: TimeInterval)?
    /// Nil when the conversation was not long enough, or nothing was there to compact.
    var compaction: CompactionRecord?
    var closeFailure: (any Error)?
}
