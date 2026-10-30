import XCTest
@testable import CompanionUI

final class ResetTimeFormatterTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let utc = TimeZone(identifier: "UTC")!

    func testNilResetIsNotStartedAndPastResetIsRefreshing() {
        let now = PanelFixtures.date(2026, 10, 25, 18, 30)
        for language in L10nLanguage.allCases {
            for zone in [shanghai, utc] {
                let formatter = ResetTimeFormatter(timeZone: zone, language: language, now: now)
                let notStarted = L10nKey.notStarted.string(in: language)
                XCTAssertEqual(formatter.fiveHourLine(resetAt: nil), notStarted)
                XCTAssertEqual(formatter.weeklyLine(resetAt: nil), notStarted)
                XCTAssertEqual(formatter.tooltip(resetAt: nil), notStarted)
                let refreshing = L10nKey.resetRefreshing.string(in: language)
                let past = now.addingTimeInterval(-60)
                XCTAssertEqual(formatter.fiveHourLine(resetAt: past), refreshing)
                XCTAssertEqual(formatter.weeklyLine(resetAt: past), refreshing)
                XCTAssertEqual(formatter.tooltip(resetAt: past), refreshing)
            }
        }
        let zh = ResetTimeFormatter(timeZone: shanghai, language: .zhHans, now: now)
        let en = ResetTimeFormatter(timeZone: shanghai, language: .en, now: now)
        XCTAssertEqual(zh.fiveHourLine(resetAt: now.addingTimeInterval(-1)), "已重置，正在刷新…")
        XCTAssertEqual(en.fiveHourLine(resetAt: now.addingTimeInterval(-1)), "Reset, refreshing…")
    }

    func testFiveHourCountdownInShanghaiAndUTC() {
        let now = date(2026, 10, 25, 18, 30, shanghai)
        let underAnHour = date(2026, 10, 25, 18, 55, shanghai)
        let fourHours = date(2026, 10, 25, 23, 29, shanghai)
        let exactlyOneHour = date(2026, 10, 25, 19, 30, shanghai)
        let fiftyNineMinutes = date(2026, 10, 25, 19, 29, shanghai)

        let zh = ResetTimeFormatter(timeZone: shanghai, language: .zhHans, now: now)
        XCTAssertEqual(zh.fiveHourLine(resetAt: underAnHour), "18:55 · 25 分后")
        XCTAssertEqual(zh.fiveHourLine(resetAt: fourHours), "23:29 · 4 小时 59 分后")
        XCTAssertEqual(zh.fiveHourLine(resetAt: exactlyOneHour), "19:30 · 1 小时后")
        XCTAssertEqual(zh.fiveHourLine(resetAt: fiftyNineMinutes), "19:29 · 59 分后")

        let en = ResetTimeFormatter(timeZone: shanghai, language: .en, now: now)
        XCTAssertEqual(en.fiveHourLine(resetAt: underAnHour), "18:55 · in 25m")
        XCTAssertEqual(en.fiveHourLine(resetAt: fourHours), "23:29 · in 4h 59m")
        XCTAssertEqual(en.fiveHourLine(resetAt: exactlyOneHour), "19:30 · in 1h")
        XCTAssertEqual(en.fiveHourLine(resetAt: fiftyNineMinutes), "19:29 · in 59m")

        let utcNow = date(2026, 10, 25, 10, 30, utc)
        let utcReset = date(2026, 10, 25, 10, 55, utc)
        let utcFormatter = ResetTimeFormatter(timeZone: utc, language: .en, now: utcNow)
        XCTAssertEqual(utcFormatter.fiveHourLine(resetAt: utcReset), "10:55 · in 25m")

        let sameInstantShanghai = ResetTimeFormatter(timeZone: shanghai, language: .zhHans, now: utcNow)
        XCTAssertEqual(sameInstantShanghai.fiveHourLine(resetAt: utcReset), "18:55 · 25 分后")
    }

    func testZeroMinutesAreOmittedFromTheCountdown() {
        let now = date(2026, 10, 25, 18, 30, shanghai)
        let zh = ResetTimeFormatter(timeZone: shanghai, language: .zhHans, now: now)
        let en = ResetTimeFormatter(timeZone: shanghai, language: .en, now: now)

        let fiveHours = now.addingTimeInterval(5 * 60 * 60)
        XCTAssertEqual(zh.fiveHourLine(resetAt: fiveHours), "23:30 · 5 小时后")
        XCTAssertEqual(en.fiveHourLine(resetAt: fiveHours), "23:30 · in 5h")

        let fiftyNineMinutesThirty = now.addingTimeInterval(59 * 60 + 30)
        XCTAssertEqual(zh.fiveHourLine(resetAt: fiftyNineMinutesThirty), "19:29 · 1 小时后")
        XCTAssertEqual(en.fiveHourLine(resetAt: fiftyNineMinutesThirty), "19:29 · in 1h")

        let oneSecond = now.addingTimeInterval(1)
        XCTAssertEqual(zh.fiveHourLine(resetAt: oneSecond), "18:30 · 1 分后")
        XCTAssertEqual(en.fiveHourLine(resetAt: oneSecond), "18:30 · in 1m")
    }

    func testWeeklyFormatUses24HourClockAndPOSIXAbbreviations() {
        let now = date(2026, 10, 25, 18, 30, shanghai)
        let thursday = date(2026, 10, 29, 21, 0, shanghai)
        let early = date(2026, 10, 26, 0, 30, shanghai)

        let zh = ResetTimeFormatter(timeZone: shanghai, language: .zhHans, now: now)
        XCTAssertEqual(zh.weeklyLine(resetAt: thursday), "10月29日 周四 21:00")
        XCTAssertEqual(zh.weeklyLine(resetAt: early), "10月26日 周一 00:30")

        let en = ResetTimeFormatter(timeZone: shanghai, language: .en, now: now)
        XCTAssertEqual(en.weeklyLine(resetAt: thursday), "Thu, Oct 29, 21:00")
        let yearEnd = en.weeklyLine(resetAt: date(2026, 12, 31, 23, 59, shanghai))
        XCTAssertTrue(yearEnd.hasSuffix("Dec 31, 23:59"), yearEnd)
        XCTAssertFalse(yearEnd.contains("PM"))

        let utcEnglish = ResetTimeFormatter(timeZone: utc, language: .en, now: now)
        XCTAssertEqual(utcEnglish.weeklyLine(resetAt: thursday), "Thu, Oct 29, 13:00")
        let utcChinese = ResetTimeFormatter(timeZone: utc, language: .zhHans, now: now)
        XCTAssertEqual(utcChinese.weeklyLine(resetAt: thursday), "10月29日 周四 13:00")

        let sundayUTC = ResetTimeFormatter(timeZone: utc, language: .en, now: date(2026, 10, 20, 0, 0, utc))
        XCTAssertEqual(sundayUTC.weeklyLine(resetAt: early), "Sun, Oct 25, 16:30")
    }

    func testTooltipSentence() {
        let now = date(2026, 10, 25, 18, 30, shanghai)
        let reset = date(2026, 10, 29, 21, 0, shanghai)
        let zh = ResetTimeFormatter(timeZone: shanghai, language: .zhHans, now: now)
        XCTAssertEqual(zh.tooltip(resetAt: reset), "将于 2026年10月29日 周四 21:00 重置")
        let en = ResetTimeFormatter(timeZone: shanghai, language: .en, now: now)
        XCTAssertEqual(en.tooltip(resetAt: reset), "Resets on Thursday, October 29, 2026 at 21:00")
        let utc = ResetTimeFormatter(timeZone: utc, language: .en, now: now)
        XCTAssertEqual(utc.tooltip(resetAt: reset), "Resets on Thursday, October 29, 2026 at 13:00")
    }

    func testSnapWithinOneSecondOfAMinute() {
        let now = date(2026, 10, 25, 18, 30, shanghai)
        let zh = ResetTimeFormatter(timeZone: shanghai, language: .zhHans, now: now)
        let justBefore = date(2026, 10, 25, 21, 0, shanghai).addingTimeInterval(-0.6)
        XCTAssertEqual(zh.fiveHourLine(resetAt: justBefore), "21:00 · 2 小时 30 分后")
        let justAfter = date(2026, 10, 25, 19, 0, shanghai).addingTimeInterval(0.4)
        XCTAssertEqual(zh.fiveHourLine(resetAt: justAfter), "19:00 · 30 分后")
        let weekly = ResetTimeFormatter(timeZone: shanghai, language: .en, now: now)
        let almostThursday = date(2026, 10, 29, 21, 0, shanghai).addingTimeInterval(-0.4)
        XCTAssertEqual(weekly.weeklyLine(resetAt: almostThursday), "Thu, Oct 29, 21:00")
    }

    func testQuotaLevelBoundaries() {
        XCTAssertEqual(QuotaLevel.fromRemainingPercent(100), .ok)
        XCTAssertEqual(QuotaLevel.fromRemainingPercent(51), .ok)
        XCTAssertEqual(QuotaLevel.fromRemainingPercent(50), .fair)
        XCTAssertEqual(QuotaLevel.fromRemainingPercent(30), .fair)
        XCTAssertEqual(QuotaLevel.fromRemainingPercent(29), .mid)
        XCTAssertEqual(QuotaLevel.fromRemainingPercent(11), .mid)
        XCTAssertEqual(QuotaLevel.fromRemainingPercent(10), .low)
        XCTAssertEqual(QuotaLevel.fromRemainingPercent(0), .low)
    }

    func testBarFillNeverThinnerThanTwoPercentUnlessEmpty() {
        let empty = QuotaBlockState(title: "5 小时", remainingPercent: nil, level: .low, resetLine: "", tooltip: "")
        XCTAssertEqual(empty.fillFraction, 0)
        let zero = QuotaBlockState(title: "5 小时", remainingPercent: 0, level: .low, resetLine: "", tooltip: "")
        XCTAssertEqual(zero.fillFraction, 0)
        let one = QuotaBlockState(title: "5 小时", remainingPercent: 1, level: .low, resetLine: "", tooltip: "")
        XCTAssertEqual(one.fillFraction, 0.02, accuracy: 0.0001)
        let half = QuotaBlockState(title: "5 小时", remainingPercent: 50, level: .ok, resetLine: "", tooltip: "")
        XCTAssertEqual(half.fillFraction, 0.5, accuracy: 0.0001)
    }

    func testNameCheck() {
        XCTAssertEqual(NameCheck.problem(in: "   "), .empty)
        XCTAssertNil(NameCheck.problem(in: String(repeating: "名", count: 20)))
        XCTAssertEqual(NameCheck.problem(in: String(repeating: "a", count: 21)), .tooLong)
    }

    func testFixtureUsesTheContractTooltip() async throws {
        let zh = try await FixtureScene.main.make(.zhHans)
        XCTAssertEqual(zh.current?.name, "204")
        XCTAssertEqual(zh.others.map(\.name), ["201", "203", "208"])
        XCTAssertEqual(zh.current?.weekly.tooltip, "将于 2026年10月29日 周四 21:00 重置")
        XCTAssertEqual(zh.current?.fiveHour.resetLine, "21:00 · 2 小时 30 分后")
        XCTAssertEqual(zh.current?.fiveHour.level, .ok)
        XCTAssertEqual(zh.current?.weekly.level, .fair)
        XCTAssertEqual(zh.others[0].channelText, "App Store 订阅")
        XCTAssertEqual(zh.others[0].fiveHour.resetLine, "19:05 · 35 分后")
        XCTAssertEqual(zh.others[0].fiveHour.level, .mid)
        XCTAssertEqual(zh.others[2].fiveHour.remainingPercent, 100)
        XCTAssertEqual(zh.others[2].fiveHour.level, .ok)
        XCTAssertEqual(zh.others[2].fiveHour.resetLine, "未计时")
        XCTAssertEqual(zh.others[2].fiveHour.fillFraction, 1, accuracy: 0.0001)
        let signedOut = try await FixtureScene.signedOut.make(.zhHans)
        XCTAssertNil(signedOut.others[0].weekly.remainingPercent)
        XCTAssertEqual(signedOut.others[0].weekly.resetLine, "\u{2014}")
        XCTAssertNotEqual(signedOut.others[0].weekly.resetLine, "未计时")
        let en = try await FixtureScene.main.make(.en)
        XCTAssertEqual(en.current?.weekly.tooltip, "Resets on Thursday, October 29, 2026 at 21:00")
        XCTAssertEqual(en.current?.fiveHour.resetLine, "21:00 · in 2h 30m")
        XCTAssertEqual(en.current?.weekly.resetLine, "Thu, Oct 29, 21:00")
    }

    func testAMomentIsItsClockTodayAndItsDateOnAnotherDayRoundedUpToTheMinute() {
        let now = date(2026, 10, 25, 18, 30, shanghai)
        let zh = ResetTimeFormatter(timeZone: shanghai, language: .zhHans, now: now)
        let en = ResetTimeFormatter(timeZone: shanghai, language: .en, now: now)
        XCTAssertEqual(zh.moment(date(2026, 10, 25, 19, 10, shanghai)), "19:10")
        XCTAssertEqual(zh.moment(date(2026, 10, 25, 19, 9, shanghai).addingTimeInterval(1)), "19:10")
        XCTAssertEqual(zh.moment(date(2026, 10, 27, 9, 5, shanghai)), "10月27日 09:05")
        XCTAssertEqual(zh.moment(date(2026, 10, 25, 23, 59, shanghai).addingTimeInterval(30)), "10月26日 00:00")
        XCTAssertEqual(en.moment(date(2026, 10, 25, 19, 10, shanghai)), "19:10")
        XCTAssertEqual(en.moment(date(2026, 10, 27, 9, 5, shanghai)), "Oct 27, 09:05")
        XCTAssertEqual(zh.minute(date(2026, 10, 25, 23, 59, shanghai).addingTimeInterval(30)), "00:00")
        XCTAssertEqual(en.minute(date(2026, 10, 25, 19, 9, shanghai).addingTimeInterval(59)), "19:10")
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0))!
    }
}
