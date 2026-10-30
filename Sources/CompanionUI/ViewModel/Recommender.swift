import Foundation

/// What one account can do now, read from the same figures its card shows.
struct QuotaStanding: Equatable {
    var id: String
    /// Remaining percent. Nil when the account's quota is not known.
    var fiveHour: Int?
    var weekly: Int?
    /// When the weekly window resets. Nil when that week has not started, or has reset and not started again.
    var weeklyResetsAt: Date?

    /// Below this the 5-hour window is nearly out, so the account is not worth switching to.
    static let minimumFiveHour = 10
    /// Below this the week is nearly out: a long conversation can use it up within minutes, and Claude
    /// closes again for the next account.
    static let lowWeekly = 5

    var isUsable: Bool {
        guard let fiveHour, let weekly else { return false }
        return fiveHour >= Self.minimumFiveHour && weekly > 0
    }

    var weekIsLow: Bool { (weekly ?? 0) < Self.lowWeekly }
}

enum Recommendation: Equatable {
    enum Reason: Equatable {
        case currentUnknown
        case currentFiveHourLow(percent: Int)
        case currentWeekSpent
        case noCurrent
    }

    case switchTo(id: String, reason: Reason)
    /// The current account is out and no other one can be used now.
    case noneReady
}

/// Once the current account is out, suggests the usable account whose weekly limit resets on the nearest
/// day, so quota that is about to reset gets used first. While the current account can be used nothing is
/// suggested: a switch restarts Claude, and a long conversation is read again in full on the next account.
/// Usable: weekly quota left and the 5-hour window at `minimumFiveHour` or more. Days, not hours, as the
/// cards show them: accounts that reset on the same day rank by the larger 5-hour remaining, then the
/// earlier reset. A week that has not started resets seven days after it does, so it ranks after every
/// week that has. A week nearly out ranks after all of them, and is suggested only when nothing else can be.
struct Recommender {
    var formatter: ResetTimeFormatter

    /// Nil when there is no other account, or while the current one can be used.
    func decide(current: QuotaStanding?, others: [QuotaStanding]) -> Recommendation? {
        guard !others.isEmpty, current?.isUsable != true else { return nil }
        let ranked = others.enumerated()
            .filter { $0.element.isUsable }
            .sorted { ranksBefore($0, $1) }
            .map(\.element)
        guard let best = ranked.first else { return .noneReady }
        guard let current else { return .switchTo(id: best.id, reason: .noCurrent) }
        return .switchTo(id: best.id, reason: reason(why: current))
    }

    private func reason(why current: QuotaStanding) -> Recommendation.Reason {
        guard let fiveHour = current.fiveHour, let weekly = current.weekly else { return .currentUnknown }
        if weekly <= 0 { return .currentWeekSpent }
        return .currentFiveHourLow(percent: fiveHour)
    }

    private func ranksBefore(_ a: (offset: Int, element: QuotaStanding), _ b: (offset: Int, element: QuotaStanding)) -> Bool {
        if a.element.weekIsLow != b.element.weekIsLow { return b.element.weekIsLow }
        let dayA = resetDay(a.element), dayB = resetDay(b.element)
        if dayA != dayB { return dayA < dayB }
        let fiveA = a.element.fiveHour ?? 0, fiveB = b.element.fiveHour ?? 0
        if fiveA != fiveB { return fiveA > fiveB }
        let resetA = resetInstant(a.element), resetB = resetInstant(b.element)
        if resetA != resetB { return resetA < resetB }
        return a.offset < b.offset
    }

    private func resetInstant(_ standing: QuotaStanding) -> Date {
        standing.weeklyResetsAt ?? formatter.now.addingTimeInterval(7 * 24 * 3600)
    }

    private func resetDay(_ standing: QuotaStanding) -> Date {
        formatter.resetDay(resetInstant(standing))
    }
}

/// The words for a suggestion. The mapper and the text-fit test build them the same way.
enum RecommendationCopy {
    /// `day` is the suggested account's reset day; nil when that week has not started.
    static func reason(for decision: Recommendation, day: String?, language: L10nLanguage) -> String {
        switch decision {
        case .switchTo(_, let reason):
            let first = day.map { L10nKey.recommendResetsOn.string(in: language, parameters: ["day": $0]) }
                ?? L10nKey.recommendWeekNotStarted.string(in: language)
            let second: String
            switch reason {
            case .noCurrent:
                return first
            case .currentUnknown:
                second = L10nKey.recommendCurrentUnknown.string(in: language)
            case .currentFiveHourLow(let percent):
                second = L10nKey.recommendCurrentFiveHourLow.string(in: language, parameters: ["percent": String(percent)])
            case .currentWeekSpent:
                second = L10nKey.recommendCurrentWeekSpent.string(in: language)
            }
            return L10nKey.recommendJoin.string(in: language, parameters: ["first": first, "second": second])
        case .noneReady:
            return L10nKey.recommendNoneReady.string(in: language)
        }
    }
}
