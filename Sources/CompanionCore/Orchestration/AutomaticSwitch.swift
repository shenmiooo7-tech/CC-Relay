import Foundation

public enum AutoSwitchPauseReason: String, Equatable, Sendable, Codable {
    case noAvailableAccount, otherAccountsOpen, lastSwitchFailed
    /// Accounts with quota left exist, but none allows the conversation's bypass mode.
    case needsBypassAccount
    /// A command runs that closing Claude would end and nothing can hand over. The switch follows
    /// once it ends, without a notice.
    case commandRunning
    /// The work could not be made ready to carry on: its preparation failed.
    case continuationNotReady
    /// A limit again, right after a limit alone sent the work to this account, whose own figures
    /// show quota left: the next account would most likely fare the same.
    case limitRepeated
    /// The service itself stopped this account: on hold, or its organization not allowed. The work
    /// stays here, whatever else says the account is spent.
    case accountRestricted
}

/// A structured limit observation from a runtime whose identity Core verifies independently.
public struct NativeQuotaBlock: Codable, Equatable, Sendable {
    public var reason: String
    public var observedAt: Double
    public var until: Double

    public init(reason: String, observedAt: Double, until: Double) {
        self.reason = reason; self.observedAt = observedAt; self.until = until
    }

    public func isActive(at now: Date) -> Bool {
        ["quota", "rateLimit"].contains(reason) && stands(at: now)
    }

    /// The service itself stopped the account: no reason to leave it, and one to stay.
    public func stopsAccount(at now: Date) -> Bool {
        reason == "accountRestricted" && stands(at: now)
    }

    private func stands(at now: Date) -> Bool {
        let instant = now.timeIntervalSince1970 * 1_000
        return observedAt.isFinite && until.isFinite &&
            observedAt <= instant + 1_000 && instant - observedAt < 8 * 86_400_000 && until > instant
    }
}

/// Automatic decisions use successful, current network readings, never displayed estimates or errors.
enum AutomaticSwitchPolicy {
    /// Only evidence about the target justifies excluding that login, and another one is tried
    /// soon. Source preparation, close, lease and recovery failures must not make healthy
    /// alternatives look unavailable.
    static func excludesTarget(after failure: FailureReason) -> Bool {
        switch failure {
        case .targetMissing, .targetUnreadable, .returnedToPreviousAccount, .couldNotOpenClaude,
             .signedInAccountDiffers, .targetCannotContinue: true
        default: false
        }
    }

    /// Claude was closed and the work stayed behind for a reason that is not the target's: another
    /// try would most likely close Claude for nothing again, so none leaves that login until its
    /// limit ends.
    static func holdsSource(after failure: FailureReason) -> Bool {
        switch failure {
        case .transferFailedReturnedToPreviousAccount, .transferFailedNotReopened: true
        default: false
        }
    }

    /// Whether a limit report came so soon after a switch that a report alone caused that the
    /// account it came from can hardly be the reason.
    static func repeatsLimit(_ block: NativeQuotaBlock, after switched: Date) -> Bool {
        let seconds = block.observedAt / 1_000 - switched.timeIntervalSince1970
        return block.reason == "rateLimit" && seconds >= 0 && seconds < 600
    }

    static func reading(_ value: QuotaReading?, profile: ProfileSnapshot, now: Date) -> QuotaSnapshot? {
        guard let value, value.freshness == .fresh, value.lastError == nil,
              let quota = value.snapshot, quota.source == .network,
              now.timeIntervalSince(quota.fetchedAt) < 120, quota.fetchedAt.timeIntervalSince(now) <= 1,
              profile.identity?.matches(account: quota.accountUUID, organization: quota.organizationUUID) == true
        else { return nil }
        return quota
    }

    static func exhausted(_ quota: QuotaSnapshot?, now: Date) -> Bool {
        guard let quota else { return false }
        return [quota.fiveHour, quota.sevenDay].contains { window in
            guard let used = window.usedPercent, used.isFinite, used >= 100 else { return false }
            return window.resetsAt.map { $0 > now } ?? true
        }
    }

    static func identity(_ profile: ProfileSnapshot) -> String? {
        guard let identity = profile.identity, let org = identity.activeOrganizationUUID else { return nil }
        return identity.accountUUID + ":" + org
    }

    /// Below this a week is nearly out, and ranks after every other account: a long conversation can
    /// use it up within minutes, and Claude closes again for the next one. The panel ranks alike.
    private static let lowWeek = 5

    static func target(profiles: [ProfileSnapshot], source: ProfileSnapshot,
                       readings: [ProfileFolder: QuotaReading], excluded: Set<String>, now: Date,
                       timeZone: TimeZone = .autoupdatingCurrent) -> ProfileSnapshot? {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let candidates = profiles.enumerated().compactMap { index, profile -> (Int, ProfileSnapshot, Int, Date, Date, Bool)? in
            guard profile.folder != source.folder, let login = identity(profile), login != identity(source),
                  !excluded.contains(login), let quota = reading(readings[profile.folder], profile: profile, now: now),
                  let five = remaining(quota.fiveHour, now: now), five >= 10,
                  let week = remaining(quota.sevenDay, now: now), week > 0 else { return nil }
            let reset = quota.sevenDay.resetsAt ?? now.addingTimeInterval(7 * 86_400)
            // Match the panel's reset-day ranking, including a time within one second of midnight.
            let milliseconds = reset.timeIntervalSince1970 * 1_000
            let remainder = milliseconds.truncatingRemainder(dividingBy: 60_000)
            let shown = remainder >= 59_000 ? reset.addingTimeInterval((60_000 - remainder) / 1_000) : reset
            return (index, profile, five, calendar.startOfDay(for: shown), reset, week < lowWeek)
        }
        return candidates.sorted { a, b in
            if a.5 != b.5 { return b.5 }
            if a.3 != b.3 { return a.3 < b.3 }
            if a.2 != b.2 { return a.2 > b.2 }
            if a.4 != b.4 { return a.4 < b.4 }
            return a.0 < b.0
        }.first?.1
    }

    /// When another account may first have become usable, so that none is read again before: the
    /// end of its exclusion, or the reset of what holds it back. Figures only lose quota between
    /// resets, so an older reading still tells. An account whose figures cannot tell counts as ten
    /// minutes away; one without a sign-in waits for the accounts to change.
    static func nextChance(profiles: [ProfileSnapshot], source: ProfileSnapshot, readings: [ProfileFolder: QuotaReading],
                           exclusions: [String: Date], now: Date) -> Date {
        profiles.reduce(Date.distantFuture) { earliest, profile in
            guard profile.folder != source.folder, let login = identity(profile), login != identity(source) else { return earliest }
            if let until = exclusions[login], until > now { return min(earliest, until) }
            return min(earliest, usableFrom(readings[profile.folder], profile: profile, now: now) ?? now.addingTimeInterval(600))
        }
    }

    /// The last reset among the windows that hold an account back; nil when its figures cannot
    /// tell, including when nothing seems to hold it back.
    private static func usableFrom(_ value: QuotaReading?, profile: ProfileSnapshot, now: Date) -> Date? {
        guard let quota = value?.snapshot, quota.source == .network,
              profile.identity?.matches(account: quota.accountUUID, organization: quota.organizationUUID) == true else { return nil }
        var resets: [Date] = []
        for (window, needed) in [(quota.fiveHour, 10), (quota.sevenDay, 1)] {
            guard let left = remaining(window, now: now) else { return nil }
            if left < needed {
                guard let reset = window.resetsAt else { return nil }
                resets.append(reset)
            }
        }
        return resets.max()
    }

    private static func remaining(_ window: QuotaWindow, now: Date) -> Int? {
        guard let used = window.usedPercent, used.isFinite,
              window.resetsAt.map({ $0 > now }) ?? true else { return nil }
        return Int(floor(100 - min(100, max(0, used))))
    }
}
