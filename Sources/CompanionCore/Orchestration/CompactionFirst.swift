import Foundation

/// The wait for a compaction before a switch: the panel can cut it short, and quitting calls the
/// switch off, since nothing has been touched yet.
public actor CompactionWait {
    enum Interruption: Equatable {
        case skipped
        case cancelled
    }

    private var closed = false
    private(set) var interruption: Interruption?

    public init() {}

    /// Each wait begins afresh, so a skip too late for one cannot cut the next one short.
    public func skip() {
        if interruption == nil { interruption = .skipped }
    }

    /// Quitting: the wait under way, and any that would begin after, ends with the switch called off.
    public func cancelAll() {
        closed = true
        interruption = .cancelled
    }

    func begin() {
        interruption = closed ? .cancelled : nil
    }

    func end() {
        interruption = nil
    }
}

/// How the compaction before a switch went, for the switch's result and its line in the log.
struct CompactionRecord {
    enum Outcome {
        /// The conversation's plugin has not reported lately, so nothing was asked.
        case notLive
        /// Its plugin reports but would not answer a request, so nothing was asked.
        case pluginOutdated
        /// The request could not be written.
        case notAsked
        case answered(SwitchCompactionAnswer)
        case skippedByUser
        /// CC-Relay quit during the wait: the switch is called off.
        case cancelled
        /// Nothing began, and no answer came, in time.
        case timedOut
        /// It began and had not ended when the switch stopped waiting.
        case unfinished
    }

    var tokens: Int
    var outcome: Outcome
    var seconds: TimeInterval = 0

    /// The switch asked and waited, time in which a Code task could begin.
    var waited: Bool {
        switch outcome {
        case .notLive, .pluginOutdated, .notAsked: false
        case .answered, .skippedByUser, .cancelled, .timedOut, .unfinished: true
        }
    }

    /// Asked for and not compacted, for a reason the user did not choose.
    var missed: Bool {
        switch outcome {
        case .answered(let answer): answer.outcome != .compacted
        case .skippedByUser, .cancelled: false
        case .notLive, .pluginOutdated, .notAsked, .timedOut, .unfinished: true
        }
    }
}
