import XCTest
@testable import CompanionUI

final class RecommenderTests: XCTestCase {
    private let zone = PanelFixtures.timeZone
    private let now = PanelFixtures.date(2026, 10, 26, 10, 0)

    private var recommender: Recommender {
        Recommender(formatter: ResetTimeFormatter(timeZone: zone, language: .zhHans, now: now))
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        PanelFixtures.date(2026, 10, day, hour, minute)
    }

    private func standing(_ id: String, five: Int? = 80, week: Int? = 50, resets: Date?) -> QuotaStanding {
        QuotaStanding(id: id, fiveHour: five, weekly: week, weeklyResetsAt: resets)
    }

    /// Out of its 5-hour window, so another account is suggested.
    private var outCurrent: QuotaStanding { standing("current", five: 5, resets: at(31, 9)) }
    private let out = Recommendation.Reason.currentFiveHourLow(percent: 5)

    func testNothingIsSuggestedWhileTheCurrentAccountCanBeUsed() {
        // A switch restarts Claude and a long conversation is read again on the next account, so an
        // earlier weekly reset elsewhere is no reason to leave an account that still works.
        let current = standing("current", resets: at(31, 9))
        XCTAssertNil(recommender.decide(current: current, others: [standing("soon", resets: at(27, 9))]))
        XCTAssertNil(recommender.decide(current: current, others: [standing("later", resets: at(31, 23))]))
        XCTAssertNil(recommender.decide(current: current, others: [standing("spent", week: 0, resets: at(27, 9))]))
        XCTAssertNil(recommender.decide(current: standing("current", resets: nil), others: [standing("soon", resets: at(28, 9))]))
        // Ten percent of the 5-hour window and one percent of the week still count as usable.
        XCTAssertNil(recommender.decide(current: standing("current", five: 10, week: 1, resets: at(31, 9)),
                                        others: [standing("soon", resets: at(27, 9))]))
    }

    func testTheNearestResetDayWinsWhateverTheHour() {
        // Tomorrow just before midnight beats the day after just after it.
        let lateTomorrow = standing("late", five: 30, resets: at(27, 23, 59))
        let earlyNextDay = standing("early", five: 100, resets: at(28, 0, 1))
        XCTAssertEqual(recommender.decide(current: outCurrent, others: [earlyNextDay, lateTomorrow]),
                       .switchTo(id: "late", reason: out))
    }

    func testAWeekNearlyOutWaitsUntilNoOtherAccountCanBeUsed() {
        // Four percent left gives way, even with the nearest reset; five is enough.
        let nearlyOut = standing("nearly-out", week: 4, resets: at(27, 9))
        let later = standing("later", week: 60, resets: at(30, 9))
        XCTAssertEqual(recommender.decide(current: outCurrent, others: [nearlyOut, later]),
                       .switchTo(id: "later", reason: out))
        XCTAssertEqual(recommender.decide(current: outCurrent, others: [standing("enough", week: 5, resets: at(27, 9)), later]),
                       .switchTo(id: "enough", reason: out))
        // It also gives way to a week that has not started, which otherwise ranks last.
        XCTAssertEqual(recommender.decide(current: outCurrent, others: [nearlyOut, standing("fresh", week: 100, resets: nil)]),
                       .switchTo(id: "fresh", reason: out))
        // Alone, or among others nearly out, it is still taken, the nearest first as ever.
        XCTAssertEqual(recommender.decide(current: outCurrent, others: [nearlyOut]),
                       .switchTo(id: "nearly-out", reason: out))
        XCTAssertEqual(recommender.decide(current: outCurrent, others: [standing("other", week: 1, resets: at(29, 9)), nearlyOut]),
                       .switchTo(id: "nearly-out", reason: out))
    }

    func testOnOneDayTheLargerFiveHourWindowThenTheEarlierResetThenTheListOrderWins() {
        let morningLow = standing("morning", five: 40, resets: at(27, 8))
        let eveningHigh = standing("evening", five: 90, resets: at(27, 20))
        XCTAssertEqual(recommender.decide(current: outCurrent, others: [morningLow, eveningHigh]),
                       .switchTo(id: "evening", reason: out))
        let morning = standing("morning", five: 90, resets: at(27, 8))
        let evening = standing("evening", five: 90, resets: at(27, 20))
        XCTAssertEqual(recommender.decide(current: outCurrent, others: [evening, morning]),
                       .switchTo(id: "morning", reason: out))
        let first = standing("first", five: 90, resets: at(27, 8))
        let second = standing("second", five: 90, resets: at(27, 8))
        XCTAssertEqual(recommender.decide(current: outCurrent, others: [first, second]), .switchTo(id: "first", reason: out))
        XCTAssertEqual(recommender.decide(current: outCurrent, others: [second, first]), .switchTo(id: "second", reason: out))
    }

    func testOnlyAnAccountWithWeeklyQuotaAndTenPercentOfItsFiveHoursIsSuggested() {
        let later = standing("later", resets: at(30, 9))
        let candidates: [(QuotaStanding, Bool)] = [
            (standing("ten", five: 10, resets: at(27, 9)), true),
            (standing("nine", five: 9, resets: at(27, 9)), false),
            (standing("spent", week: 0, resets: at(27, 9)), false),
            (standing("blind", five: nil, week: nil, resets: at(27, 9)), false),
            (standing("halfBlind", five: 80, week: nil, resets: at(27, 9)), false),
        ]
        for (candidate, usable) in candidates {
            let decision = recommender.decide(current: outCurrent, others: [later, candidate])
            XCTAssertEqual(decision, .switchTo(id: usable ? candidate.id : "later", reason: out), candidate.id)
        }
        // One percent of the week still counts as usable.
        XCTAssertEqual(recommender.decide(current: outCurrent, others: [standing("one", week: 1, resets: at(27, 9))]),
                       .switchTo(id: "one", reason: out))
    }

    func testAnAccountResettingAfterTheCurrentOneIsSuggestedOnceTheCurrentOneIsOut() {
        let current = standing("current", five: 5, resets: at(27, 9))
        XCTAssertEqual(recommender.decide(current: current, others: [standing("later", resets: at(29, 1))]),
                       .switchTo(id: "later", reason: out))
    }

    func testACurrentAccountThatIsOutSaysWhy() {
        let other = standing("other", resets: at(30, 9))
        XCTAssertEqual(recommender.decide(current: standing("current", five: nil, week: nil, resets: nil), others: [other]),
                       .switchTo(id: "other", reason: .currentUnknown))
        XCTAssertEqual(recommender.decide(current: standing("current", five: 5, week: 50, resets: at(27, 9)), others: [other]),
                       .switchTo(id: "other", reason: .currentFiveHourLow(percent: 5)))
        // Out on both counts, the week says more: it lasts until the weekly reset.
        XCTAssertEqual(recommender.decide(current: standing("current", five: 5, week: 0, resets: at(27, 9)), others: [other]),
                       .switchTo(id: "other", reason: .currentWeekSpent))
        XCTAssertEqual(recommender.decide(current: nil, others: [other]),
                       .switchTo(id: "other", reason: .noCurrent))
    }

    func testWhenNoAccountCanBeUsedALineSaysSoAndOtherwiseNothingShows() {
        let spent = standing("spent", five: 3, resets: at(27, 9))
        XCTAssertEqual(recommender.decide(current: standing("current", week: 0, resets: at(29, 9)), others: [spent]), .noneReady)
        XCTAssertEqual(recommender.decide(current: nil, others: [spent]), .noneReady)
        // The current account still works: no line about the others.
        XCTAssertNil(recommender.decide(current: standing("current", resets: at(29, 9)), others: [spent]))
        XCTAssertNil(recommender.decide(current: outCurrent, others: []))
    }

    func testAWeekThatHasNotStartedRanksAfterEveryWeekThatHas() {
        let notStarted = standing("fresh", five: 100, week: 100, resets: nil)
        let started = standing("started", five: 20, resets: at(31, 23))
        XCTAssertEqual(recommender.decide(current: outCurrent, others: [notStarted, started]), .switchTo(id: "started", reason: out))
        XCTAssertEqual(recommender.decide(current: outCurrent, others: [notStarted]), .switchTo(id: "fresh", reason: out))
    }

    func testAResetOnTheLastSecondOfADayCountsOnTheNextDayAsItsLineShows() {
        // Shown as 10月28日, it ranks with that day's accounts, where the larger 5-hour window wins.
        let edge = standing("edge", five: 40, resets: at(27, 23, 59).addingTimeInterval(59.6))
        let morning = standing("morning", five: 90, resets: at(28, 8))
        XCTAssertEqual(recommender.decide(current: outCurrent, others: [edge, morning]), .switchTo(id: "morning", reason: out))
        let formatter = ResetTimeFormatter(timeZone: zone, language: .zhHans, now: now)
        XCTAssertEqual(formatter.weeklyDay(resetAt: at(27, 23, 59).addingTimeInterval(59.6)), "10月28日 周三")
    }

    func testTheReasonLinesInBothLanguages() {
        func copy(_ decision: Recommendation, _ day: String?, _ language: L10nLanguage) -> String {
            RecommendationCopy.reason(for: decision, day: day, language: language)
        }
        XCTAssertEqual(copy(.switchTo(id: "a", reason: .currentFiveHourLow(percent: 4)), "10月27日 周二", .zhHans),
                       "周限额 10月27日 周二 重置，日期最近；当前 5 小时只剩 4%")
        XCTAssertEqual(copy(.switchTo(id: "a", reason: .currentFiveHourLow(percent: 4)), "Tue, Oct 27", .en),
                       "Week resets Tue, Oct 27, soonest · current 5h at 4%")
        XCTAssertEqual(copy(.switchTo(id: "a", reason: .currentWeekSpent), nil, .zhHans), "每周额度未计时；当前每周额度已用完")
        XCTAssertEqual(copy(.switchTo(id: "a", reason: .currentUnknown), "10月27日 周二", .zhHans),
                       "周限额 10月27日 周二 重置，日期最近；当前账号额度读不到")
        XCTAssertEqual(copy(.switchTo(id: "a", reason: .noCurrent), nil, .en), "Weekly not started")
        XCTAssertEqual(copy(.noneReady, nil, .zhHans), "暂时没有可用的账号，等额度恢复")
    }

    func testThePinnedTopKeepsItsHeightUntilTheListWouldGetTooLittle() {
        func split(_ top: CGFloat, _ list: CGFloat) -> [CGFloat] {
            let heights = PinnedTopLayout.split(top: top, list: list, limit: 720, minimumList: 160)
            return [heights.top, heights.list]
        }
        XCTAssertEqual(split(400, 200), [400, 200])
        XCTAssertEqual(split(400, 800), [400, 320])
        XCTAssertEqual(split(560, 800), [560, 160])
        // A taller top scrolls in its own place and leaves the list its share.
        XCTAssertEqual(split(700, 800), [560, 160])
        XCTAssertEqual(split(700, 100), [620, 100])
        XCTAssertEqual(split(900, 0), [720, 0])
    }
}
