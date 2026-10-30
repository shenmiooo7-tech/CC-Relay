import Foundation

public enum QuotaLevel: Sendable, Equatable, CaseIterable {
    /// Green.
    case ok
    /// Blue.
    case fair
    /// Yellow.
    case mid
    /// Red.
    case low

    /// Remaining percent: above 50 ok, 30–50 fair, above 10 and under 30 mid, 10 or less low.
    public static func fromRemainingPercent(_ percent: Int) -> QuotaLevel {
        if percent > 50 { return .ok }
        if percent >= 30 { return .fair }
        if percent > 10 { return .mid }
        return .low
    }
}

public struct ResetTimeFormatter: Sendable, Equatable {
    public var timeZone: TimeZone
    public var language: L10nLanguage
    public var now: Date

    public init(timeZone: TimeZone, language: L10nLanguage, now: Date) {
        self.timeZone = timeZone
        self.language = language
        self.now = now
    }

    public func fiveHourLine(resetAt: Date?) -> String {
        switch classify(resetAt) {
        case .missing:
            return L10nKey.notStarted.string(in: language)
        case .refreshing:
            return L10nKey.resetRefreshing.string(in: language)
        case .scheduled(let reset):
            return L10nKey.resetLine.string(in: language, parameters: [
                "time": clock(reset),
                "countdown": countdownText(until: reset),
            ])
        }
    }

    public func weeklyLine(resetAt: Date?) -> String {
        switch classify(resetAt) {
        case .missing:
            return L10nKey.notStarted.string(in: language)
        case .refreshing:
            return L10nKey.resetRefreshing.string(in: language)
        case .scheduled(let reset):
            switch language {
            case .zhHans:
                return weeklyChinese(reset)
            case .en:
                return englishFormatter(format: "EEE, MMM d, HH:mm").string(from: reset)
            }
        }
    }

    /// The date part of a weekly reset line: "10月27日 周二" / "Tue, Oct 27".
    public func weeklyDay(resetAt: Date) -> String {
        let reset = snapped(resetAt)
        switch language {
        case .zhHans:
            let parts = dateParts(reset)
            return "\(parts.monthNumber)月\(parts.dayNumber)日 \(parts.chineseWeekday)"
        case .en:
            return englishFormatter(format: "EEE, MMM d").string(from: reset)
        }
    }

    /// When a wait ends, in the minute it is over: "19:10" today, "10月27日 09:05" / "Oct 27, 09:05"
    /// on another day.
    public func moment(_ date: Date) -> String {
        let minute = Self.minuteOver(date)
        if gregorianCalendar().isDate(minute, inSameDayAs: now) { return clock(minute) }
        switch language {
        case .zhHans:
            let parts = dateParts(minute)
            return "\(parts.monthNumber)月\(parts.dayNumber)日 \(parts.clock)"
        case .en:
            return englishFormatter(format: "MMM d, HH:mm").string(from: minute)
        }
    }

    /// The clock of the minute a wait short enough to need no day is over: "19:10".
    public func minute(_ date: Date) -> String {
        clock(Self.minuteOver(date))
    }

    private static func minuteOver(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.up) * 60)
    }

    /// The start of the day a reset falls on, the day its line shows.
    func resetDay(_ resetAt: Date) -> Date {
        gregorianCalendar().startOfDay(for: snapped(resetAt))
    }

    public func tooltip(resetAt: Date?) -> String {
        switch classify(resetAt) {
        case .missing:
            return L10nKey.notStarted.string(in: language)
        case .refreshing:
            return L10nKey.resetRefreshing.string(in: language)
        case .scheduled(let reset):
            return tooltipSentence(reset)
        }
    }

    private func tooltipSentence(_ reset: Date) -> String {
        let parts = dateParts(reset)
        switch language {
        case .zhHans:
            return L10nKey.resetTooltip.string(in: language, parameters: [
                "year": parts.year,
                "month": parts.monthNumber,
                "day": parts.dayNumber,
                "weekday": parts.chineseWeekday,
                "time": parts.clock,
            ])
        case .en:
            return L10nKey.resetTooltip.string(in: language, parameters: [
                "year": parts.year,
                "month": englishFormatter(format: "MMMM").string(from: reset),
                "day": parts.dayNumber,
                "weekday": englishFormatter(format: "EEEE").string(from: reset),
                "time": parts.clock,
            ])
        }
    }

    private enum ResetTiming {
        case missing
        case refreshing
        case scheduled(Date)
    }

    /// A nil reset has not started. A reset that is already past is waiting for a new reading.
    /// Snapping can land on `now` while the original instant is still ahead; that stays a countdown.
    private func classify(_ resetAt: Date?) -> ResetTiming {
        guard let resetAt else { return .missing }
        let reset = snapped(resetAt)
        if reset.timeIntervalSince(now) > 0 || resetAt.timeIntervalSince(now) > 0 {
            return .scheduled(reset)
        }
        return .refreshing
    }

    private func countdownText(until reset: Date) -> String {
        let seconds = max(0, reset.timeIntervalSince(now))
        let minutesTotal = max(1, Int((seconds / 60).rounded(.up)))
        let hours = minutesTotal / 60
        let minutes = minutesTotal % 60
        if hours == 0 {
            return L10nKey.countdownMinutes.string(in: language, parameters: [
                "m": String(minutes),
            ])
        }
        if minutes == 0 {
            return L10nKey.countdownHours.string(in: language, parameters: [
                "h": String(hours),
            ])
        }
        return L10nKey.countdownHoursMinutes.string(in: language, parameters: [
            "h": String(hours),
            "m": String(minutes),
        ])
    }

    private func weeklyChinese(_ date: Date) -> String {
        let parts = dateParts(date)
        return "\(parts.monthNumber)月\(parts.dayNumber)日 \(parts.chineseWeekday) \(parts.clock)"
    }

    private func clock(_ date: Date) -> String {
        dateParts(date).clock
    }

    private struct DateParts {
        var year: String
        var monthNumber: String
        var dayNumber: String
        var clock: String
        var chineseWeekday: String
    }

    private func dateParts(_ date: Date) -> DateParts {
        let calendar = gregorianCalendar()
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return DateParts(
            year: String(calendar.component(.year, from: date)),
            monthNumber: String(calendar.component(.month, from: date)),
            dayNumber: String(calendar.component(.day, from: date)),
            clock: String(format: "%02d:%02d", hour, minute),
            chineseWeekday: Self.chineseWeekday(calendar.component(.weekday, from: date))
        )
    }

    /// Gregorian weekday: 1 is Sunday.
    private static func chineseWeekday(_ weekday: Int) -> String {
        switch weekday {
        case 1: "周日"
        case 2: "周一"
        case 3: "周二"
        case 4: "周三"
        case 5: "周四"
        case 6: "周五"
        case 7: "周六"
        default: "周日"
        }
    }

    private func englishFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.calendar = gregorianCalendar(locale: Locale(identifier: "en_US_POSIX"))
        formatter.dateFormat = format
        return formatter
    }

    private func gregorianCalendar(locale: Locale? = nil) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if let locale {
            calendar.locale = locale
        }
        return calendar
    }

    /// A reset within one second of a minute boundary is shown on that minute.
    private func snapped(_ date: Date) -> Date {
        let millis = Int((date.timeIntervalSince1970 * 1000).rounded())
        if millis < 0 { return date }
        let minute = 60_000
        let remainder = millis % minute
        if remainder <= 1000 {
            return Date(timeIntervalSince1970: Double(millis - remainder) / 1000)
        }
        if minute - remainder <= 1000 {
            return Date(timeIntervalSince1970: Double(millis + (minute - remainder)) / 1000)
        }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }
}
