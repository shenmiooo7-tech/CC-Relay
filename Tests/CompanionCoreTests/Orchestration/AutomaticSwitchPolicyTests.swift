import Foundation
import XCTest
@testable import CompanionCore

final class AutomaticSwitchPolicyTests: XCTestCase {
    func testOnlyTargetFailuresExcludeAnOtherwiseUsableLogin() {
        for failure in [FailureReason.targetMissing, .targetUnreadable, .returnedToPreviousAccount, .couldNotOpenClaude,
                        .signedInAccountDiffers, .targetCannotContinue] {
            XCTAssertTrue(AutomaticSwitchPolicy.excludesTarget(after: failure))
        }
        for failure in [FailureReason.couldNotCloseClaude, .couldNotPrepareContinuation, .operationInFlight,
                        .couldNotReadProcesses, .transferFailedReturnedToPreviousAccount, .transferFailedNotReopened, .cancelled] {
            XCTAssertFalse(AutomaticSwitchPolicy.excludesTarget(after: failure))
        }
    }

    func testOnlyFailuresThatClosedClaudeAndLeftTheWorkBehindHoldTheSource() {
        for failure in [FailureReason.transferFailedReturnedToPreviousAccount, .transferFailedNotReopened] {
            XCTAssertTrue(AutomaticSwitchPolicy.holdsSource(after: failure))
        }
        // Target failures set that target aside and let another one be tried; the rest never closed Claude.
        for failure in [FailureReason.targetMissing, .targetUnreadable, .returnedToPreviousAccount, .couldNotOpenClaude,
                        .targetCannotContinue, .couldNotCloseClaude, .couldNotPrepareContinuation, .operationInFlight,
                        .couldNotReadProcesses, .cancelled] {
            XCTAssertFalse(AutomaticSwitchPolicy.holdsSource(after: failure))
        }
    }

    func testOnlyFreshMatchingNetworkQuotaCanAuthorizeAnAutomaticDecision() async throws {
        let h = try await EngineHarness(); defer { h.scratch.cleanup() }
        let source = try h.profile("Claude"), now = h.clock.now()
        let good = quotaReading(source, now: now, used: 100)
        XCTAssertTrue(AutomaticSwitchPolicy.exhausted(AutomaticSwitchPolicy.reading(good, profile: source, now: now), now: now))
        var cases: [QuotaReading] = []
        var value = good; value.freshness = .stale; cases.append(value)
        value = good; value.freshness = .refreshing; cases.append(value)
        value = good; value.lastError = .httpFailure(429); cases.append(value)
        value = good; value.snapshot?.source = .localHistory; cases.append(value)
        value = good; value.snapshot?.fetchedAt = now.addingTimeInterval(-121); cases.append(value)
        value = good; value.snapshot?.fetchedAt = now.addingTimeInterval(2); cases.append(value)
        value = good; value.snapshot?.accountUUID = "another-login"; cases.append(value)
        value = good; value.snapshot?.organizationUUID = "another-organization"; cases.append(value)
        for invalid in cases { XCTAssertNil(AutomaticSwitchPolicy.reading(invalid, profile: source, now: now)) }
        value = good; value.snapshot?.fiveHour.resetsAt = now
        XCTAssertFalse(AutomaticSwitchPolicy.exhausted(value.snapshot, now: now))
        value = good; value.snapshot?.fiveHour.usedPercent = 99.9
        XCTAssertFalse(AutomaticSwitchPolicy.exhausted(value.snapshot, now: now))
        value.snapshot?.sevenDay.usedPercent = 100
        XCTAssertTrue(AutomaticSwitchPolicy.exhausted(value.snapshot, now: now))
    }

    func testAWeekNearlyOutIsTakenOnlyWhenNoOtherAccountCanBe() async throws {
        let h = try await EngineHarness(); defer { h.scratch.cleanup() }
        let a = try h.profile("Claude"), b = try h.profile("Claude_204"), c = try h.profile("Claude_Kxm8")
        let now = h.clock.now()
        var values = [a.folder: quotaReading(a, now: now, used: 100),
                      b.folder: quotaReading(b, now: now, used: 20, weekResetDays: 1),
                      c.folder: quotaReading(c, now: now, used: 20, weekResetDays: 5)]
        func selected() -> ProfileFolder? {
            AutomaticSwitchPolicy.target(profiles: [a, b, c], source: a, readings: values, excluded: [], now: now)?.folder
        }
        // Less than five percent left gives way, even with the nearest reset; five is enough.
        values[b.folder]?.snapshot?.sevenDay.usedPercent = 95.5
        XCTAssertEqual(selected(), c.folder)
        values[b.folder]?.snapshot?.sevenDay.usedPercent = 95
        XCTAssertEqual(selected(), b.folder)
        // Among others nearly out, or alone, it is still taken, the nearest first as ever.
        values[b.folder]?.snapshot?.sevenDay.usedPercent = 96
        values[c.folder]?.snapshot?.sevenDay.usedPercent = 99
        XCTAssertEqual(selected(), b.folder)
        values[c.folder] = nil
        XCTAssertEqual(selected(), b.folder)
    }

    func testRecommendationRequiresUsableBothWindowsAndSkipsDuplicateOrRejectedLogins() async throws {
        let h = try await EngineHarness(); defer { h.scratch.cleanup() }
        let a = try h.profile("Claude"), b = try h.profile("Claude_204"), c = try h.profile("Claude_Kxm8")
        let now = h.clock.now()
        var values = [a.folder: quotaReading(a, now: now, used: 100),
                      b.folder: quotaReading(b, now: now, used: 20, weekResetDays: 1),
                      c.folder: quotaReading(c, now: now, used: 10, weekResetDays: 2)]
        func selected(_ excluded: Set<String> = []) -> ProfileFolder? {
            AutomaticSwitchPolicy.target(profiles: [a, b, c], source: a, readings: values, excluded: excluded, now: now)?.folder
        }
        XCTAssertEqual(selected(), b.folder)
        XCTAssertEqual(selected([try XCTUnwrap(AutomaticSwitchPolicy.identity(b))]), c.folder)
        values[b.folder]?.snapshot?.fiveHour.usedPercent = 91
        XCTAssertEqual(selected(), c.folder)
        values[c.folder]?.snapshot?.sevenDay.usedPercent = 100
        XCTAssertNil(selected())
        values[b.folder] = quotaReading(b, now: now, used: 20)
        values[b.folder]?.snapshot?.fiveHour.resetsAt = now.addingTimeInterval(-1)
        XCTAssertNil(selected(), "A reset prediction cannot authorize an automatic close")
    }

    func testTheNextChanceIsTheFirstResetOrExclusionEndAmongTheOtherAccounts() async throws {
        let h = try await EngineHarness(); defer { h.scratch.cleanup() }
        let a = try h.profile("Claude"), b = try h.profile("Claude_204"), c = try h.profile("Claude_Kxm8")
        let now = h.clock.now(), earlier = now.addingTimeInterval(-3_300)
        // Read 55 minutes ago: the five-hour windows reset five minutes from now.
        var values = [a.folder: quotaReading(a, now: now, used: 100),
                      b.folder: quotaReading(b, now: earlier, used: 95),
                      c.folder: quotaReading(c, now: earlier, used: 100)]
        func chance(_ exclusions: [String: Date] = [:]) -> Date {
            AutomaticSwitchPolicy.nextChance(profiles: [a, b, c], source: a, readings: values, exclusions: exclusions, now: now)
        }
        XCTAssertEqual(chance(), now.addingTimeInterval(300), "An older reading still tells")
        values[b.folder]?.snapshot?.fiveHour.resetsAt = now.addingTimeInterval(240)
        XCTAssertEqual(chance(), now.addingTimeInterval(240), "The first account to come free decides")
        values[b.folder]?.snapshot?.sevenDay.usedPercent = 100
        values[b.folder]?.snapshot?.sevenDay.resetsAt = now.addingTimeInterval(86_400)
        XCTAssertEqual(chance(), now.addingTimeInterval(300), "Both windows have to reset")
        let login = try XCTUnwrap(AutomaticSwitchPolicy.identity(c))
        XCTAssertEqual(chance([login: now.addingTimeInterval(120)]), now.addingTimeInterval(120))
        XCTAssertEqual(chance([login: now.addingTimeInterval(-1)]), now.addingTimeInterval(300), "An ended exclusion counts no more")
        values[c.folder]?.snapshot?.fiveHour.usedPercent = nil
        XCTAssertEqual(chance(), now.addingTimeInterval(600), "Figures that cannot tell count as ten minutes")
        values[c.folder] = nil
        XCTAssertEqual(chance(), now.addingTimeInterval(600))
        values[c.folder] = quotaReading(c, now: earlier, used: 20)
        XCTAssertEqual(chance(), now.addingTimeInterval(600), "Passed over with quota left: it is read again soon")
        XCTAssertEqual(AutomaticSwitchPolicy.nextChance(profiles: [a], source: a, readings: values, exclusions: [:], now: now),
                       .distantFuture, "With no other account, only a change of accounts helps")
    }

    func testOnlyARateLimitWithinTenMinutesOfTheSwitchRepeatsIt() {
        let switched = Date(timeIntervalSince1970: 1_800_000_000), ms = switched.timeIntervalSince1970 * 1_000
        func repeats(_ reason: String, after seconds: Double) -> Bool {
            AutomaticSwitchPolicy.repeatsLimit(NativeQuotaBlock(reason: reason, observedAt: ms + seconds * 1_000, until: ms + 1_200_000),
                                               after: switched)
        }
        XCTAssertTrue(repeats("rateLimit", after: 0))
        XCTAssertTrue(repeats("rateLimit", after: 599))
        XCTAssertFalse(repeats("rateLimit", after: 600), "Later it is a limit like any other")
        XCTAssertFalse(repeats("rateLimit", after: -1), "From before the switch began")
        XCTAssertFalse(repeats("quota", after: 1), "A spent window is that account's own")
    }

    func testAnAccountTheServiceStoppedIsNoLimitAndEndsWithItsWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000), ms = now.timeIntervalSince1970 * 1_000
        let stopped = NativeQuotaBlock(reason: "accountRestricted", observedAt: ms, until: ms + 600_000)
        XCTAssertTrue(stopped.stopsAccount(at: now))
        XCTAssertFalse(stopped.isActive(at: now), "It is no reason to leave the account")
        XCTAssertFalse(stopped.stopsAccount(at: now.addingTimeInterval(600)))
        XCTAssertFalse(NativeQuotaBlock(reason: "rateLimit", observedAt: ms, until: ms + 600_000).stopsAccount(at: now))
        XCTAssertFalse(NativeQuotaBlock(reason: "accountRestricted", observedAt: ms + 2_000, until: ms + 600_000).stopsAccount(at: now))
    }

    func testRuntimeBlockRequiresKnownReasonCurrentTimeAndUnexpiredWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000), ms = now.timeIntervalSince1970 * 1_000
        XCTAssertTrue(NativeQuotaBlock(reason: "rateLimit", observedAt: ms, until: ms + 600_000).isActive(at: now))
        XCTAssertFalse(NativeQuotaBlock(reason: "network", observedAt: ms, until: ms + 600_000).isActive(at: now))
        XCTAssertFalse(NativeQuotaBlock(reason: "quota", observedAt: ms + 2_000, until: ms + 600_000).isActive(at: now))
        XCTAssertFalse(NativeQuotaBlock(reason: "quota", observedAt: ms - 1_000, until: ms).isActive(at: now))
    }
}

func quotaReading(_ profile: ProfileSnapshot, now: Date, used: Double, weekResetDays: Double = 3) -> QuotaReading {
    QuotaReading(snapshot: QuotaSnapshot(folder: profile.folder, accountUUID: profile.identity!.accountUUID,
        organizationUUID: profile.identity!.activeOrganizationUUID!,
        fiveHour: QuotaWindow(usedPercent: used, resetsAt: now.addingTimeInterval(3600)),
        sevenDay: QuotaWindow(usedPercent: 30, resetsAt: now.addingTimeInterval(weekResetDays * 86_400)),
        fetchedAt: now, source: .network), freshness: .fresh)
}
