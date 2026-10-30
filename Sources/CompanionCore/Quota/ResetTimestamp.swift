import Foundation

enum ResetTimestamp {
    /// A reset within one second of a minute is that minute.
    static func snap(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return date }
        let start = (seconds / 60).rounded(.down) * 60
        let end = start + 60
        if abs(seconds - start) <= 1 {
            return Date(timeIntervalSince1970: start)
        }
        if abs(seconds - end) <= 1 {
            return Date(timeIntervalSince1970: end)
        }
        return date
    }
}
