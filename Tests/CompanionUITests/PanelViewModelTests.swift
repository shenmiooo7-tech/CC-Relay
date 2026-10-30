import XCTest
import CompanionCore
@testable import CompanionUI

/// Suspends until `advance` moves `now` to the deadline. Core's test clock
/// returns from `sleep` immediately, which would spin the minute ticker.
final class ManualClock: Clock, @unchecked Sendable {
    private struct Waiter {
        var id: UUID
        var deadline: Date
        var resume: (Result<Void, Error>) -> Void
    }

    private let lock = NSLock()
    private var instant: Date
    private var waiters: [Waiter] = []
    private var cancelled: Set<UUID> = []

    init(now: Date) {
        instant = now
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    var waiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        let seconds = Self.seconds(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                switch self.enqueue(id: id, seconds: seconds, resume: { continuation.resume(with: $0) }) {
                case .waiting:
                    break
                case .alreadyCancelled:
                    continuation.resume(throwing: CancellationError())
                case .due:
                    continuation.resume()
                }
            }
        } onCancel: {
            if let resume = self.cancel(id) {
                resume(.failure(CancellationError()))
            }
        }
    }

    func advance(by seconds: TimeInterval) {
        let ready = takeDue(adding: seconds)
        for waiter in ready {
            waiter.resume(.success(()))
        }
    }

    private enum Enqueue {
        case waiting
        case alreadyCancelled
        case due
    }

    private func enqueue(
        id: UUID,
        seconds: TimeInterval,
        resume: @escaping (Result<Void, Error>) -> Void
    ) -> Enqueue {
        lock.lock()
        defer { lock.unlock() }
        if cancelled.remove(id) != nil {
            return .alreadyCancelled
        }
        let deadline = instant.addingTimeInterval(seconds)
        if deadline <= instant {
            return .due
        }
        waiters.append(Waiter(id: id, deadline: deadline, resume: resume))
        return .waiting
    }

    private func cancel(_ id: UUID) -> ((Result<Void, Error>) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            return waiters.remove(at: index).resume
        }
        cancelled.insert(id)
        return nil
    }

    private func takeDue(adding seconds: TimeInterval) -> [Waiter] {
        lock.lock()
        defer { lock.unlock() }
        instant = instant.addingTimeInterval(seconds)
        let due = waiters.filter { $0.deadline <= instant }
        waiters.removeAll { $0.deadline <= instant }
        return due
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

@MainActor
private final class Harness {
    let facade: FakeCompanionFacade
    let clock: ManualClock
    let model: PanelViewModel

    var state: PanelViewState { model.state }

    init(facade: FakeCompanionFacade, clock: ManualClock, model: PanelViewModel) {
        self.facade = facade
        self.clock = clock
        self.model = model
    }

    static func make(
        snapshot: CompanionSnapshot = PanelFixtures.mainSnapshot(),
        preferred: [String] = ["zh-Hans"],
        now: Date = PanelFixtures.now
    ) async -> Harness {
        let facade = FakeCompanionFacade(snapshot: snapshot)
        let clock = ManualClock(now: now)
        let model = PanelViewModel(
            facade: facade,
            clock: clock,
            timeZone: PanelFixtures.timeZone,
            preferredLanguages: preferred
        )
        let harness = Harness(facade: facade, clock: clock, model: model)
        let applied = await model.waitUntilApplied()
        XCTAssertTrue(applied)
        return harness
    }

    func push(_ snapshot: CompanionSnapshot) async {
        let previous = model.revision
        facade.push(snapshot)
        await until(model.revision > previous, "snapshot was not applied")
    }

    func until(_ condition: @autoclosure () -> Bool, _ message: String) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail(message)
    }

    func waitForWaiters(_ count: Int) async {
        await until(clock.waiterCount >= count, "clock waiters stayed at \(clock.waiterCount)")
    }

    /// Confirms the removal asked about, then lets its undo note run out so the removal goes through.
    /// No other note may be showing: the two timers are the note's and the removal's.
    func confirmRemovalAndLetTheUndoLapse(_ confirm: () async -> Void) async {
        let waiting = clock.waiterCount
        await confirm()
        await waitForWaiters(waiting + 2)
        clock.advance(by: 4)
    }
}

@MainActor
final class PanelViewModelTests: XCTestCase {
    /// While the plugin is missing, turning on a feature that needs it asks to install it first. Closing the
    /// question leaves the feature off; a failed install says why and can be tried again; turning off never asks.
    func testTurningOnAFeatureThatNeedsTheMissingPluginAsksToInstallItFirst() async {
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.settings.autoSwitchOnQuota = false
        snapshot.settings.autoCompactOnLowQuota = false
        snapshot.pluginReady = false
        let harness = await Harness.make(snapshot: snapshot)

        await harness.model.setAutoSwitch(true)
        XCTAssertEqual(harness.state.pluginDialog, PluginDialogState(feature: .autoSwitch))
        XCTAssertFalse(harness.state.settings.autoSwitchOnQuota)
        XCTAssertFalse(harness.facade.recordedActions().contains(.setAutoSwitch(true)))
        harness.model.closePluginDialog()
        XCTAssertNil(harness.state.pluginDialog)
        XCTAssertFalse(harness.state.settings.autoSwitchOnQuota)

        await harness.model.setAutoCompact(true)
        XCTAssertEqual(harness.state.pluginDialog, PluginDialogState(feature: .autoCompact))
        harness.facade.enqueueReceipt(.pluginNotInstalled(.claudeCodeMissing))
        await harness.model.installPlugin()
        XCTAssertEqual(harness.state.pluginDialog?.phase, .failed(.claudeCodeMissing))
        XCTAssertFalse(harness.state.settings.autoCompactOnLowQuota)

        harness.facade.enqueueReceipt(.pluginInstalled)
        await harness.model.installPlugin()
        XCTAssertEqual(harness.state.pluginDialog?.phase, .done)
        XCTAssertTrue(harness.state.settings.autoCompactOnLowQuota)
        XCTAssertEqual(Array(harness.facade.recordedActions().suffix(3)), [.installPlugin, .installPlugin, .setAutoCompact(true)])
        harness.model.closePluginDialog()
        XCTAssertNil(harness.state.pluginDialog)

        await harness.model.setAutoCompact(false)
        XCTAssertNil(harness.state.pluginDialog)
        XCTAssertEqual(harness.facade.recordedActions().last, .setAutoCompact(false))
    }

    func testAFeatureRefusedAfterTheInstallIsNotReportedAsOn() async {
        for feature in [PluginDialogState.Feature.autoSwitch, .autoCompact] {
            var snapshot = PanelFixtures.mainSnapshot()
            snapshot.settings.autoSwitchOnQuota = false
            snapshot.settings.autoCompactOnLowQuota = false
            snapshot.pluginReady = false
            let harness = await Harness.make(snapshot: snapshot)
            if feature == .autoSwitch { await harness.model.setAutoSwitch(true) } else { await harness.model.setAutoCompact(true) }
            // The plugin goes in, but a switch has started meanwhile and turning the feature on is refused.
            harness.facade.enqueueReceipt(.pluginInstalled)
            harness.facade.enqueueReceipt(.notPerformed)
            await harness.model.installPlugin()
            XCTAssertEqual(harness.state.pluginDialog?.phase, .installedButOff)
            XCTAssertFalse(harness.state.settings.autoSwitchOnQuota)
            XCTAssertFalse(harness.state.settings.autoCompactOnLowQuota)
            XCTAssertEqual(harness.facade.recordedActions().last, feature == .autoSwitch ? .setAutoSwitch(true) : .setAutoCompact(true))
        }
    }

    func testAReadyOrNotYetCheckedPluginTurnsTheFeatureOnAtOnce() async {
        for ready in [true, nil] as [Bool?] {
            var snapshot = PanelFixtures.mainSnapshot()
            snapshot.settings.autoSwitchOnQuota = false
            snapshot.pluginReady = ready
            let harness = await Harness.make(snapshot: snapshot)
            await harness.model.setAutoSwitch(true)
            XCTAssertNil(harness.state.pluginDialog)
            XCTAssertTrue(harness.state.settings.autoSwitchOnQuota)
            XCTAssertEqual(harness.facade.recordedActions().last, .setAutoSwitch(true))
        }
    }

    /// The plugin updates itself after an app update; only a failed update shows, as one row in Settings
    /// whose retry runs the install again.
    func testOnlyAFailedPluginUpdateShowsARowAndItsRetryInstallsAgain() async {
        let quiet = await Harness.make(snapshot: PanelFixtures.mainSnapshot())
        XCTAssertFalse(quiet.state.settings.pluginUpdateFailed)
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.pluginUpdateFailed = true
        let harness = await Harness.make(snapshot: snapshot)
        XCTAssertTrue(harness.state.settings.pluginUpdateFailed)
        await harness.model.retryPluginUpdate()
        XCTAssertEqual(harness.facade.recordedActions().last, .installPlugin)
        XCTAssertEqual(L10nKey.pluginUpdateFailed.string(in: .zhHans), "插件没能更新")
    }

    func testAutomaticSwitchIsARealPersistedControlAndPauseReasonsAreVisible() async {
        let harness = await Harness.make()
        XCTAssertFalse(harness.state.settings.autoSwitchOnQuota)
        await harness.model.setAutoSwitch(true)
        XCTAssertTrue(harness.state.settings.autoSwitchOnQuota)
        XCTAssertEqual(harness.facade.recordedActions().last, .setAutoSwitch(true))
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.settings.autoSwitchOnQuota = true
        snapshot.banners = [.autoSwitchPaused(.noAvailableAccount)]
        await harness.push(snapshot)
        XCTAssertTrue(harness.state.settings.autoSwitchOnQuota)
        XCTAssertEqual(harness.state.banners.first?.id, "auto-switch:noAvailableAccount")
        XCTAssertTrue(harness.state.banners.first?.text.contains("原任务已保留") == true)
    }

    func testAMissingClaudeIsSaidFirst() async {
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.banners = [.claudeNotFound]
        let zh = await Harness.make(snapshot: snapshot)
        XCTAssertEqual(zh.state.banners.first?.text, "没找到 Claude\n装好 Claude 后重新打开 CC-Relay")
        let en = await Harness.make(snapshot: snapshot, preferred: ["en"])
        XCTAssertEqual(en.state.banners.first?.text, "Claude wasn't found.\nInstall it, then open CC-Relay again.")
    }

    func testAutomaticSwitchingPausesSayWhyAndWhenTheyTryAgain() async {
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.settings.autoSwitchOnQuota = true
        let harness = await Harness.make(snapshot: snapshot)
        let cases: [(Banner, String)] = [
            (.autoSwitchPaused(.noAvailableAccount, retryAt: PanelFixtures.now.addingTimeInterval(2 * 3600 + 40 * 60)),
             "额度已用完，暂时没有可用账号\n原任务已保留，21:10 后自动重试"),
            (.autoSwitchPaused(.noAvailableAccount, retryAt: PanelFixtures.date(2026, 10, 28, 9, 0)),
             "额度已用完，暂时没有可用账号\n原任务已保留，10月28日 09:00 后自动重试"),
            (.autoSwitchPaused(.noAvailableAccount, retryAt: .distantFuture),
             "额度已用完，其他账号都没登录\n原任务已保留，登录后自动重试"),
            (.autoSwitchPaused(.noAvailableAccount), "额度已用完，暂时没有可用账号\n原任务已保留，稍后自动重试"),
            (.autoSwitchPaused(.commandRunning), "有命令正在运行，切换会中断它\n等它结束后再自动切换"),
            (.autoSwitchPaused(.limitRepeated), "刚换过号又遇到限流，先不再换\n额度还有余量，过一会儿回到会话继续"),
            (.autoSwitchPaused(.accountRestricted), "这个账号被暂停或不允许使用\n自动切换已停下，请到 claude.ai 查看"),
            (.autoSwitchPaused(.continuationNotReady, retryAt: PanelFixtures.now.addingTimeInterval(600)),
             "没能准备好接续\n18:40 后再试"),
            (.autoSwitchPaused(.continuationNotReady), "没能准备好接续\n先保留当前账号"),
        ]
        for (banner, text) in cases {
            snapshot.banners = [banner]
            await harness.push(snapshot)
            XCTAssertEqual(harness.state.banners.first?.text, text)
        }
    }

    func testBypassNoticeNamesTheAccountToTurnItOnIn() async {
        for language in [L10nLanguage.zhHans, .en] {
            var snapshot = PanelFixtures.mainSnapshot()
            snapshot.settings.autoSwitchOnQuota = true
            snapshot.banners = [.autoSwitchNeedsBypass(account: profile("Claude"))]
            let harness = await Harness.make(snapshot: snapshot, preferred: [language == .zhHans ? "zh-Hans" : "en"])
            let banner = harness.state.banners.first
            XCTAssertEqual(banner?.id, "auto-switch:needsBypassAccount")
            XCTAssertEqual(banner?.kind, .warning)
            XCTAssertEqual(banner?.text, L10nKey.autoSwitchNeedsBypass.string(in: language, parameters: ["name": "201"]))
            XCTAssertFalse(banner?.text.contains("{name}") ?? true)
            XCTAssertTrue(harness.facade.recordedActions().isEmpty)
        }
    }

    func testAKeptWatchNoticeNamesTheAccountAndListsItsChats() async {
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.banners = [.watchesStayed(account: profile("Claude"), titles: ["Review the page", ""])]
        let harness = await Harness.make(snapshot: snapshot)
        let banner = harness.state.banners.first
        XCTAssertEqual(banner?.id, "watches-stayed:Claude:2")
        XCTAssertEqual(banner?.kind, .neutral)
        XCTAssertEqual(banner?.text, "评论监听留在了 201（2 段会话）\n切回这个账号时自动重新打开")
        XCTAssertEqual(banner?.details, ["Review the page", "未命名会话"])
        XCTAssertEqual(banner?.closeTitle, L10nKey.dismissNotice.string(in: .zhHans))
        XCTAssertTrue(harness.facade.recordedActions().isEmpty)
    }

    func testAnAutomaticPauseStaysDismissedWhileTheChecksRepeat() async {
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.settings.autoSwitchOnQuota = true
        snapshot.banners = [.autoSwitchPaused(.lastSwitchFailed)]
        let harness = await Harness.make(snapshot: snapshot)
        let noticeID = "auto-switch:lastSwitchFailed"
        XCTAssertEqual(harness.state.banners.first?.id, noticeID)
        XCTAssertEqual(harness.state.banners.first?.text, "上次自动切换没能转移会话\n额度恢复前不再自动重试")
        XCTAssertNil(harness.state.switchDialog)

        harness.model.closeNotice(noticeID)
        XCTAssertTrue(harness.state.banners.isEmpty)
        await harness.push(snapshot)
        XCTAssertTrue(harness.state.banners.isEmpty, "The same pause must stay dismissed while automatic checks repeat")
        XCTAssertNil(harness.state.switchDialog)
        XCTAssertTrue(harness.facade.recordedActions().isEmpty)
    }

    func testMainSnapshotMapsHeroTilesPlanAndChannel() async {
        let harness = await Harness.make()
        let state = harness.state
        let hero = try! XCTUnwrap(state.current)
        XCTAssertEqual(hero.id, "Claude_204")
        XCTAssertEqual(hero.name, "204")
        XCTAssertEqual(hero.buddy, BuddyFace(mood: .happy, color: .fair))
        XCTAssertEqual(hero.planLabel, "Max")
        XCTAssertEqual(hero.planTier, .max)
        XCTAssertEqual(hero.channelText, "网页订阅")
        XCTAssertEqual(state.others.map(\.id), ["Claude", "Claude_203", "Claude_208"])

        let anna = try! XCTUnwrap(state.others.first { $0.id == "Claude" })
        XCTAssertEqual(anna.buddy, BuddyFace(mood: .tired, color: .ok))
        XCTAssertEqual(anna.planLabel, "Pro")
        XCTAssertEqual(anna.planTier, .pro)
        XCTAssertEqual(anna.channelText, "App Store 订阅")
        XCTAssertEqual(anna.fiveHour.remainingPercent, 18)
        XCTAssertEqual(anna.fiveHour.level, .mid)

        let kai = try! XCTUnwrap(state.others.first { $0.id == "Claude_203" })
        XCTAssertEqual(kai.buddy, BuddyFace(mood: .happy, color: .mid))
        XCTAssertEqual(kai.planLabel, "Max 5×")
        XCTAssertEqual(kai.planTier, .max)
        XCTAssertEqual(kai.channelText, "网页订阅")
        XCTAssertEqual(kai.fiveHour.remainingPercent, 55)
        XCTAssertEqual(kai.fiveHour.level, .ok)

        let team = try! XCTUnwrap(state.others.first { $0.id == "Claude_208" })
        XCTAssertEqual(team.buddy, BuddyFace(mood: .happy, color: .low))
        XCTAssertEqual(team.planLabel, "Team")
        XCTAssertEqual(team.planTier, .other)
        XCTAssertEqual(team.channelText, "Google Play 订阅")
        XCTAssertNil(team.note)
        XCTAssertEqual(team.fiveHour.remainingPercent, 100)
        XCTAssertEqual(team.fiveHour.resetLine, "未计时")
        XCTAssertEqual(team.weekly.remainingPercent, 9)
        XCTAssertEqual(team.weekly.level, .low)

        let formatter = ResetTimeFormatter(
            timeZone: PanelFixtures.timeZone,
            language: .zhHans,
            now: PanelFixtures.now
        )
        XCTAssertEqual(hero.fiveHour.remainingPercent, 72)
        XCTAssertEqual(hero.fiveHour.level, .ok)
        XCTAssertEqual(hero.fiveHour.fillFraction, 0.72, accuracy: 0.0001)
        XCTAssertEqual(
            hero.fiveHour.resetLine,
            formatter.fiveHourLine(resetAt: PanelFixtures.date(2026, 10, 25, 21, 0))
        )
        XCTAssertEqual(hero.fiveHour.resetLine, "21:00 · 2 小时 30 分后")
        XCTAssertEqual(
            hero.fiveHour.tooltip,
            formatter.tooltip(resetAt: PanelFixtures.date(2026, 10, 25, 21, 0))
        )
        XCTAssertEqual(hero.weekly.remainingPercent, 46)
        XCTAssertEqual(hero.weekly.level, .fair)
        XCTAssertEqual(
            hero.weekly.resetLine,
            formatter.weeklyLine(resetAt: PanelFixtures.date(2026, 10, 29, 21, 0))
        )
        XCTAssertEqual(harness.model.menuBarModel.title, "204")
        XCTAssertEqual(harness.model.menuBarModel.quotaPercent, 72)
        XCTAssertFalse(harness.model.menuBarModel.isSwitching)
        XCTAssertEqual(harness.model.menuBarModel.content.accessibilityLabel, "CC-Relay, 204 · 72%")
        XCTAssertFalse(state.interactionLocked)
        XCTAssertTrue(state.settings.controlsEnabled)
        XCTAssertEqual(state.settings.version, "0.1.0")
        XCTAssertEqual(state.settings.language, .system)
        XCTAssertEqual(state.language, .zhHans)
        XCTAssertNil(state.addDialog)
        XCTAssertTrue(state.canAddAccount)
        XCTAssertFalse(state.hasDialog)
        XCTAssertEqual(hero.quota, .figures)
    }

    func testRegistryOrderKeepsRelativeOrderAroundTheCurrentAccount() async {
        let first = account("Claude", display: "201", email: "anna@example.com")
        let current = account("Claude_204", display: "204", email: "oli@example.com")
        let last = account("Claude_203", display: "203", email: "kai@example.com")
        let harness = await Harness.make(snapshot: snapshot(accounts: [first, current, last], current: "Claude_204"))
        XCTAssertEqual(harness.state.current?.id, "Claude_204")
        XCTAssertEqual(harness.state.others.map(\.id), ["Claude", "Claude_203"])
    }

    func testMissingCurrentFallsBackToTheAppName() async {
        let only = account("Claude", display: "201")
        let harness = await Harness.make(
            snapshot: snapshot(accounts: [only], current: "Claude_missing")
        )
        XCTAssertNil(harness.state.current)
        XCTAssertEqual(harness.state.others.map(\.id), ["Claude"])
        XCTAssertEqual(harness.model.menuBarModel.title, "CC-Relay")
        XCTAssertFalse(harness.model.menuBarModel.isSwitching)

        let empty = await Harness.make(snapshot: CompanionSnapshot.empty(appVersion: "0.1.0"))
        XCTAssertEqual(empty.model.menuBarModel.title, "CC-Relay")
        XCTAssertNil(empty.state.current)
    }

    func testClaudeRunningDoesNotChangeThePanel() async {
        var running = PanelFixtures.mainSnapshot()
        running.claudeRunning = true
        let left = await Harness.make()
        let right = await Harness.make(snapshot: running)
        XCTAssertEqual(left.state, right.state)
        XCTAssertEqual(left.model.menuBarModel.title, right.model.menuBarModel.title)
        XCTAssertEqual(left.model.menuBarModel.isSwitching, right.model.menuBarModel.isSwitching)
    }

    func testThePanelCountsAsOpenFromAppearingUntilItCloses() async {
        // Closed, at launch too, nothing on it moves.
        let harness = await Harness.make()
        XCTAssertFalse(harness.model.panelOpen)
        harness.model.panelAppeared()
        XCTAssertTrue(harness.model.panelOpen)
        harness.model.panelClosed()
        XCTAssertFalse(harness.model.panelOpen)
    }

    func testPlanChannelAndAvatarFallbacks() async {
        let blank = account("Claude", display: "201", email: "  ", plan: "   ", channel: .unknown, seed: "???")
        let letter = account("Claude_203", display: "203", email: " kai@example.com ", plan: " Max ", channel: .googlePlay, seed: "seed-k")
        let harness = await Harness.make(snapshot: snapshot(accounts: [blank, letter], current: "Claude"))
        let hero = try! XCTUnwrap(harness.state.current)
        XCTAssertNil(hero.planLabel)
        XCTAssertNil(hero.planTier)
        XCTAssertNil(hero.channelText)
        let tile = try! XCTUnwrap(harness.state.others.first)
        XCTAssertEqual(tile.planLabel, "Max")
        XCTAssertEqual(tile.planTier, .max)
        XCTAssertEqual(tile.channelText, "Google Play 订阅")
    }

    func testPlanTiersColourPlansByName() {
        XCTAssertEqual(PlanTier(label: "Pro"), .pro)
        XCTAssertEqual(PlanTier(label: "Max"), .max)
        XCTAssertEqual(PlanTier(label: "Max 5×"), .max)
        XCTAssertEqual(PlanTier(label: "Max 20×"), .max20)
        for other in ["Team", "Enterprise", "Free", "Something new"] {
            XCTAssertEqual(PlanTier(label: other), .other, other)
        }
        XCTAssertNil(PlanTier(label: nil))
    }

    func testTheBuddysFaceFollowsTheFiveHourWindowAndItsColourTheWeek() async {
        func face(five: Double?, week: Double?, status: AccountSummary.Status = .signedIn,
                  freshness: QuotaFreshness = .fresh) async -> BuddyFace {
            var row = account("Claude", display: "201", status: status, freshness: freshness)
            row.quota?.fiveHour.usedPercent = five.map { 100 - $0 }
            row.quota?.sevenDay.usedPercent = week.map { 100 - $0 }
            let harness = await Harness.make(snapshot: snapshot(accounts: [row], current: "Claude"))
            return harness.state.current!.buddy
        }
        // Remaining percents, in the bars' four bands: above 50, 30 to 50, 11 to 29, 10 or less.
        let happy = await face(five: 51, week: 51)
        XCTAssertEqual(happy, BuddyFace(mood: .happy, color: .ok))
        let content = await face(five: 50, week: 50)
        XCTAssertEqual(content, BuddyFace(mood: .content, color: .fair))
        let stillContent = await face(five: 30, week: 30)
        XCTAssertEqual(stillContent, BuddyFace(mood: .content, color: .fair))
        let tired = await face(five: 29, week: 29)
        XCTAssertEqual(tired, BuddyFace(mood: .tired, color: .mid))
        let lastTired = await face(five: 11, week: 11)
        XCTAssertEqual(lastTired, BuddyFace(mood: .tired, color: .mid))
        let sleepy = await face(five: 10, week: 10)
        XCTAssertEqual(sleepy, BuddyFace(mood: .sleepy, color: .low))
        let nearlyOut = await face(five: 9, week: 1)
        XCTAssertEqual(nearlyOut, BuddyFace(mood: .sleepy, color: .low))
        // A used-up week sleeps whatever the 5-hour window has left.
        let asleep = await face(five: 100, week: 0)
        XCTAssertEqual(asleep, BuddyFace(mood: .asleep, color: .empty))
        let signedOut = await face(five: 80, week: 80, status: .signedOut)
        XCTAssertEqual(signedOut, .unknown)
        let unreadable = await face(five: 80, week: 80, status: .unreadable)
        XCTAssertEqual(unreadable, .unknown)
        let unavailable = await face(five: 80, week: 80, freshness: .unavailable)
        XCTAssertEqual(unavailable, .unknown)
        // A stale reading still shows its figures, so the buddy follows them.
        let stale = await face(five: 80, week: 80, freshness: .stale)
        XCTAssertEqual(stale, BuddyFace(mood: .happy, color: .ok))
    }

    func testTheCardUnderTheCurrentAccountShowsOnlyOnceTheCurrentOneIsOut() async {
        // The current account, 204, still works: nothing under it, though 208's week resets sooner.
        let main = await Harness.make()
        XCTAssertNil(main.state.recommendation)

        let out = await Harness.make(snapshot: PanelFixtures.recommendSnapshot())
        guard case .card(let suggested) = out.state.recommendation else {
            return XCTFail("no card: \(String(describing: out.state.recommendation))")
        }
        XCTAssertEqual(suggested.card.id, "Claude_208")
        XCTAssertEqual(suggested.reason, "周限额 10月26日 周一 重置，日期最近；当前 5 小时只剩 7%")
        XCTAssertEqual(suggested.card, out.state.others.first { $0.id == "Claude_208" })

        // With 208's week spent too, 203 is suggested, shown like its tile: no card shows an address.
        var spent = PanelFixtures.recommendSnapshot()
        spent.accounts[3].quota?.sevenDay.usedPercent = 100
        let next = await Harness.make(snapshot: spent)
        guard case .card(let kai) = next.state.recommendation else { return XCTFail("no card") }
        XCTAssertEqual(kai.card.id, "Claude_203")
        XCTAssertEqual(kai.card, next.state.others.first { $0.id == "Claude_203" })

        // No account can be used: one line says so. While the current one works, nothing shows.
        let none = await Harness.make(snapshot: PanelFixtures.recommendNoneSnapshot())
        XCTAssertEqual(none.state.recommendation, .note("暂时没有可用的账号，等额度恢复"))
        var working = PanelFixtures.recommendNoneSnapshot()
        working.accounts[0].quota?.fiveHour.usedPercent = 60
        let othersOut = await Harness.make(snapshot: working)
        XCTAssertNil(othersOut.state.recommendation)

        let english = await Harness.make(snapshot: PanelFixtures.recommendSnapshot(), preferred: ["en"])
        guard case .card(let englishCard) = english.state.recommendation else { return XCTFail("no card") }
        XCTAssertEqual(englishCard.reason, "Week resets Mon, Oct 26, soonest · current 5h at 7%")

        let alone = await Harness.make(snapshot: snapshot(accounts: [account("Claude", display: "201")], current: "Claude"))
        XCTAssertNil(alone.state.recommendation)
    }

    func testTheSuggestedCardTellsWhyTheCurrentAccountIsOut() async {
        func reason(_ change: (inout AccountSummary) -> Void) async -> String? {
            var snapshot = PanelFixtures.mainSnapshot()
            change(&snapshot.accounts[0])
            let harness = await Harness.make(snapshot: snapshot)
            guard case .card(let card) = harness.state.recommendation else { return nil }
            return card.reason
        }
        let low = await reason { $0.quota?.fiveHour.usedPercent = 93 }
        XCTAssertEqual(low, "周限额 10月26日 周一 重置，日期最近；当前 5 小时只剩 7%")
        let spent = await reason { $0.quota?.sevenDay.usedPercent = 100 }
        XCTAssertEqual(spent, "周限额 10月26日 周一 重置，日期最近；当前每周额度已用完")
        let unknown = await reason { $0.status = .unreadable }
        XCTAssertEqual(unknown, "周限额 10月26日 周一 重置，日期最近；当前账号额度读不到")
        let missing = await reason { $0.quotaFreshness = .unavailable }
        XCTAssertEqual(missing, "周限额 10月26日 周一 重置，日期最近；当前账号额度读不到")

        var noCurrent = PanelFixtures.mainSnapshot()
        noCurrent.currentFolder = nil
        let harness = await Harness.make(snapshot: noCurrent)
        guard case .card(let card) = harness.state.recommendation else { return XCTFail("no card") }
        XCTAssertEqual(card.card.id, "Claude_208")
        XCTAssertEqual(card.reason, "周限额 10月26日 周一 重置，日期最近")
    }

    func testAWeekWhoseResetHasPassedCountsAsNotStarted() async {
        // 208's week has just reset: it shows 100 % and its next reset is not known yet, so it ranks
        // last, and 203, whose week resets next, is suggested once the current account is out.
        var snapshot = PanelFixtures.recommendSnapshot()
        snapshot.accounts[3].quota?.sevenDay.resetsAt = PanelFixtures.date(2026, 10, 25, 17, 0)
        snapshot.accounts[3].quotaFreshness = .resetPassed
        let harness = await Harness.make(snapshot: snapshot)
        XCTAssertEqual(harness.state.others.first { $0.id == "Claude_208" }?.weekly.remainingPercent, 100)
        guard case .card(let card) = harness.state.recommendation else { return XCTFail("no card") }
        XCTAssertEqual(card.card.id, "Claude_203")
    }

    func testTheSuggestedCardRenamesInADialogAndSkipsAnAccountBeingRemoved() async {
        let harness = await Harness.make(snapshot: PanelFixtures.recommendSnapshot())
        harness.model.beginRename("Claude_208")
        XCTAssertEqual(harness.state.renameDialog, RenameDialogState(id: "Claude_208", name: "208"))
        guard case .card(let card) = harness.state.recommendation else { return XCTFail("no card") }
        XCTAssertEqual(card.card.status, .normal)

        var removing = PanelFixtures.recommendSnapshot()
        removing.operation = .removing(folder: profile("Claude_208"))
        await harness.push(removing)
        guard case .card(let other) = harness.state.recommendation else { return XCTFail("no card") }
        // 203's week resets on 10月31日, the soonest after 208's.
        XCTAssertEqual(other.card.id, "Claude_203")
    }

    func testTheSuggestedCardSkipsAFolderSignedInToTheCurrentLogin() async {
        // 203 holds the current account a second time, kept on purpose: the same login, so the same quota.
        var snapshot = PanelFixtures.mainSnapshot()
        let current = snapshot.accounts[0]
        XCTAssertEqual(snapshot.currentFolder, current.folder)
        var twin = snapshot.accounts[2]
        twin.quota = current.quota.map { reading in
            var copy = reading
            copy.folder = twin.folder
            return copy
        }
        twin.duplicateOf = current.folder
        snapshot.accounts[2] = twin
        // 208's week is spent, and the current account is out of its 5 hours, so a card shows.
        snapshot.accounts[3].quota?.sevenDay.usedPercent = 100
        snapshot.accounts[0].quota?.fiveHour.usedPercent = 93
        let harness = await Harness.make(snapshot: snapshot)
        guard case .card(let card) = harness.state.recommendation else { return XCTFail("no card") }
        XCTAssertEqual(card.card.id, "Claude")

        // The same account in another organization has a quota of its own and stays a candidate.
        twin.quota?.organizationUUID = "org-team"
        snapshot.accounts[2] = twin
        await harness.push(snapshot)
        guard case .card(let other) = harness.state.recommendation else { return XCTFail("no card") }
        XCTAssertEqual(other.card.id, "Claude_203")
    }

    func testAClickOnTheSuggestedCardOfAnAccountBeingRenamedKeepsTheNewName() async {
        let harness = await Harness.make(snapshot: PanelFixtures.recommendSnapshot())
        harness.model.beginRename("Claude_208")
        guard case .card(let card) = harness.state.recommendation else { return XCTFail("no card") }
        XCTAssertEqual(card.card.id, "Claude_208")
        // The suggested card selects as its tile does; a tile being renamed waits for its name.
        await harness.model.select(card.card.id)
        XCTAssertTrue(harness.facade.recordedActions().isEmpty)
        XCTAssertEqual(harness.state.renameDialog?.id, "Claude_208")
        XCTAssertNil(harness.state.switchDialog)
    }

    func testQuotaFailuresExplainOldFiguresAndPreserveDuplicateNotes() async {
        var snapshot = PanelFixtures.duplicateSnapshot()
        snapshot.accounts[0].quotaFreshness = .stale
        snapshot.accounts[0].quotaFailure = .timedOut
        let harness = await Harness.make(snapshot: snapshot)
        XCTAssertEqual(harness.state.current?.quota, .figures)
        XCTAssertEqual(harness.state.current?.note, "请求超时，请刷新 · 上次数据\n与 203 是同一个账号")
        let percent = harness.state.current?.fiveHour.remainingPercent

        snapshot.accounts[0].quotaFailure = .invalidResponse
        await harness.push(snapshot)
        XCTAssertEqual(harness.state.current?.note, "读取失败，请刷新 · 上次数据\n与 203 是同一个账号")
        XCTAssertEqual(harness.state.current?.fiveHour.remainingPercent, percent)

        snapshot.accounts[0].quotaFailure = nil
        await harness.push(snapshot)
        XCTAssertEqual(harness.state.current?.note, "上次数据\n与 203 是同一个账号")
        snapshot.accounts[0].quotaFreshness = .fresh
        await harness.push(snapshot)
        XCTAssertEqual(harness.state.current?.note, "与 203 是同一个账号")

        snapshot.accounts[0].quota = nil
        snapshot.accounts[0].quotaFreshness = .unavailable
        snapshot.accounts[0].quotaFailure = .timedOut
        await harness.push(snapshot)
        XCTAssertEqual(harness.state.current?.quota, .notice("请求超时，请刷新", .warning))
        XCTAssertEqual(harness.state.current?.note, "与 203 是同一个账号")
        snapshot.accounts[0].quotaFailure = .decryptFailed
        await harness.push(snapshot)
        XCTAssertEqual(harness.state.current?.quota, .notice("读取失败，请刷新", .warning))
        let english = await Harness.make(snapshot: snapshot, preferred: ["en"])
        XCTAssertEqual(english.state.current?.quota, .notice("Read failed; refresh quota", .warning))
    }

    func testARefusedOrLimitedReadSaysWhyInsteadOfAskingToSignIn() async {
        var snapshot = PanelFixtures.duplicateSnapshot()
        snapshot.accounts[0].quotaFreshness = .stale
        snapshot.accounts[0].quotaFailure = .refused
        let harness = await Harness.make(snapshot: snapshot)
        XCTAssertEqual(harness.state.current?.quota, .figures)
        XCTAssertEqual(harness.state.current?.note, "claude.ai 拒绝了读取 · 上次数据\n与 203 是同一个账号")

        // The time is the minute the wait is over, never earlier.
        snapshot.accounts[0].quota = nil
        snapshot.accounts[0].quotaFreshness = .unavailable
        snapshot.accounts[0].quotaFailure = .rateLimited(until: PanelFixtures.now.addingTimeInterval(39 * 60 + 30))
        await harness.push(snapshot)
        XCTAssertEqual(harness.state.current?.quota, .notice("请求太多，19:10 后再读", .warning))
        let english = await Harness.make(snapshot: snapshot, preferred: ["en"])
        XCTAssertEqual(english.state.current?.quota, .notice("Rate-limited until 19:10", .warning))
    }

    func testOlderQuotaUpdateTimesIncludeTheirDateAndYearWhenNeeded() async {
        let harness = await Harness.make(snapshot: quotaSnapshot(
            fiveUsed: 20, fiveReset: nil, fetchedAt: PanelFixtures.date(2026, 10, 24, 18, 30), freshness: .stale))
        XCTAssertEqual(harness.state.current?.fiveHour.resetLine, "更新于 10-24 18:30")
        XCTAssertEqual(harness.state.current?.fiveHour.tooltip, "额度信息更新于 10-24 18:30")
        await harness.push(quotaSnapshot(
            fiveUsed: 20, fiveReset: nil, fetchedAt: PanelFixtures.date(2025, 10, 24, 18, 30), freshness: .stale))
        XCTAssertEqual(harness.state.current?.fiveHour.tooltip, "额度信息更新于 2025-10-24 18:30")
        let english = await Harness.make(snapshot: quotaSnapshot(
            fiveUsed: 20, fiveReset: nil, fetchedAt: PanelFixtures.date(2026, 10, 24, 18, 30), freshness: .stale),
            preferred: ["en"])
        XCTAssertEqual(english.state.current?.fiveHour.tooltip, "Quota updated at 10-24 18:30")
    }

    func testQuotaFreshnessPresentation() async {
        let future = PanelFixtures.date(2026, 10, 25, 21, 0)
        let past = PanelFixtures.now.addingTimeInterval(-60)
        let week = PanelFixtures.date(2026, 10, 29, 21, 0)

        let fresh = await Harness.make(snapshot: quotaSnapshot(
            fiveUsed: 80,
            fiveReset: nil,
            weekUsed: 28.9,
            weekReset: future,
            freshness: .fresh
        ))
        XCTAssertEqual(fresh.state.current?.fiveHour.remainingPercent, 20)
        XCTAssertEqual(fresh.state.current?.fiveHour.resetLine, "更新于 18:30")
        XCTAssertEqual(fresh.state.current?.fiveHour.tooltip, "额度信息更新于 18:30")
        XCTAssertEqual(fresh.state.current?.weekly.remainingPercent, 71)
        XCTAssertEqual(fresh.state.current?.weekly.level, .ok)

        await fresh.push(quotaSnapshot(fiveUsed: nil, fiveReset: future, weekUsed: 28, weekReset: week, freshness: .fresh))
        XCTAssertNil(fresh.state.current?.fiveHour.remainingPercent)
        XCTAssertEqual(fresh.state.current?.fiveHour.resetLine.contains("21:00"), true)
        XCTAssertNotEqual(fresh.state.current?.fiveHour.resetLine, "未计时")
        XCTAssertEqual(fresh.state.current?.fiveHour.fillFraction, 0)
        XCTAssertEqual(fresh.state.current?.fiveHour.level, .low)

        let boundaries: [(Double, Int, QuotaLevel)] = [
            (49, 51, .ok),
            (50, 50, .fair),
            (70, 30, .fair),
            (70.1, 29, .mid),
            (89, 11, .mid),
            (89.1, 10, .low),
            (100, 0, .low),
            (150, 0, .low),
            (-5, 100, .ok),
        ]
        for sample in boundaries {
            await fresh.push(quotaSnapshot(fiveUsed: sample.0, fiveReset: future, freshness: .fresh))
            XCTAssertEqual(fresh.state.current?.fiveHour.remainingPercent, sample.1, "used \(sample.0)")
            XCTAssertEqual(fresh.state.current?.fiveHour.level, sample.2, "used \(sample.0)")
        }
        await fresh.push(quotaSnapshot(fiveUsed: 99, fiveReset: future, freshness: .fresh))
        XCTAssertEqual(fresh.state.current?.fiveHour.fillFraction, Double(Metrics.minimumBarFraction))
        await fresh.push(quotaSnapshot(fiveUsed: 0, fiveReset: future, freshness: .fresh))
        XCTAssertEqual(fresh.state.current?.fiveHour.fillFraction, 1)

        let weekFuture = PanelFixtures.date(2026, 10, 29, 21, 0)
        await fresh.push(quotaSnapshot(
            fiveUsed: 28,
            fiveReset: past,
            weekUsed: 54,
            weekReset: weekFuture,
            freshness: .resetPassed
        ))
        XCTAssertEqual(fresh.state.current?.fiveHour.remainingPercent, 100)
        XCTAssertEqual(fresh.state.current?.fiveHour.resetLine, "已重置，正在刷新…")
        XCTAssertEqual(fresh.state.current?.weekly.remainingPercent, 46)
        XCTAssertNotEqual(fresh.state.current?.weekly.resetLine, "已重置，正在刷新…")
        let weeklyFormatter = ResetTimeFormatter(
            timeZone: PanelFixtures.timeZone,
            language: .zhHans,
            now: PanelFixtures.now
        )
        XCTAssertEqual(fresh.state.current?.weekly.resetLine, weeklyFormatter.weeklyLine(resetAt: weekFuture))

        await fresh.push(quotaSnapshot(
            fiveUsed: 28,
            fiveReset: future,
            weekUsed: 54,
            weekReset: past,
            freshness: .resetPassed
        ))
        XCTAssertEqual(fresh.state.current?.fiveHour.remainingPercent, 72)
        XCTAssertEqual(fresh.state.current?.fiveHour.resetLine.contains("21:00"), true)
        XCTAssertEqual(fresh.state.current?.weekly.remainingPercent, 100)
        XCTAssertEqual(fresh.state.current?.weekly.resetLine, "已重置，正在刷新…")

        await fresh.push(quotaSnapshot(fiveUsed: 10, fiveReset: past, freshness: .fresh))
        XCTAssertEqual(fresh.state.current?.fiveHour.remainingPercent, 100)
        XCTAssertEqual(fresh.state.current?.fiveHour.resetLine, "已重置，正在刷新…")

        await fresh.push(quotaSnapshot(fiveUsed: 40, fiveReset: past, weekUsed: 10, weekReset: future, freshness: .stale))
        XCTAssertEqual(fresh.state.current?.fiveHour.remainingPercent, 60)
        XCTAssertEqual(fresh.state.current?.fiveHour.resetLine, "更新于 18:30")
        XCTAssertEqual(fresh.state.current?.fiveHour.tooltip, "额度信息更新于 18:30")
        XCTAssertEqual(fresh.state.current?.weekly.remainingPercent, 90)
        XCTAssertNotEqual(fresh.state.current?.weekly.resetLine, "更新于 18:30")

        await fresh.push(quotaSnapshot(fiveUsed: 40, fiveReset: nil, freshness: .stale, includeQuota: true))
        XCTAssertEqual(fresh.state.current?.fiveHour.remainingPercent, 60)
        XCTAssertEqual(fresh.state.current?.fiveHour.resetLine, "更新于 18:30")
        XCTAssertEqual(fresh.state.current?.fiveHour.tooltip, "额度信息更新于 18:30")
        await fresh.push(quotaSnapshot(fiveUsed: nil, fiveReset: nil, freshness: .fresh))
        XCTAssertEqual(fresh.state.current?.fiveHour.remainingPercent, 100)
        XCTAssertEqual(fresh.state.current?.fiveHour.resetLine, "未计时")
        await fresh.push(quotaSnapshot(fiveUsed: 0, fiveReset: nil, freshness: .fresh))
        XCTAssertEqual(fresh.state.current?.fiveHour.remainingPercent, 100)
        XCTAssertEqual(fresh.state.current?.fiveHour.resetLine, "未计时")

        await fresh.push(quotaSnapshot(freshness: .stale, includeQuota: false))
        XCTAssertNil(fresh.state.current?.fiveHour.remainingPercent)
        XCTAssertEqual(fresh.state.current?.fiveHour.resetLine, "\u{2014}")

        await fresh.push(quotaSnapshot(fiveUsed: 40, fiveReset: future, freshness: .refreshing))
        XCTAssertEqual(fresh.state.current?.fiveHour.remainingPercent, 60)
        XCTAssertEqual(fresh.state.current?.fiveHour.tooltip, "正在刷新…")
        XCTAssertNotEqual(fresh.state.current?.fiveHour.resetLine, "正在刷新…")

        await fresh.push(quotaSnapshot(fiveUsed: 40, fiveReset: nil, freshness: .refreshing))
        XCTAssertEqual(fresh.state.current?.fiveHour.remainingPercent, 60)
        XCTAssertEqual(fresh.state.current?.fiveHour.resetLine, "更新于 18:30")
        XCTAssertEqual(fresh.state.current?.fiveHour.tooltip, "额度信息更新于 18:30")

        await fresh.push(quotaSnapshot(fiveUsed: 40, fiveReset: past, freshness: .refreshing))
        XCTAssertEqual(fresh.state.current?.fiveHour.remainingPercent, 100)
        XCTAssertEqual(fresh.state.current?.fiveHour.resetLine, "已重置，正在刷新…")
        XCTAssertEqual(fresh.state.current?.fiveHour.tooltip, "正在刷新…")

        await fresh.push(quotaSnapshot(freshness: .refreshing, includeQuota: false))
        XCTAssertNil(fresh.state.current?.fiveHour.remainingPercent)
        XCTAssertEqual(fresh.state.current?.fiveHour.resetLine, "正在刷新…")
        // The first reading still on its way: grey placeholders where the bars go.
        XCTAssertEqual(fresh.state.current?.quota, .loading)

        await fresh.push(quotaSnapshot(fiveUsed: 10, fiveReset: future, freshness: .unavailable))
        XCTAssertNil(fresh.state.current?.fiveHour.remainingPercent)
        XCTAssertEqual(fresh.state.current?.fiveHour.resetLine, "\u{2014}")
        XCTAssertEqual(fresh.state.current?.fiveHour.tooltip, "\u{2014}")
        XCTAssertEqual(fresh.state.current?.quota, .notice("暂时无法获取额度", .warning))

        let almost = PanelFixtures.now.addingTimeInterval(0.4)
        await fresh.push(quotaSnapshot(fiveUsed: 10, fiveReset: almost, freshness: .fresh))
        let formatter = ResetTimeFormatter(timeZone: PanelFixtures.timeZone, language: .zhHans, now: PanelFixtures.now)
        XCTAssertEqual(fresh.state.current?.fiveHour.resetLine, formatter.fiveHourLine(resetAt: almost))
        XCTAssertNotEqual(fresh.state.current?.fiveHour.resetLine, "已重置，正在刷新…")
    }

    func testAccountStatusesDuplicateNoteAndAddPhases() async {
        let signedOut = account("Claude", display: "201", status: .signedOut, email: "anna@example.com")
        let awaiting = account("Claude_203", display: "203", status: .awaitingSignIn, email: "kai@example.com")
        let unreadable = account("Claude_208", display: "208", status: .unreadable)
        let current = account("Claude_204", display: "204", email: "oli@example.com", duplicateOf: profile("Claude_203"))
        var rows = [current, signedOut, awaiting, unreadable]
        rows[2].duplicateOf = profile("Claude_204")
        let harness = await Harness.make(snapshot: snapshot(accounts: rows, current: "Claude_204"))
        XCTAssertEqual(harness.state.current?.note, "与 203 是同一个账号")
        XCTAssertFalse(harness.state.hasDialog)
        let out = try! XCTUnwrap(harness.state.others.first { $0.id == "Claude" })
        XCTAssertEqual(out.status, .signedOut)
        XCTAssertEqual(out.quota, .notice("需要重新登录", .failure))
        let waitingCard = try! XCTUnwrap(harness.state.others.first { $0.id == "Claude_203" })
        XCTAssertEqual(waitingCard.status, .awaitingSignIn)
        XCTAssertEqual(waitingCard.quota, .notice("等待登录…", .progress))
        XCTAssertEqual(waitingCard.note, "与 204 是同一个账号")
        let broken = try! XCTUnwrap(harness.state.others.first { $0.id == "Claude_208" })
        XCTAssertEqual(broken.status, .unavailable)
        XCTAssertEqual(broken.quota, .notice("暂时无法获取额度", .warning))

        let phases: [(AddAccountPhase, AddDialogState)] = [
            (.closingClaude, .closingClaude),
            (.waitingForSignIn, .waitingForSignIn),
            (.importingHistory, .importingHistory),
            (.openingClaude, .openingClaude),
        ]
        for phase in phases {
            var pending = snapshot(accounts: rows, current: "Claude_204")
            pending.pendingAdd = PendingAddState(folder: profile("Claude_new"), phase: .waitingForSignIn)
            pending.operation = .addingAccount(phase: phase.0)
            await harness.push(pending)
            XCTAssertEqual(harness.state.addDialog, phase.1)
            XCTAssertTrue(harness.state.hasDialog)
            XCTAssertTrue(harness.state.operationBusy)
            XCTAssertTrue(harness.state.interactionLocked)
        }

        var pendingOnly = snapshot(accounts: rows, current: "Claude_204")
        pendingOnly.pendingAdd = PendingAddState(folder: profile("Claude_new"), phase: .importingHistory)
        await harness.push(pendingOnly)
        XCTAssertEqual(harness.state.addDialog, .importingHistory)
        XCTAssertEqual(L10nKey.importingHistory.string(in: .zhHans), "正在导入历史会话…")
        XCTAssertEqual(L10nKey.importingHistory.string(in: .en), "Importing your\nconversations…")
    }

    func testAcceptedActionWaitingForBackgroundInspectionLocksInteractionUntilItCanStart() async {
        var waiting = PanelFixtures.mainSnapshot()
        waiting.isPreparingOperation = true
        let harness = await Harness.make(snapshot: waiting)
        XCTAssertNil(waiting.operation)
        XCTAssertTrue(harness.state.operationBusy)
        XCTAssertTrue(harness.state.interactionLocked)
        XCTAssertFalse(harness.state.settings.controlsEnabled)
        waiting.isPreparingOperation = false
        await harness.push(waiting)
        XCTAssertFalse(harness.state.operationBusy)
        XCTAssertFalse(harness.state.interactionLocked)
    }

    func testSwitchingAndTheTaskGuardShowInTheSwitchDialog() async {
        var switching = PanelFixtures.mainSnapshot()
        switching.operation = .switching(
            target: profile("Claude"),
            step: .openingClaude,
            completedSteps: [.closingClaude, .syncingSessions]
        )
        let harness = await Harness.make(snapshot: switching)
        let tile = try! XCTUnwrap(harness.state.others.first { $0.id == "Claude" })
        XCTAssertEqual(tile.status, .switching(step: .openingClaude, stepsDone: 2))
        XCTAssertEqual(harness.state.current?.status, .normal)
        XCTAssertEqual(harness.state.switchDialog?.targetName, "201")
        XCTAssertEqual(harness.state.switchDialog?.sourceName, "204")
        XCTAssertEqual(harness.state.switchDialog?.phase, .running(step: .openingClaude, stepsDone: 2))
        XCTAssertEqual(harness.state.switchDialog?.steps.count, Metrics.switchStepCount)
        XCTAssertEqual(harness.model.menuBarModel.title, "正在切换到 201…")
        XCTAssertTrue(harness.model.menuBarModel.isSwitching)
        XCTAssertTrue(harness.state.interactionLocked)
        XCTAssertFalse(harness.state.settings.controlsEnabled)

        let steps: [CompanionCore.SwitchStep] = [.closingClaude, .syncingSessions, .openingClaude, .reopeningConversation]
        let uiSteps: [CompanionUI.SwitchStep] = [.closingClaude, .syncingSessions, .openingClaude, .reopeningConversation]
        for pair in zip(steps, uiSteps) {
            var sample = PanelFixtures.mainSnapshot()
            sample.operation = .switching(target: profile("Claude"), step: pair.0, completedSteps: [])
            await harness.push(sample)
            XCTAssertEqual(
                harness.state.others.first { $0.id == "Claude" }?.status,
                .switching(step: pair.1, stepsDone: 0)
            )
        }

        var waiting = PanelFixtures.mainSnapshot()
        waiting.operation = .waitingForTasks(target: profile("Claude"))
        await harness.push(waiting)
        XCTAssertEqual(harness.model.menuBarModel.title, "正在切换到 201…")
        // Waiting is said in the dialog, not on the card.
        XCTAssertNil(harness.state.others.first { $0.id == "Claude" }?.result)

        var asking = PanelFixtures.mainSnapshot()
        asking.operation = .waitingForTasks(target: profile("Claude"))
        asking.taskGuardPrompt = TaskGuardPrompt(target: profile("Claude"), busyCount: 1, unknown: false, isWaiting: false)
        await harness.push(asking)
        XCTAssertEqual(harness.model.menuBarModel.title, "204")
        XCTAssertEqual(harness.model.menuBarModel.quotaPercent, 72)
        XCTAssertFalse(harness.model.menuBarModel.isSwitching)
        XCTAssertNil(harness.state.others.first { $0.id == "Claude" }?.result)
        XCTAssertEqual(harness.state.switchDialog?.targetName, "201")
        XCTAssertEqual(harness.state.switchDialog?.phase, .taskGuard(title: "1 个 Code 任务正在运行", waiting: false))

        var chosen = asking
        chosen.taskGuardPrompt?.isWaiting = true
        await harness.push(chosen)
        XCTAssertEqual(harness.model.menuBarModel.title, "正在切换到 201…")
        XCTAssertTrue(harness.model.menuBarModel.isSwitching)
        XCTAssertEqual(harness.state.switchDialog?.phase, .taskGuard(title: "1 个 Code 任务正在运行", waiting: true))
        XCTAssertNil(harness.state.others.first { $0.id == "Claude" }?.result)

        var removing = PanelFixtures.mainSnapshot()
        removing.operation = .removing(folder: profile("Claude_203"))
        await harness.push(removing)
        XCTAssertEqual(harness.model.menuBarModel.title, "204")
        XCTAssertFalse(harness.model.menuBarModel.isSwitching)
        XCTAssertEqual(
            harness.state.others.first { $0.id == "Claude_203" }?.result,
            CardResultLine(text: "正在移除…", tone: .progress, canDismiss: false)
        )

        var correcting = PanelFixtures.mainSnapshot()
        correcting.operation = .autoCorrecting
        await harness.push(correcting)
        XCTAssertEqual(harness.model.menuBarModel.title, "正在切回…")
        XCTAssertTrue(harness.model.menuBarModel.isSwitching)
        XCTAssertEqual(
            harness.state.current?.result,
            CardResultLine(text: "正在切回…", tone: .progress, canDismiss: false)
        )

        var correctingAway = CompanionSnapshot.empty(appVersion: "0.1.0")
        correctingAway.operation = .autoCorrecting
        await harness.push(correctingAway)
        XCTAssertEqual(harness.state.hud, HUDState(id: "switching-back", text: "正在切回…", busy: true))
        XCTAssertTrue(harness.state.banners.isEmpty)

        var prompt = PanelFixtures.mainSnapshot()
        prompt.taskGuardPrompt = TaskGuardPrompt(target: profile("Claude"), busyCount: 1, unknown: true, isWaiting: false)
        await harness.push(prompt)
        XCTAssertEqual(harness.state.switchDialog?.phase, .taskGuard(title: "1 个 Code 任务正在运行", waiting: false))

        prompt.taskGuardPrompt = TaskGuardPrompt(target: profile("Claude"), busyCount: 0, unknown: true, isWaiting: true)
        await harness.push(prompt)
        XCTAssertEqual(harness.state.switchDialog?.phase, .taskGuard(title: "无法确认有没有 Code 任务在运行", waiting: true))

        prompt.taskGuardPrompt = TaskGuardPrompt(target: profile("Claude"), busyCount: 0, unknown: false, isWaiting: false)
        await harness.push(prompt)
        XCTAssertEqual(harness.state.switchDialog?.phase, .taskGuard(title: "有 Code 任务正在运行", waiting: false))

        var both = PanelFixtures.mainSnapshot()
        both.taskGuardPrompt = prompt.taskGuardPrompt
        both.pendingAdd = PendingAddState(
            folder: profile("Claude_new"),
            phase: .waitingForSignIn,
            duplicateOf: profile("Claude_204")
        )
        await harness.push(both)
        XCTAssertEqual(harness.state.switchDialog?.phase, .taskGuard(title: "有 Code 任务正在运行", waiting: false))

        harness.model.beginRemove("Claude_203")
        XCTAssertEqual(harness.state.switchDialog?.phase, .taskGuard(title: "有 Code 任务正在运行", waiting: false))
        var duplicateAdd = PanelFixtures.mainSnapshot()
        duplicateAdd.pendingAdd = PendingAddState(
            folder: profile("Claude_new"),
            phase: .waitingForSignIn,
            duplicateOf: profile("Claude_204")
        )
        await harness.push(duplicateAdd)
        XCTAssertNil(harness.state.switchDialog)
        XCTAssertEqual(harness.state.addDialog, .duplicate(name: "204"))
        XCTAssertFalse(harness.state.others.contains { $0.note != nil })
    }

    func testBannersAndResultPlacement() async {
        var bannerSnapshot = PanelFixtures.mainSnapshot()
        bannerSnapshot.banners = [
            .foundAccount(folder: profile("Claude:extra")),
            .autoCorrected(to: profile("Claude")),
            .autoCorrectPaused,
            .historyImportPaused(folder: profile("Claude_203"), issue: .interrupted),
            .historyImportPaused(folder: profile("Claude"), issue: .failed),
            .historyImportPaused(folder: profile("Claude_208"), issue: .unavailable),
            .quotaUnavailable,
        ]
        let harness = await Harness.make(snapshot: bannerSnapshot)
        let banners = harness.state.banners
        XCTAssertEqual(banners.map(\.id), [
            "found:Claude:extra",
            "auto:Claude",
            "auto-paused",
            "history:Claude_203",
            "history:Claude",
            "history:Claude_208",
            "quota",
        ])
        XCTAssertEqual(banners[0].text, "发现账号 Claude:extra")
        XCTAssertEqual(banners[0].actionTitle, "添加")
        XCTAssertEqual(banners[0].secondaryActionTitle, "忽略")
        XCTAssertEqual(banners[1].text, "Claude 打开的是默认账号，已切回 201")
        XCTAssertNil(banners[1].actionTitle)
        XCTAssertEqual(banners[3].text, "导入已中断：203")
        XCTAssertEqual(banners[3].actionTitle, "重试")
        XCTAssertEqual(banners[4].text, "导入失败：201")
        XCTAssertEqual(banners[5].text, "暂时无法导入：208")
        XCTAssertEqual(banners[6].kind, .quotaKeychain)
        XCTAssertEqual(banners[6].text, "需要钥匙串授权才能读取额度")
        XCTAssertEqual(banners[6].actionTitle, "重试")
        XCTAssertEqual(L10nKey.quotaKeychain.string(in: .en), "Keychain access is needed to read quota")
        XCTAssertEqual(L10nKey.refreshQuota.string(in: .en), "Refresh quota")
        XCTAssertEqual(L10nKey.resetRefreshing.string(in: .en), "Reset, refreshing…")
        XCTAssertEqual(L10nKey.notStarted.string(in: .en), "Not started")

        let warnings: [OperationWarning] = [
            .sessionsNotSynced(count: 3),
            .backupFailed,
            .conversationNotReopened,
            .continuityCaptureFailed,
            .activeOrganizationUnknown,
        ]
        var switched = PanelFixtures.mainSnapshot()
        switched.lastResult = outcome(.switched(to: profile("Claude_204"), warnings: [warnings[0]]), at: PanelFixtures.now)
        await harness.push(switched)
        XCTAssertEqual(
            harness.state.current?.result?.text,
            "已切换，但有 3 个会话没能同步"
        )
        XCTAssertEqual(harness.state.current?.result?.tone, .warning)
        XCTAssertEqual(harness.state.current?.result?.canDismiss, true)

        switched.lastResult = outcome(.switched(to: profile("Claude_204"), warnings: warnings), at: PanelFixtures.now)
        await harness.push(switched)
        XCTAssertEqual(
            harness.state.current?.result?.text,
            [
                "已切换，但有 3 个会话没能同步",
                "已切换，但备份没有成功",
                "已切换，但没能自动打开刚才的对话",
                "已切换，但没能记下当前对话",
                "已切换，但组织未能确认",
            ].joined(separator: "\n")
        )
        XCTAssertTrue(harness.state.others.allSatisfy { $0.result == nil })

        var added = PanelFixtures.mainSnapshot()
        added.lastResult = outcome(.added(folder: profile("Claude"), warnings: [.backupFailed, .sessionsNotSynced(count: 2)]), at: PanelFixtures.now)
        await harness.push(added)
        XCTAssertNil(harness.state.others.first { $0.id == "Claude" }?.result)
        XCTAssertEqual(
            harness.state.banners.last?.text,
            "已添加 201 · 备份没有成功 · 有 2 个会话没能同步"
        )
        XCTAssertEqual(harness.state.banners.last?.actionTitle, "知道了")

        var removed = PanelFixtures.mainSnapshot()
        removed.lastResult = outcome(.removed(folder: profile("Claude"), partialCleanup: false), at: PanelFixtures.now)
        await harness.push(removed)
        XCTAssertNil(harness.state.others.first { $0.id == "Claude" }?.result)
        // A clean result away from the current card passes in the middle of the panel by itself.
        XCTAssertEqual(harness.state.hud?.text, "已移除 201")
        XCTAssertEqual(harness.state.hud?.busy, false)
        XCTAssertTrue(harness.state.banners.allSatisfy { !$0.id.hasPrefix("result:") })

        removed.accounts.removeAll { $0.folder.name == "Claude" }
        await harness.push(removed)
        XCTAssertNil(harness.state.others.first { $0.id == "Claude" })
        // A clean result away from the current card passes in the middle of the panel by itself.
        XCTAssertEqual(harness.state.hud?.text, "已移除 201")
        XCTAssertEqual(harness.state.hud?.busy, false)
        XCTAssertTrue(harness.state.banners.allSatisfy { !$0.id.hasPrefix("result:") })

        removed.lastResult = outcome(.removed(folder: profile("Claude"), partialCleanup: true), at: PanelFixtures.now)
        await harness.push(removed)
        XCTAssertEqual(harness.state.banners.last?.text, "已移除 201，清理未完成")
        XCTAssertEqual(harness.state.banners.last?.actionTitle, "知道了")
        XCTAssertEqual(harness.state.banners.last?.kind, .warning)

        let reasons: [(FailureReason, String)] = [
            (.couldNotCloseClaude, "没能关闭 Claude"),
            (.couldNotOpenClaude, "没能打开 Claude"),
            (.couldNotReadProcesses, "无法读取进程"),
            (.targetMissing, "账号不存在"),
            (.targetUnreadable, "账号无法读取"),
            (.operationInFlight, "已有操作在进行"),
            (.refusedActiveAccount, "不能移除当前账号"),
            (.refusedLastAccount, "至少留一个账号"),
            (.refusedWhileRunning, "Claude 正在使用它"),
            (.runningStateUnknown, "无法确认是否在运行"),
            (.signedInAccountDiffers, "登录的账号不同"),
        ]
        // A failed switch stays in its dialog until put away, with the step it stopped at when known.
        for reason in reasons {
            var failed = PanelFixtures.mainSnapshot()
            failed.lastResult = outcome(
                .failed(operation: .switchTo(profile("Claude")), reason: reason.0),
                at: PanelFixtures.now
            )
            await harness.push(failed)
            XCTAssertNil(harness.state.others.first { $0.id == "Claude" }?.result)
            XCTAssertNil(harness.state.current?.result)
            XCTAssertTrue(harness.state.banners.allSatisfy { !$0.id.hasPrefix("result:") })
            let step: Int? = switch reason.0 {
            case .couldNotCloseClaude: 0
            case .couldNotOpenClaude: 2
            default: nil
            }
            XCTAssertEqual(harness.state.switchDialog?.targetName, "201")
            XCTAssertEqual(harness.state.switchDialog?.phase, .failed(failedStep: step, message: reason.1))
        }

        var cancelled = PanelFixtures.mainSnapshot()
        cancelled.lastResult = outcome(
            .failed(operation: .switchTo(profile("Claude")), reason: .cancelled),
            at: PanelFixtures.now
        )
        await harness.push(cancelled)
        XCTAssertNil(harness.state.others.first { $0.id == "Claude" }?.result)
        XCTAssertEqual(harness.state.hud?.text, "已取消")
        XCTAssertTrue(harness.state.banners.allSatisfy { !$0.id.hasPrefix("result:") })

        var addFailed = PanelFixtures.mainSnapshot()
        addFailed.lastResult = outcome(.failed(operation: .addAccount, reason: .targetMissing), at: PanelFixtures.now)
        await harness.push(addFailed)
        XCTAssertEqual(harness.state.addDialog, .failed(message: "账号不存在"))
        XCTAssertTrue(harness.state.banners.allSatisfy { !$0.id.hasPrefix("result:") })
        XCTAssertNil(harness.state.current?.result)

        var correctFailed = PanelFixtures.mainSnapshot()
        correctFailed.lastResult = outcome(.failed(operation: .autoCorrect, reason: .couldNotOpenClaude), at: PanelFixtures.now)
        await harness.push(correctFailed)
        XCTAssertEqual(harness.state.current?.result?.text, "自动切回失败：没能打开 Claude")

        var historyFailed = PanelFixtures.mainSnapshot()
        historyFailed.lastResult = outcome(
            .failed(operation: .historyImport(profile("Claude_208")), reason: .targetUnreadable),
            at: PanelFixtures.now
        )
        await harness.push(historyFailed)
        XCTAssertNil(harness.state.others.first { $0.id == "Claude_208" }?.result)
        XCTAssertEqual(harness.state.banners.last?.text, "导入失败：账号无法读取")
        XCTAssertEqual(harness.state.banners.last?.actionTitle, "知道了")

        var hidden = PanelFixtures.mainSnapshot()
        hidden.operation = .switching(target: profile("Claude"), step: .closingClaude, completedSteps: [])
        hidden.lastResult = outcome(.switched(to: profile("Claude_204"), warnings: []), at: PanelFixtures.now)
        await harness.push(hidden)
        XCTAssertNil(harness.state.current?.result)
        XCTAssertTrue(harness.state.banners.allSatisfy { !$0.id.hasPrefix("result:") })
    }

    func testSettingsLanguageAndVersion() async {
        var settings = Settings(autoSyncOnSwitch: false, autoCompactOnLowQuota: false,
                                launchAtLogin: false, language: .en, appearance: .dark)
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.settings = settings
        snapshot.appVersion = "9.9.9"
        let english = await Harness.make(snapshot: snapshot, preferred: ["zh-Hans"])
        XCTAssertEqual(english.state.language, .en)
        XCTAssertEqual(english.state.settings.language, .en)
        XCTAssertEqual(english.state.settings.version, "9.9.9")
        XCTAssertFalse(english.state.settings.launchAtLogin)
        XCTAssertFalse(english.state.settings.autoSyncOnSwitch)
        XCTAssertFalse(english.state.settings.autoCompactOnLowQuota)
        XCTAssertEqual(english.state.settings.appearance, .dark)
        // Compaction off says so under its switch, in grey.
        XCTAssertEqual(english.state.settings.autoCompactStatus, "Off, nothing is compacted")
        XCTAssertEqual(english.state.settings.autoCompactTone, .off)
        XCTAssertEqual(english.state.current?.channelText, "Web subscription")
        XCTAssertEqual(english.model.menuBarModel.language, .en)

        settings.language = .system
        snapshot.settings = settings
        let systemChinese = await Harness.make(snapshot: snapshot, preferred: ["zh-Hans"])
        XCTAssertEqual(systemChinese.state.language, .zhHans)
        XCTAssertEqual(systemChinese.state.settings.language, .system)
        XCTAssertEqual(systemChinese.state.current?.channelText, "网页订阅")

        let systemEnglish = await Harness.make(snapshot: snapshot, preferred: ["en-US"])
        XCTAssertEqual(systemEnglish.state.language, .en)
        XCTAssertEqual(systemEnglish.state.settings.language, .system)

        let harness = await Harness.make()
        await harness.model.setLanguage(.en)
        XCTAssertEqual(harness.state.language, .en)
        XCTAssertEqual(harness.state.settings.language, .en)
        XCTAssertEqual(harness.model.settingsModel.language, .en)
        XCTAssertEqual(harness.facade.recordedActions(), [.setLanguage(.en)])
        XCTAssertEqual(harness.state.current?.channelText, "Web subscription")

        await harness.model.setLanguage(.system)
        XCTAssertEqual(harness.state.language, .zhHans)
        XCTAssertEqual(harness.state.settings.language, .system)

        var forced = PanelFixtures.mainSnapshot()
        forced.settings.language = .zhHans
        await harness.push(forced)
        XCTAssertEqual(harness.state.language, .zhHans)
        XCTAssertEqual(harness.state.settings.language, .zhHans)

        await harness.model.setLaunchAtLogin(false)
        XCTAssertFalse(harness.state.settings.launchAtLogin)
        await harness.model.setAutoSync(false)
        await harness.model.setAutoCompact(false)
        await harness.model.setAppearance(.light)
        XCTAssertFalse(harness.state.settings.autoSyncOnSwitch)
        XCTAssertFalse(harness.state.settings.autoCompactOnLowQuota)
        XCTAssertEqual(harness.state.settings.appearance, .light)
        XCTAssertEqual(harness.facade.recordedActions().last, .setAppearance(.light))
        var echoed = forced
        echoed.settings.launchAtLogin = true
        await harness.push(echoed)
        XCTAssertTrue(harness.state.settings.launchAtLogin)

        harness.model.openSettings()
        XCTAssertTrue(harness.state.isSettingsOpen)
        harness.model.closeSettings()
        XCTAssertFalse(harness.state.isSettingsOpen)
    }

    func testRefreshAllTurnsAtLeastAWhileThenPopsAndConfirms() async {
        let harness = await Harness.make()
        harness.facade.enqueueReceipt(.quotaRefresh(updated: 4, requested: 4))
        XCTAssertEqual(harness.state.header.refresh, .idle)
        XCTAssertTrue(harness.state.header.canRefresh)
        // The countdown's own wait is already on the clock.
        let base = harness.clock.waiterCount
        let actions = harness.model.makeActions()
        actions.refreshAllQuotas()
        await harness.until(harness.facade.recordedActions() == [.refreshQuota(folder: nil)], "read")
        XCTAssertEqual(harness.state.header.refresh, .refreshing)
        // A second press while it runs reads nothing more.
        await harness.model.refreshAllQuotas()
        XCTAssertEqual(harness.facade.recordedActions(), [.refreshQuota(folder: nil)])
        // The read came back at once; the arrow still turns for its least time.
        await harness.waitForWaiters(base + 1)
        harness.clock.advance(by: 0.69)
        XCTAssertEqual(harness.state.header.refresh, .refreshing)
        harness.clock.advance(by: 0.01)
        await harness.until(harness.state.header.refresh == .updated, "updated")
        XCTAssertEqual(harness.state.hud?.text, "额度已更新")
        // The pop's wait and the confirmation's.
        await harness.waitForWaiters(base + 2)
        harness.clock.advance(by: 0.6)
        await harness.until(harness.state.header.refresh == .idle, "idle")
        XCTAssertNotNil(harness.state.hud)
        harness.clock.advance(by: 1.3)
        await harness.until(harness.state.hud == nil, "confirmation faded")

        // While a switch runs, the button is greyed and does nothing.
        var switching = PanelFixtures.mainSnapshot()
        switching.operation = .switching(target: profile("Claude"), step: .closingClaude, completedSteps: [])
        await harness.push(switching)
        XCTAssertFalse(harness.state.header.canRefresh)
        await harness.model.refreshAllQuotas()
        XCTAssertEqual(harness.facade.recordedActions(), [.refreshQuota(folder: nil)])
    }

    func testRefreshReceiptDistinguishesPartialFailureAndNoAccountsWithoutSnapshotChanges() async {
        let cases: [(CompanionActionReceipt, String, QuotaRefreshPhase)] = [
            (.quotaRefresh(updated: 1, requested: 4), "已更新 1/4 个账号额度", .updated),
            (.quotaRefresh(updated: 0, requested: 4), "额度未更新，请重试", .idle),
            (.quotaRefresh(updated: 0, requested: 0), "没有可刷新的账号", .idle),
            (.notPerformed, "额度未更新，请重试", .idle),
            (.unreported, "额度未更新，请重试", .idle),
        ]
        for (receipt, message, phase) in cases {
            // The snapshot still contains the old figures throughout; only this call's receipt
            // can establish whether a refresh actually succeeded.
            let harness = await Harness.make()
            await harness.waitForWaiters(1)
            harness.facade.enqueueReceipt(receipt)
            let baseline = harness.clock.waiterCount
            let work = Task { await harness.model.refreshAllQuotas() }
            await harness.waitForWaiters(baseline + 1)
            harness.clock.advance(by: 0.7)
            await harness.until(harness.state.hud?.text == message, "wrong refresh result for \(receipt)")
            XCTAssertEqual(harness.state.header.refresh, phase)
            if phase == .updated {
                await harness.waitForWaiters(baseline + 2)
                harness.clock.advance(by: 0.6)
            }
            await work.value
            XCTAssertEqual(harness.facade.recordedActions(), [.refreshQuota(folder: nil)])
        }
    }

    func testBackupsConfirmationRequiresTheRevealReceipt() async {
        let harness = await Harness.make()
        let cases: [(CompanionActionReceipt, String)] = [
            (.failed, "未能打开备份文件夹"),
            (.notPerformed, "未能打开备份文件夹"),
            (.unreported, "未能打开备份文件夹"),
            (.backupsOpened, "已在访达中打开备份文件夹"),
        ]
        for (receipt, expected) in cases {
            harness.facade.enqueueReceipt(receipt)
            await harness.model.openBackups()
            XCTAssertEqual(harness.state.hud?.text, expected)
        }
        XCTAssertEqual(harness.facade.recordedActions(), Array(repeating: .openBackupsFolder, count: 4))
    }

    func testNoticesWaitInADialogOneAtATimeAndCanBePutAway() async {
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.banners = [.autoCorrected(to: profile("Claude_204")), .foundAccount(folder: profile("Claude_9"))]
        let harness = await Harness.make(snapshot: snapshot)
        XCTAssertEqual(harness.state.banners.map(\.id), ["auto:Claude_204", "found:Claude_9"])
        XCTAssertEqual(harness.state.shownNotice?.id, "auto:Claude_204")
        XCTAssertEqual(harness.state.banners[0].closeTitle, "知道了")
        // Its own "ignore" puts the found account away.
        XCTAssertNil(harness.state.banners[1].closeTitle)
        harness.model.makeActions().closeNotice("auto:Claude_204")
        XCTAssertEqual(harness.state.banners.map(\.id), ["found:Claude_9"])
        XCTAssertTrue(harness.facade.recordedActions().isEmpty)
        // While the notice lasts it stays away.
        await harness.push(snapshot)
        XCTAssertEqual(harness.state.banners.map(\.id), ["found:Claude_9"])
        // Once it goes and comes again, it shows again.
        var gone = snapshot
        gone.banners = [.foundAccount(folder: profile("Claude_9"))]
        await harness.push(gone)
        await harness.push(snapshot)
        XCTAssertEqual(harness.state.banners.map(\.id), ["auto:Claude_204", "found:Claude_9"])

        // While a switch runs, or another dialog is up, the notice waits.
        var switching = snapshot
        switching.operation = .switching(target: profile("Claude"), step: .closingClaude, completedSteps: [])
        await harness.push(switching)
        XCTAssertNil(harness.state.shownNotice)
        await harness.push(snapshot)
        harness.model.beginRemove("Claude_203")
        XCTAssertNotNil(harness.state.removeDialog)
        XCTAssertNil(harness.state.shownNotice)
    }

    func testVersionCopiesThroughTheGivenPasteboardAndConfirms() async {
        let facade = FakeCompanionFacade(snapshot: PanelFixtures.mainSnapshot())
        let clock = ManualClock(now: PanelFixtures.now)
        var copied: [String] = []
        let model = PanelViewModel(facade: facade, clock: clock, timeZone: PanelFixtures.timeZone,
                                   preferredLanguages: ["zh-Hans"], copyText: { copied.append($0) })
        let applied = await model.waitUntilApplied()
        XCTAssertTrue(applied)
        model.copyVersion()
        XCTAssertEqual(copied, [PanelFixtures.mainSnapshot().appVersion])
        XCTAssertEqual(model.state.hud?.text, "已复制版本号")
        let first = try! XCTUnwrap(model.state.hud?.id)
        // The same confirmation again is a new one, so it shows afresh.
        model.copyVersion()
        XCTAssertNotEqual(model.state.hud?.id, first)

        facade.enqueueReceipt(.backupsOpened)
        await model.openBackups()
        XCTAssertEqual(facade.recordedActions(), [.openBackupsFolder])
        XCTAssertEqual(model.state.hud?.text, "已在访达中打开备份文件夹")
    }

    private func recovery(_ body: (inout NativeRecoverySummary) -> Void) -> NativeRecoverySummary {
        var summary = NativeRecoverySummary(operationID: "op-1")
        summary.from = profile("Claude_203"); summary.to = profile("Claude_204")
        body(&summary)
        return summary
    }

    func testTheContinuationNoticeHasThreeStatesAndComesBackWithTheNextOne() async {
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.banners = [.nativeRecovery(recovery { $0.waiting = 1 })]
        let harness = await Harness.make(snapshot: snapshot)
        let first = harness.state.banners.first?.id
        XCTAssertEqual(harness.state.banners.first?.text, "正在接续\n从 203 换到 204")
        XCTAssertEqual(harness.state.banners.first?.kind, .inProgress)
        XCTAssertNil(harness.state.banners.first?.actionTitle)
        harness.model.makeActions().closeNotice(first ?? "")
        XCTAssertTrue(harness.state.banners.isEmpty)
        // A problem while the conversations may still be reporting is still continuing: no new notice.
        snapshot.banners = [.nativeRecovery(recovery {
            $0.attention = 1; $0.settling = true
            $0.issues = [NativeRecoveryIssue(sessionID: "s", reason: .runtimeUnavailable)]
        })]
        await harness.push(snapshot)
        XCTAssertTrue(harness.state.banners.isEmpty, "the same state stays put away")
        snapshot.banners = [.nativeRecovery(recovery {
            $0.attention = 1
            $0.issues = [NativeRecoveryIssue(sessionID: "s", reason: .runtimeUnavailable)]
        })]
        await harness.push(snapshot)
        XCTAssertEqual(harness.state.banners.first?.text, "接续受阻\n会话在新账号上没有报到，请打开原会话看看")
        XCTAssertEqual(harness.state.banners.first?.kind, .warning)
        XCTAssertEqual(harness.state.banners.first?.actionTitle, "查看本地记录")
        XCTAssertNotEqual(harness.state.banners.first?.id, first)
        snapshot.banners = [.nativeRecovery(recovery { $0.ended = 1; $0.inspected = 1; $0.finished = true })]
        await harness.push(snapshot)
        XCTAssertEqual(harness.state.banners.first?.text, "接续成功\n从 203 换到 204")
        XCTAssertEqual(harness.state.banners.first?.kind, .neutral)
        let english = await Harness.make(snapshot: snapshot, preferred: ["en"])
        XCTAssertEqual(english.state.banners.first?.text, "Work continued\nFrom 203 to 204")
    }

    func testTheRouteNamesOnlyTheNewAccountWhenBothNamesDoNotFit() async {
        let long = "甲乙丙丁戊己庚辛壬癸甲乙丙丁戊己庚辛壬癸"
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.accounts = snapshot.accounts.map { row in
            var row = row; row.displayName = long + row.folder.name.suffix(1); return row
        }
        snapshot.banners = [.nativeRecovery(recovery { $0.ended = 1 })]
        let harness = await Harness.make(snapshot: snapshot)
        XCTAssertEqual(harness.state.banners.first?.text, "接续成功\n已切换到 \(long)4")
        // A return after a failed transfer names no route.
        snapshot.banners = [.nativeRecovery(recovery { $0.ended = 1; $0.from = nil })]
        await harness.push(snapshot)
        XCTAssertEqual(harness.state.banners.first?.text, "接续成功")
    }

    func testCommandsEndedWithTheSwitchAreToldWithoutAWarning() async {
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.banners = [.nativeRecovery(recovery { $0.endedWithSwitch = 2 })]
        let harness = await Harness.make(snapshot: snapshot)
        XCTAssertEqual(harness.state.banners.first?.text, "切换时结束了 2 个后台命令")
        XCTAssertEqual(harness.state.banners.first?.kind, .neutral)
        XCTAssertEqual(harness.state.banners.first?.details, [])
        snapshot.banners = [.nativeRecovery(recovery { $0.endedWithSwitch = 2; $0.ended = 1 })]
        await harness.push(snapshot)
        XCTAssertEqual(harness.state.banners.first?.text, "接续成功\n从 203 换到 204")
        XCTAssertEqual(harness.state.banners.first?.details, ["切换时结束了 2 个后台命令"])
    }

    func testABlockedNoticeGivesOneReasonLineInBothLanguages() async {
        let reasons: [(NativeRecoveryIssue.Reason, L10nKey)] = [
            (.missingRecord, .nativeRecoveryMissingRecord),
            (.incompatibleRuntime, .nativeRecoveryIncompatibleRuntime),
            (.blocked, .nativeRecoveryBlocked),
            (.runtimeUnavailable, .nativeRecoveryRuntimeUnavailable),
            (.expired, .nativeRecoveryExpired),
            (.conversationUnavailable, .nativeRecoveryConversationUnavailable),
            (.executionFailed, .nativeRecoveryExecutionFailed),
            (.recoveryIncomplete, .nativeRecoveryIncomplete),
        ]
        for language in L10nLanguage.allCases {
            let preferred = [language == .zhHans ? "zh-Hans" : "en"]
            let blocked = L10nKey.nativeRecoveryStateBlocked.string(in: language)
            for (reason, key) in reasons {
                var summary = NativeRecoverySummary(operationID: "op-\(reason.rawValue)")
                // Two conversations held up for the same reason still read as that reason.
                summary.attention = 2
                summary.issues = ["session-1", "session-2"].map { NativeRecoveryIssue(sessionID: $0, reason: reason) }
                var snapshot = PanelFixtures.mainSnapshot()
                snapshot.banners = [.nativeRecovery(summary)]
                let notice = await Harness.make(snapshot: snapshot, preferred: preferred).state.shownNotice
                XCTAssertEqual(notice?.text, blocked + "\n" + key.string(in: language))
                XCTAssertEqual(notice?.details, [])
                XCTAssertEqual(notice?.actionTitle, L10nKey.openRecoveryRecords.string(in: language))
            }
            var mixed = NativeRecoverySummary(operationID: "op-mixed")
            mixed.attention = reasons.count
            mixed.issues = reasons.enumerated().map { NativeRecoveryIssue(sessionID: "session-\($0.offset)", reason: $0.element.0) }
            var snapshot = PanelFixtures.mainSnapshot()
            snapshot.banners = [.nativeRecovery(mixed)]
            let notice = await Harness.make(snapshot: snapshot, preferred: preferred).state.shownNotice
            XCTAssertEqual(notice?.text, blocked + "\n" +
                L10nKey.nativeRecoveryReasonsVary.string(in: language, parameters: ["n": String(reasons.count)]))
            // Without the list of reasons the count still comes from the conversations held up.
            var unlisted = NativeRecoverySummary(operationID: "op-unlisted")
            unlisted.attention = 2
            snapshot.banners = [.nativeRecovery(unlisted)]
            let unlistedNotice = await Harness.make(snapshot: snapshot, preferred: preferred).state.shownNotice
            XCTAssertEqual(unlistedNotice?.text, blocked + "\n" +
                L10nKey.nativeRecoveryReasonsVary.string(in: language, parameters: ["n": "2"]))
        }
    }

    func testChangedRecoveryReasonReopensNoticeAndFolderFeedbackRequiresItsReceipt() async {
        var summary = NativeRecoverySummary(operationID: "op-details")
        summary.attention = 1
        summary.issues = [NativeRecoveryIssue(sessionID: "session-1", reason: .runtimeUnavailable)]
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.banners = [.nativeRecovery(summary)]
        let harness = await Harness.make(snapshot: snapshot)
        let firstID = harness.state.shownNotice?.id ?? ""
        harness.model.closeNotice(firstID)
        XCTAssertNil(harness.state.shownNotice)
        summary.issues = [NativeRecoveryIssue(sessionID: "session-1", reason: .recoveryIncomplete)]
        snapshot.banners = [.nativeRecovery(summary)]
        await harness.push(snapshot)
        let nextID = harness.state.shownNotice?.id ?? ""
        XCTAssertNotEqual(nextID, firstID)
        XCTAssertEqual(harness.state.shownNotice?.text, "接续受阻\n接续没有完成，请打开原会话核对")

        let receipts: [(CompanionActionReceipt, String)] = [
            (.failed, "未能打开接续记录"),
            (.notPerformed, "未能打开接续记录"),
            (.unreported, "未能打开接续记录"),
            (.backupsOpened, "未能打开接续记录"),
            (.recoveryFolderOpened, "已在访达中打开接续记录"),
        ]
        for (receipt, expected) in receipts {
            harness.facade.enqueueReceipt(receipt)
            await harness.model.activateBanner(nextID)
            // HUDs are hidden behind dialogs, so the existing dialog must show this feedback too.
            XCTAssertEqual(harness.state.shownNotice?.actionFeedback, expected)
            XCTAssertEqual(harness.state.shownNotice?.id, nextID)
        }
        XCTAssertEqual(harness.facade.recordedActions(), Array(repeating: .openRecoveryFolder, count: receipts.count))
    }

    func testTransferFailureSaysTheOriginalAccountReturnedWithoutClaimingWorkResumed() async {
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.lastResult = outcome(.failed(operation: .switchTo(profile("Claude")),
            reason: .transferFailedReturnedToPreviousAccount), at: PanelFixtures.now)
        let chinese = await Harness.make(snapshot: snapshot)
        XCTAssertEqual(chinese.state.switchDialog?.phase, .failed(failedStep: 1,
            message: "会话转移失败，已回到原账号\n请打开原会话确认任务状态"))
        let english = await Harness.make(snapshot: snapshot, preferred: ["en"])
        XCTAssertEqual(english.state.switchDialog?.phase, .failed(failedStep: 1,
            message: "Chat transfer failed.\nBack on the original account.\nCheck the work in the original chat."))
    }

    func testCompactionNoticesAndThePluginStatusLine() async {
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.settings.autoCompactOnLowQuota = true
        func result(_ trigger: AutoCompactResult.Trigger, _ outcome: AutoCompactResult.Outcome, after: Int?, resumed: Bool = false)
            -> AutoCompactResult {
            AutoCompactResult(trigger: trigger, outcome: outcome, tokensBefore: 812_000, tokensAfter: after,
                              finishedAt: PanelFixtures.now, resumed: resumed)
        }
        snapshot.banners = [.autoCompacted(result(.early, .compacted, after: 74_000))]
        snapshot.autoCompact.status = AutoCompactStatus(lastReport: PanelFixtures.now, liveConversations: 1)
        let harness = await Harness.make(snapshot: snapshot)
        XCTAssertEqual(harness.state.banners.first?.text, "已在额度用完前压缩对话：约 81 万 → 7 万")
        XCTAssertEqual(harness.state.settings.autoCompactStatus, "压缩插件已连接")
        XCTAssertEqual(harness.state.settings.autoCompactTone, .live)

        snapshot.banners = [.autoCompacted(result(.early, .compacted, after: nil))]
        snapshot.autoCompact.status = AutoCompactStatus(lastReport: PanelFixtures.now, liveConversations: 0)
        await harness.push(snapshot)
        XCTAssertEqual(harness.state.banners.first?.text, "已在额度用完前压缩一段约 81 万的对话")
        XCTAssertEqual(harness.state.settings.autoCompactStatus, "压缩插件上次报到 18:30")
        XCTAssertEqual(harness.state.settings.autoCompactTone, .quiet)

        snapshot.banners = [.autoCompacted(result(.hard, .compacted, after: 74_000, resumed: true))]
        snapshot.autoCompact.status = AutoCompactStatus()
        await harness.push(snapshot)
        XCTAssertEqual(harness.state.banners.first?.text, "额度快用完：已暂停任务并压缩对话（约 81 万），\n任务已自动继续")
        XCTAssertEqual(harness.state.settings.autoCompactStatus, "还没收到压缩插件的报到")
        XCTAssertEqual(harness.state.settings.autoCompactTone, .quiet)

        snapshot.banners = [.autoCompacted(result(.hard, .failed, after: nil, resumed: true))]
        await harness.push(snapshot)
        XCTAssertEqual(harness.state.banners.first?.kind, .warning)
        XCTAssertEqual(harness.state.banners.first?.text, "额度快用完，自动压缩没有成功，\n请在对话里发送 /compact")

        // A paused task that could not be told to go on: compacted or not, the person has to, after a
        // /compact of their own only when the compaction failed.
        let notResumed: [(AutoCompactResult.Outcome, Int?, String)] = [
            (.compacted, 74_000, "额度快用完：已暂停任务并压缩对话（约 81 万），\n但任务没能自动继续，请让它接着做"),
            (.skipped, nil, "额度快用完：任务已暂停，没能自动继续，\n请让它接着做"),
            (.failed, nil, "额度快用完：任务已暂停，没能自动继续，\n请发送 /compact，再让它接着做"),
        ]
        for (outcome, after, notice) in notResumed {
            snapshot.banners = [.autoCompacted(result(.hard, outcome, after: after, resumed: false))]
            await harness.push(snapshot)
            XCTAssertEqual(harness.state.banners.first?.kind, .warning)
            XCTAssertEqual(harness.state.banners.first?.text, notice)
        }

        snapshot.banners = [.autoCompacted(result(.beforeSwitch, .compacted, after: 21_000))]
        await harness.push(snapshot)
        XCTAssertEqual(harness.state.banners.first?.kind, .neutral)
        XCTAssertEqual(harness.state.banners.first?.text, "切换前已压缩对话：约 81 万 → 2 万")
        snapshot.banners = [.autoCompacted(result(.beforeSwitch, .compacted, after: nil))]
        await harness.push(snapshot)
        XCTAssertEqual(harness.state.banners.first?.text, "切换前已压缩一段约 81 万的对话")
    }

    func testCompactingFirstShowsInTheSwitchDialogWhichCanSkipIt() async {
        let harness = await Harness.make(snapshot: PanelFixtures.compactingFirstSnapshot())
        let target = try! XCTUnwrap(harness.state.others.first { $0.id == "Claude_203" })
        XCTAssertEqual(target.status, .switching(step: .compactingConversation, stepsDone: 0))
        XCTAssertEqual(harness.state.switchDialog?.targetName, "203")
        XCTAssertEqual(harness.state.switchDialog?.phase, .compacting)
        XCTAssertTrue(harness.state.interactionLocked)
        await harness.model.select("Claude")
        XCTAssertTrue(harness.facade.recordedActions().isEmpty)
        await harness.model.skipCompaction()
        XCTAssertEqual(harness.facade.recordedActions(), [.skipCompaction])
        XCTAssertEqual(SwitchStep.compactingConversation.title(name: "203", language: .en), "Compact the chat first")
    }

    func testOperationBlocksCardEditsButNotTheInFlightResponses() async {
        var busy = PanelFixtures.mainSnapshot()
        busy.operation = .addingAccount(phase: .waitingForSignIn)
        busy.pendingAdd = PendingAddState(
            folder: profile("Claude_new"),
            phase: .waitingForSignIn,
            duplicateOf: profile("Claude_204")
        )
        let harness = await Harness.make(snapshot: busy)
        await harness.model.select("Claude")
        await harness.model.addAccount()
        await harness.model.refreshQuota("Claude")
        await harness.model.setAutoSync(false)
        await harness.model.activateBanner("history:Claude")
        XCTAssertTrue(harness.state.settings.autoSyncOnSwitch)
        XCTAssertTrue(harness.facade.recordedActions().isEmpty)

        await harness.model.cancelAdd()
        await harness.model.keepBoth()
        await harness.model.discardNew()
        await harness.model.waitForTasks()
        await harness.model.switchNow()
        await harness.model.cancelTaskGuard()
        await harness.model.skipCompaction()
        await harness.model.activateBanner("quota")
        await harness.model.quit()
        XCTAssertEqual(harness.facade.recordedActions(), [
            .cancelAddAccount,
            .resolveDuplicateAdd(.keepBoth),
            .resolveDuplicateAdd(.discardNew),
            .taskGuard(.waitThenSwitch),
            .taskGuard(.switchNow),
            .taskGuard(.cancel),
            .skipCompaction,
            .refreshQuota(folder: nil),
            .quitApp,
        ])
    }

    func testActionsValidateRenameAndIgnoreTheCurrentCard() async {
        let harness = await Harness.make()
        await harness.model.select("Claude_204")
        await harness.model.select("missing")
        harness.model.beginRename("missing")
        XCTAssertNil(harness.state.renameDialog)
        XCTAssertTrue(harness.facade.recordedActions().isEmpty)

        await harness.model.select("Claude")
        await harness.model.confirmSwitch(stopAsking: false)
        harness.model.beginRename("Claude_203")
        XCTAssertEqual(harness.state.renameDialog, RenameDialogState(id: "Claude_203", name: "203"))
        await harness.model.rename(id: "Claude_203", to: "   ")
        await harness.model.rename(id: "Claude_203", to: String(repeating: "名", count: 21))
        XCTAssertEqual(harness.state.renameDialog?.id, "Claude_203")
        XCTAssertEqual(harness.facade.recordedActions(), [.switchTo(folder: profile("Claude"))])

        await harness.model.rename(id: "Claude_203", to: "  ab  ")
        XCTAssertEqual(harness.facade.recordedActions().last, .rename(folder: profile("Claude_203"), name: "ab"))
        XCTAssertNil(harness.state.renameDialog)

        harness.model.beginRename("Claude")
        await harness.model.rename(id: "Claude", to: "a")
        await harness.model.rename(id: "Claude", to: String(repeating: "b", count: 20))
        harness.model.beginRename("Claude")
        harness.model.cancelRename("Claude")
        XCTAssertNil(harness.state.renameDialog)

        harness.model.beginRemove("Claude_203")
        XCTAssertEqual(harness.state.removeDialog, RemoveDialogState(id: "Claude_203", name: "203"))
        harness.model.dismissSheet()
        XCTAssertNil(harness.state.removeDialog)
        harness.model.beginRemove("Claude_203")
        await harness.confirmRemovalAndLetTheUndoLapse { await harness.model.confirmRemove() }
        XCTAssertNil(harness.state.removeDialog)
        await harness.until(harness.facade.recordedActions().last == .remove(folder: profile("Claude_203")), "removal")

        await harness.model.addAccount()
        await harness.model.refreshQuota("Claude")
        await harness.model.refreshQuota("Claude_signed_out")
        var signed = PanelFixtures.mainSnapshot()
        signed.accounts[1].status = .signedOut
        signed.accounts[2].status = .awaitingSignIn
        signed.accounts[3].status = .unreadable
        await harness.push(signed)
        await harness.model.refreshQuota("Claude")
        await harness.model.refreshQuota("Claude_203")
        await harness.model.refreshQuota("Claude_208")
        XCTAssertEqual(harness.facade.recordedActions().suffix(2), [
            .refreshQuota(folder: profile("Claude")),
            .refreshQuota(folder: profile("Claude_208")),
        ])

        harness.model.beginRename("Claude_208")
        var switching = signed
        switching.operation = .switching(target: profile("Claude_204"), step: .syncingSessions, completedSteps: [.closingClaude])
        await harness.push(switching)
        XCTAssertEqual(
            harness.state.current?.status,
            .switching(step: .syncingSessions, stepsDone: 1)
        )
        XCTAssertNil(harness.state.renameDialog)
        harness.model.beginRemove("Claude_208")
        XCTAssertNil(harness.state.removeDialog)
        var guarded = PanelFixtures.mainSnapshot()
        guarded.taskGuardPrompt = TaskGuardPrompt(target: profile("Claude"), busyCount: 2, unknown: false, isWaiting: false)
        await harness.push(guarded)
        XCTAssertEqual(harness.state.switchDialog?.phase, .taskGuard(title: "2 个 Code 任务正在运行", waiting: false))
    }

    func testPanelActionClosuresAndBannerRouting() async {
        let harness = await Harness.make()
        let actions = harness.model.makeActions()
        func expect(_ send: () -> Void, _ action: CompanionAction, line: UInt = #line) async {
            let before = harness.facade.recordedActions().count
            send()
            await harness.until(harness.facade.recordedActions().count == before + 1, "missing \(action)")
            XCTAssertEqual(harness.facade.recordedActions().last, action, line: line)
        }
        actions.selectAccount("Claude")
        await harness.until(harness.state.switchDialog?.phase == .asking, "the switch did not ask")
        await expect({ actions.confirmSwitch(false) }, .switchTo(folder: profile("Claude")))
        actions.beginRename("Claude_203")
        XCTAssertEqual(harness.state.renameDialog?.id, "Claude_203")
        await expect({ actions.rename("Claude_203", "  新名  ") }, .rename(folder: profile("Claude_203"), name: "新名"))
        actions.beginRename("Claude_203")
        actions.cancelRename("Claude_203")
        XCTAssertNil(harness.state.renameDialog)
        actions.remove("Claude_203")
        XCTAssertEqual(harness.state.removeDialog?.id, "Claude_203")
        await harness.confirmRemovalAndLetTheUndoLapse { actions.confirmRemove() }
        await harness.until(harness.facade.recordedActions().last == .remove(folder: profile("Claude_203")), "removal")
        await expect({ actions.addAccount() }, .addAccount)
        await expect({ actions.cancelAdd() }, .cancelAddAccount)
        await expect({ actions.keepBothAccounts() }, .resolveDuplicateAdd(.keepBoth))
        await expect({ actions.discardNewAccount() }, .resolveDuplicateAdd(.discardNew))
        await expect({ actions.waitForTasks() }, .taskGuard(.waitThenSwitch))
        await expect({ actions.switchNow() }, .taskGuard(.switchNow))
        await expect({ actions.cancelTaskGuard() }, .taskGuard(.cancel))
        await expect({ actions.bannerAction("quota") }, .refreshQuota(folder: nil))
        await expect({ actions.bannerAction("found:Claude:extra") }, .addFoundAccount(folder: profile("Claude:extra")))
        await expect({ actions.bannerSecondaryAction("found:Claude:extra") }, .dismissFoundAccount(folder: profile("Claude:extra")))
        await expect({ actions.bannerAction("history:Claude") }, .retryHistoryImport(folder: profile("Claude")))
        actions.openSettings()
        XCTAssertTrue(harness.state.isSettingsOpen)
        actions.closeSettings()
        XCTAssertFalse(harness.state.isSettingsOpen)
        await expect({ actions.setLaunchAtLogin(false) }, .setLaunchAtLogin(false))
        await expect({ actions.setAutoSync(false) }, .setAutoSync(false))
        await expect({ actions.setAppearance(.dark) }, .setAppearance(.dark))
        await expect({ actions.setAutoCompact(false) }, .setAutoCompact(false))
        await expect({ actions.setLanguage(.zhHans) }, .setLanguage(.zhHans))
        await expect({ actions.openBackups() }, .openBackupsFolder)
        await expect({ actions.quit() }, .quitApp)
        await expect({ actions.refreshQuota("Claude_204") }, .refreshQuota(folder: profile("Claude_204")))
        XCTAssertEqual(harness.facade.recordedActions(), [
            .switchTo(folder: profile("Claude")),
            .rename(folder: profile("Claude_203"), name: "新名"),
            .remove(folder: profile("Claude_203")),
            .addAccount,
            .cancelAddAccount,
            .resolveDuplicateAdd(.keepBoth),
            .resolveDuplicateAdd(.discardNew),
            .taskGuard(.waitThenSwitch),
            .taskGuard(.switchNow),
            .taskGuard(.cancel),
            .refreshQuota(folder: nil),
            .addFoundAccount(folder: profile("Claude:extra")),
            .dismissFoundAccount(folder: profile("Claude:extra")),
            .retryHistoryImport(folder: profile("Claude")),
            .setLaunchAtLogin(false),
            .setAutoSync(false),
            .setAppearance(.dark),
            .setAutoCompact(false),
            .setLanguage(.zhHans),
            .openBackupsFolder,
            .quitApp,
            .refreshQuota(folder: profile("Claude_204")),
        ])

        harness.model.panelAppeared()
        await harness.until(harness.facade.recordedActions().contains(.panelOpened), "panel")
        let resultID = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        var warned = PanelFixtures.mainSnapshot()
        warned.lastResult = outcome(.switched(to: profile("Claude"), warnings: [.backupFailed]), at: PanelFixtures.now, id: resultID)
        await harness.push(warned)
        actions.dismissResult()
        await harness.until(
            harness.facade.recordedActions().contains(.dismissResult(id: resultID)),
            "dismiss"
        )
        // The facade records the action before the model re-renders; wait for the render.
        await harness.until(
            harness.state.banners.allSatisfy { !$0.id.hasPrefix("result:") },
            "dismissed line"
        )
        XCTAssertNil(harness.state.others.first { $0.id == "Claude" }?.result)

        var again = warned
        again.lastResult = outcome(
            .failed(operation: .addAccount, reason: .cancelled),
            at: PanelFixtures.now,
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!
        )
        await harness.push(again)
        actions.bannerAction("result:\(again.lastResult!.id.uuidString)")
        await harness.until(
            harness.facade.recordedActions().contains(.dismissResult(id: again.lastResult!.id)),
            "banner dismiss"
        )
    }

    func testCountdownTickerAdvancesWithoutANewSnapshot() async {
        let reset = PanelFixtures.date(2026, 10, 25, 20, 0)
        let weeklyReset = PanelFixtures.date(2026, 10, 29, 21, 0)
        let harness = await Harness.make(snapshot: quotaSnapshot(
            fiveUsed: 10,
            fiveReset: reset,
            weekUsed: 20,
            weekReset: weeklyReset,
            freshness: .fresh
        ))
        let weekly = try! XCTUnwrap(harness.state.current?.weekly.resetLine)
        XCTAssertEqual(harness.state.current?.fiveHour.resetLine, "20:00 · 1 小时 30 分后")
        await harness.waitForWaiters(1)
        harness.clock.advance(by: 3)
        await Task.yield()
        XCTAssertEqual(harness.state.current?.fiveHour.resetLine, "20:00 · 1 小时 30 分后")

        harness.clock.advance(by: 57)
        await harness.until(
            harness.state.current?.fiveHour.resetLine == "20:00 · 1 小时 29 分后",
            "countdown did not tick"
        )
        XCTAssertEqual(harness.state.current?.weekly.resetLine, weekly)
        let ticked = ResetTimeFormatter(
            timeZone: PanelFixtures.timeZone,
            language: .zhHans,
            now: PanelFixtures.now.addingTimeInterval(60)
        )
        XCTAssertEqual(harness.state.current?.fiveHour.resetLine, ticked.fiveHourLine(resetAt: reset))

        await harness.model.setLanguage(.en)
        await harness.waitForWaiters(1)
        harness.clock.advance(by: 60)
        let english = ResetTimeFormatter(
            timeZone: PanelFixtures.timeZone,
            language: .en,
            now: PanelFixtures.now.addingTimeInterval(120)
        )
        await harness.until(
            harness.state.current?.fiveHour.resetLine == english.fiveHourLine(resetAt: reset),
            "english countdown"
        )
        XCTAssertEqual(harness.state.language, .en)
        XCTAssertEqual(harness.facade.recordedActions(), [.setLanguage(.en)])
    }

    func testCleanResultsDismissOnTheClockAndWarningsStay() async {
        let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
        var clean = PanelFixtures.mainSnapshot()
        clean.lastResult = outcome(.switched(to: profile("Claude_204"), warnings: []), at: PanelFixtures.now, id: id)
        let harness = await Harness.make(snapshot: clean)
        // A clean switch ends in its dialog, shown a moment; the card says nothing.
        XCTAssertNil(harness.state.current?.result)
        XCTAssertEqual(harness.state.switchDialog?.phase, .done)
        XCTAssertEqual(harness.state.switchDialog?.targetName, "204")
        await harness.waitForWaiters(2)
        let weekly = harness.state.current?.weekly.resetLine
        harness.clock.advance(by: 3)
        await harness.until(harness.state.switchDialog == nil, "clean result stayed")
        await harness.until(
            harness.facade.recordedActions() == [.dismissResult(id: id)],
            "missing dismiss"
        )
        XCTAssertEqual(harness.state.current?.weekly.resetLine, weekly)

        await harness.push(clean)
        XCTAssertNil(harness.state.switchDialog)
        XCTAssertEqual(harness.facade.recordedActions(), [.dismissResult(id: id)])

        let warningID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!
        var warning = PanelFixtures.mainSnapshot()
        warning.lastResult = outcome(
            .switched(to: profile("Claude"), warnings: [.continuityCaptureFailed]),
            at: PanelFixtures.now.addingTimeInterval(-30),
            id: warningID
        )
        await harness.push(warning)
        let waiters = harness.clock.waiterCount
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(harness.clock.waiterCount, waiters)
        XCTAssertNil(harness.state.others.first { $0.id == "Claude" }?.result)
        XCTAssertEqual(harness.state.banners.last?.text, "已切换，但没能记下当前对话")
        XCTAssertEqual(harness.state.banners.last?.actionTitle, "知道了")
        harness.clock.advance(by: 3)
        await Task.yield()
        XCTAssertEqual(harness.state.banners.last?.text, "已切换，但没能记下当前对话")
        XCTAssertFalse(harness.facade.recordedActions().contains(.dismissResult(id: warningID)))
        await harness.model.dismissDisplayedResult()
        XCTAssertNil(harness.state.others.first { $0.id == "Claude" }?.result)
        XCTAssertTrue(harness.state.banners.allSatisfy { !$0.id.hasPrefix("result:") })
        XCTAssertTrue(harness.facade.recordedActions().contains(.dismissResult(id: warningID)))

        let expiredID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D3")!
        var expired = PanelFixtures.mainSnapshot()
        expired.lastResult = outcome(
            .added(folder: profile("Claude_203"), warnings: []),
            at: PanelFixtures.now.addingTimeInterval(-5),
            id: expiredID
        )
        await harness.push(expired)
        XCTAssertNil(harness.state.others.first { $0.id == "Claude_203" }?.result)
        XCTAssertNil(harness.state.addDialog)
        await harness.until(
            harness.facade.recordedActions().contains(.dismissResult(id: expiredID)),
            "expired result was not dismissed"
        )

        let freshID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D4")!
        var restarted = PanelFixtures.mainSnapshot()
        restarted.lastResult = outcome(.switched(to: profile("Claude_204"), warnings: []), at: harness.clock.now(), id: freshID)
        await harness.push(restarted)
        await harness.waitForWaiters(2)
        harness.clock.advance(by: 0.8)
        await Task.yield()
        XCTAssertEqual(harness.state.switchDialog?.phase, .done)
        await harness.push(restarted)
        harness.clock.advance(by: 0.5)
        await harness.until(harness.state.switchDialog == nil, "dismiss timer restarted")
        XCTAssertTrue(harness.facade.recordedActions().contains(.dismissResult(id: freshID)))
    }

    func testInFlightOperationHoldsTheResultUntilItFinishes() async {
        let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!
        var shown = PanelFixtures.mainSnapshot()
        shown.lastResult = outcome(.switched(to: profile("Claude_204"), warnings: []), at: PanelFixtures.now, id: id)
        let harness = await Harness.make(snapshot: shown)
        await harness.waitForWaiters(2)
        var busy = shown
        busy.operation = .switching(target: profile("Claude"), step: .closingClaude, completedSteps: [])
        await harness.push(busy)
        XCTAssertEqual(harness.state.switchDialog?.phase, .running(step: .closingClaude, stepsDone: 0))
        await harness.until(harness.clock.waiterCount == 1, "dismiss timer stayed armed during the switch")
        harness.clock.advance(by: 1)
        await Task.yield()
        XCTAssertFalse(harness.facade.recordedActions().contains(.dismissResult(id: id)))

        await harness.push(shown)
        XCTAssertEqual(harness.state.switchDialog?.phase, .done)
        await harness.waitForWaiters(2)
        harness.clock.advance(by: 1.5)
        await harness.until(
            harness.facade.recordedActions().contains(.dismissResult(id: id)),
            "result did not dismiss after the operation"
        )
    }

    func testMenuBarQuotaFollowsTheFiveHourWindow() async {
        let future = PanelFixtures.date(2026, 10, 25, 21, 0)
        let past = PanelFixtures.now.addingTimeInterval(-60)
        let harness = await Harness.make(snapshot: quotaSnapshot(
            fiveUsed: nil,
            fiveReset: nil,
            weekUsed: 40,
            weekReset: future,
            freshness: .fresh
        ))
        XCTAssertEqual(harness.model.menuBarModel.title, "204")
        XCTAssertNil(harness.model.menuBarModel.quotaPercent)

        await harness.push(quotaSnapshot(fiveUsed: 28.9, fiveReset: future, freshness: .fresh))
        XCTAssertEqual(harness.model.menuBarModel.quotaPercent, 71)

        await harness.push(quotaSnapshot(fiveUsed: 80.1, fiveReset: future, freshness: .stale))
        XCTAssertEqual(harness.model.menuBarModel.quotaPercent, 19)

        await harness.push(quotaSnapshot(fiveUsed: 80, fiveReset: future, freshness: .refreshing))
        XCTAssertEqual(harness.model.menuBarModel.quotaPercent, 20)

        await harness.push(quotaSnapshot(fiveUsed: 82, fiveReset: past, freshness: .resetPassed))
        XCTAssertEqual(harness.model.menuBarModel.quotaPercent, 100)
        XCTAssertEqual(harness.state.current?.fiveHour.remainingPercent, 100)

        var switching = quotaSnapshot(fiveUsed: 82, fiveReset: past, freshness: .resetPassed)
        switching.operation = .switching(target: profile("Claude_204"), step: .closingClaude, completedSteps: [])
        await harness.push(switching)
        XCTAssertTrue(harness.model.menuBarModel.isSwitching)
        XCTAssertNil(harness.model.menuBarModel.quotaPercent)
        XCTAssertEqual(harness.model.menuBarModel.title, "正在切换到 204…")
        XCTAssertEqual(harness.model.menuBarModel.content.accessibilityLabel, "CC-Relay, 正在切换到 204…")
    }

    func testNotCompactedFirstAndReturnedAccountResults() async {
        var warned = PanelFixtures.mainSnapshot()
        warned.lastResult = outcome(
            .switched(to: profile("Claude_204"), warnings: [.notCompactedFirst]),
            at: PanelFixtures.now
        )
        let chinese = await Harness.make(snapshot: warned)
        XCTAssertEqual(chinese.state.current?.result?.text, "已切换，但对话没能先压缩")
        XCTAssertEqual(chinese.state.current?.result?.tone, .warning)
        XCTAssertEqual(chinese.state.current?.result?.canDismiss, true)

        let english = await Harness.make(snapshot: warned, preferred: ["en"])
        XCTAssertEqual(english.state.current?.result?.text, "Switched, but the chat wasn't compacted first")
        XCTAssertEqual(english.state.current?.result?.canDismiss, true)

        var failed = PanelFixtures.mainSnapshot()
        failed.lastResult = outcome(
            .failed(operation: .switchTo(profile("Claude")), reason: .returnedToPreviousAccount),
            at: PanelFixtures.now
        )
        await chinese.push(failed)
        XCTAssertNil(chinese.state.others.first { $0.id == "Claude" }?.result)
        XCTAssertNil(chinese.state.current?.result)
        XCTAssertTrue(chinese.state.banners.isEmpty)
        // The dialog names both: the one that did not open and the one Claude is back on.
        XCTAssertEqual(chinese.state.switchDialog?.phase, .failed(failedStep: 2, message: "201 没能打开，已回到 204。"))

        let englishFailure = await Harness.make(snapshot: failed, preferred: ["en"])
        XCTAssertNil(englishFailure.state.others.first { $0.id == "Claude" }?.result)
        XCTAssertEqual(englishFailure.state.switchDialog?.phase, .failed(failedStep: 2, message: "201 didn't open; back on 204."))
    }

    @MainActor
    func testReleasedModelStopsItsTasks() async {
        let facade = FakeCompanionFacade(snapshot: PanelFixtures.mainSnapshot())
        let clock = ManualClock(now: PanelFixtures.now)
        weak var released: PanelViewModel?
        var model: PanelViewModel? = PanelViewModel(
            facade: facade,
            clock: clock,
            timeZone: PanelFixtures.timeZone,
            preferredLanguages: ["zh-Hans"]
        )
        released = model
        let applied = await model?.waitUntilApplied()
        XCTAssertEqual(applied, true)
        for _ in 0..<500 where clock.waiterCount < 1 {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(clock.waiterCount, 1)
        model = nil
        for _ in 0..<500 where released != nil || clock.waiterCount != 0 {
            await Task.yield()
        }
        XCTAssertNil(released)
        XCTAssertEqual(clock.waiterCount, 0)
    }

    func testResetTimesFollowTheSystemTimeZoneWhenItChanges() async {
        // The app makes the panel with the system's zone; a trip abroad changes that zone.
        let original = ProcessInfo.processInfo.environment["TZ"]
        func useZone(_ identifier: String?) {
            if let identifier { setenv("TZ", identifier, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
        }
        useZone("Asia/Shanghai")
        defer { useZone(original) }
        let facade = FakeCompanionFacade(snapshot: PanelFixtures.mainSnapshot())
        let clock = ManualClock(now: PanelFixtures.now)
        let model = PanelViewModel(facade: facade, clock: clock, preferredLanguages: ["zh-Hans"])
        let applied = await model.waitUntilApplied()
        XCTAssertTrue(applied)
        let harness = Harness(facade: facade, clock: clock, model: model)
        // 204's 5-hour window resets at 21:00 in Shanghai, 13:00 UTC.
        XCTAssertEqual(harness.state.current?.fiveHour.resetLine.prefix(5), "21:00")
        useZone("America/New_York")
        await harness.push(PanelFixtures.mainSnapshot())
        XCTAssertEqual(harness.state.current?.fiveHour.resetLine.prefix(5), "09:00")
    }

    func testAClickedSwitchAsksFirstAndCanStopAsking() async {
        let harness = await Harness.make()
        XCTAssertTrue(harness.state.settings.confirmSwitch)
        await harness.model.select("Claude")
        XCTAssertTrue(harness.facade.recordedActions().isEmpty)
        XCTAssertEqual(harness.state.switchDialog?.phase, .asking)
        XCTAssertEqual(harness.state.switchDialog?.targetName, "201")
        XCTAssertEqual(harness.state.switchDialog?.sourceName, "204")
        // While it asks, no other card is switched to and nothing else opens over it.
        await harness.model.select("Claude_203")
        XCTAssertEqual(harness.state.switchDialog?.targetName, "201")
        harness.model.cancelSwitchQuestion()
        XCTAssertNil(harness.state.switchDialog)
        XCTAssertTrue(harness.facade.recordedActions().isEmpty)

        // Switch: the dialog goes straight to the first step, before Core says the switch is under way.
        await harness.model.select("Claude")
        await harness.model.confirmSwitch(stopAsking: false)
        XCTAssertEqual(harness.facade.recordedActions(), [.switchTo(folder: profile("Claude"))])

        // "Don't ask again" turns the setting off, and the next click switches at once.
        await harness.model.select("Claude_203")
        await harness.model.confirmSwitch(stopAsking: true)
        XCTAssertEqual(harness.facade.recordedActions().suffix(2), [.setConfirmSwitch(false), .switchTo(folder: profile("Claude_203"))])
        var off = PanelFixtures.mainSnapshot()
        off.settings.confirmSwitch = false
        await harness.push(off)
        XCTAssertFalse(harness.state.settings.confirmSwitch)
        await harness.model.select("Claude_208")
        XCTAssertEqual(harness.facade.recordedActions().last, .switchTo(folder: profile("Claude_208")))
        XCTAssertNotEqual(harness.state.switchDialog?.phase, .asking)

        // The settings switch turns it back on.
        await harness.model.setConfirmSwitch(true)
        XCTAssertEqual(harness.facade.recordedActions().last, .setConfirmSwitch(true))
        XCTAssertTrue(harness.state.settings.confirmSwitch)
    }

    func testASwitchCoreStartsByItselfIsNotAskedAbout() async {
        let harness = await Harness.make()
        var switching = PanelFixtures.mainSnapshot()
        switching.operation = .switching(target: profile("Claude_203"), step: .closingClaude, completedSteps: [])
        await harness.push(switching)
        XCTAssertEqual(harness.state.switchDialog?.phase, .running(step: .closingClaude, stepsDone: 0))
        XCTAssertTrue(harness.facade.recordedActions().isEmpty)
    }

    func testAQuestionGivesWayToCodeTasksAfterSwitchIsChosen() async {
        let harness = await Harness.make()
        await harness.model.select("Claude")
        await harness.model.confirmSwitch(stopAsking: false)
        var guarded = PanelFixtures.mainSnapshot()
        guarded.operation = .waitingForTasks(target: profile("Claude"))
        guarded.taskGuardPrompt = TaskGuardPrompt(target: profile("Claude"), busyCount: 1, unknown: false, isWaiting: false)
        await harness.push(guarded)
        XCTAssertEqual(harness.state.switchDialog?.phase, .taskGuard(title: "1 个 Code 任务正在运行", waiting: false))
        // Once Core lets the question go, nothing of it is left.
        await harness.push(PanelFixtures.mainSnapshot())
        XCTAssertNil(harness.state.switchDialog)
    }

    func testAFailedSwitchOrAddCanBeTriedAgainOrClosed() async {
        let switchID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
        var failed = PanelFixtures.mainSnapshot()
        failed.lastResult = outcome(.failed(operation: .switchTo(profile("Claude")), reason: .couldNotOpenClaude),
                                    at: PanelFixtures.now, id: switchID)
        let harness = await Harness.make(snapshot: failed)
        XCTAssertEqual(harness.state.switchDialog?.phase, .failed(failedStep: 2, message: "没能打开 Claude"))
        // Tried again, it does not ask: the person already chose it.
        await harness.model.retrySwitch()
        XCTAssertEqual(harness.facade.recordedActions(), [.dismissResult(id: switchID), .switchTo(folder: profile("Claude"))])

        let addID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!
        var addFailed = PanelFixtures.mainSnapshot()
        addFailed.lastResult = outcome(.failed(operation: .addAccount, reason: .signedInAccountDiffers),
                                       at: PanelFixtures.now, id: addID)
        await harness.push(addFailed)
        XCTAssertEqual(harness.state.addDialog, .failed(message: "登录的账号不同"))
        await harness.model.retryAdd()
        XCTAssertEqual(harness.facade.recordedActions().suffix(2), [.dismissResult(id: addID), .addAccount])

        let closeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F3")!
        failed.lastResult?.id = closeID
        await harness.push(failed)
        harness.model.makeActions().closeSwitchResult()
        await harness.until(harness.facade.recordedActions().last == .dismissResult(id: closeID), "close")
        await harness.until(harness.state.switchDialog == nil, "the failed switch stayed")
    }

    func testASwitchRefusedBeforeItsFirstStepCrossesNoStepOut() async {
        let harness = await Harness.make()
        await harness.model.select("Claude")
        await harness.model.confirmSwitch(stopAsking: false)
        var refused = PanelFixtures.mainSnapshot()
        refused.lastResult = outcome(.failed(operation: .switchTo(profile("Claude")), reason: .targetUnreadable),
                                     at: PanelFixtures.now)
        await harness.push(refused)
        XCTAssertEqual(harness.state.switchDialog?.phase, .failed(failedStep: nil, message: "账号无法读取"))

        // A reason that names its step wins over the last step seen, which a quick switch may have passed.
        await harness.model.retrySwitch()
        var syncing = PanelFixtures.mainSnapshot()
        syncing.operation = .switching(target: profile("Claude"), step: .syncingSessions, completedSteps: [.closingClaude])
        await harness.push(syncing)
        var failed = PanelFixtures.mainSnapshot()
        failed.lastResult = outcome(.failed(operation: .switchTo(profile("Claude")), reason: .couldNotOpenClaude),
                                    at: PanelFixtures.now, id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F5")!)
        await harness.push(failed)
        XCTAssertEqual(harness.state.switchDialog?.phase, .failed(failedStep: 2, message: "没能打开 Claude"))
        XCTAssertEqual(harness.state.switchDialog?.sourceName, "204")

        // Without one, the last step seen under way is crossed out.
        await harness.model.retrySwitch()
        await harness.push(syncing)
        var unreadable = PanelFixtures.mainSnapshot()
        unreadable.lastResult = outcome(.failed(operation: .switchTo(profile("Claude")), reason: .targetUnreadable),
                                        at: PanelFixtures.now, id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F6")!)
        await harness.push(unreadable)
        XCTAssertEqual(harness.state.switchDialog?.phase, .failed(failedStep: 1, message: "账号无法读取"))
    }

    func testAnAddedAccountShowsAMomentInItsDialog() async {
        var added = PanelFixtures.mainSnapshot()
        added.lastResult = outcome(.added(folder: profile("Claude_203"), warnings: []), at: PanelFixtures.now)
        let harness = await Harness.make(snapshot: added)
        XCTAssertEqual(harness.state.addDialog, .added(name: "203", detail: "Max 5× · 网页订阅"))
        await harness.waitForWaiters(2)
        harness.clock.advance(by: 1.5)
        await harness.until(harness.state.addDialog == nil, "the added dialog stayed")
    }

    func testARemovedAccountLeavesAtOnceAndComesBackOnUndo() async {
        let harness = await Harness.make()
        await harness.waitForWaiters(1)
        harness.model.beginRemove("Claude_203")
        let waiting = harness.clock.waiterCount
        await harness.model.confirmRemove()
        await harness.waitForWaiters(waiting + 2)
        XCTAssertNil(harness.state.removeDialog)
        XCTAssertEqual(harness.state.others.map(\.id), ["Claude", "Claude_208"])
        XCTAssertEqual(harness.state.hud?.text, "已移除 203")
        XCTAssertEqual(harness.state.hud?.actionTitle, "撤销")
        XCTAssertTrue(harness.facade.recordedActions().isEmpty)

        harness.model.makeActions().hudAction()
        XCTAssertEqual(harness.state.others.map(\.id), ["Claude", "Claude_203", "Claude_208"])
        XCTAssertEqual(harness.state.hud?.text, "已恢复 203")
        XCTAssertNil(harness.state.hud?.actionTitle)
        // The removal's timer is gone; the new note's is set.
        await harness.waitForWaiters(waiting + 1)
        harness.clock.advance(by: 5)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(harness.facade.recordedActions().isEmpty)
        XCTAssertNil(harness.state.hud)

        // Again, and this time the note runs out: the removal goes through, and Core's own word about it
        // is put away unseen.
        harness.model.beginRemove("Claude_203")
        await harness.confirmRemovalAndLetTheUndoLapse { await harness.model.confirmRemove() }
        await harness.until(harness.facade.recordedActions() == [.remove(folder: profile("Claude_203"))], "removal")
        await harness.until(harness.state.hud == nil, "the note stayed")
        XCTAssertFalse(harness.state.others.contains { $0.id == "Claude_203" })
        let resultID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F4")!
        var removed = PanelFixtures.mainSnapshot()
        removed.accounts.removeAll { $0.folder.name == "Claude_203" }
        removed.lastResult = outcome(.removed(folder: profile("Claude_203"), partialCleanup: false),
                                     at: harness.clock.now(), id: resultID)
        await harness.push(removed)
        XCTAssertNil(harness.state.hud)
        XCTAssertTrue(harness.state.banners.isEmpty)
        await harness.until(harness.facade.recordedActions().last == .dismissResult(id: resultID), "quiet result")
    }

    func testARemovalCoreRefusesBringsTheAccountBack() async {
        let harness = await Harness.make()
        await harness.waitForWaiters(1)
        harness.model.beginRemove("Claude_203")
        await harness.confirmRemovalAndLetTheUndoLapse { await harness.model.confirmRemove() }
        await harness.until(harness.facade.recordedActions() == [.remove(folder: profile("Claude_203"))], "removal")
        var refused = PanelFixtures.mainSnapshot()
        refused.lastResult = outcome(.failed(operation: .remove(profile("Claude_203")), reason: .refusedWhileRunning),
                                     at: harness.clock.now())
        await harness.push(refused)
        XCTAssertTrue(harness.state.others.contains { $0.id == "Claude_203" })
        XCTAssertEqual(harness.state.banners.last?.text, "移除失败：Claude 正在使用它")
    }

    func testASecondRemovalSendsTheFirstAtOnceAndKeepsItsOwnUndo() async {
        let harness = await Harness.make()
        await harness.waitForWaiters(1)
        harness.model.beginRemove("Claude_203")
        let waiting = harness.clock.waiterCount
        await harness.model.confirmRemove()
        await harness.waitForWaiters(waiting + 2)
        harness.clock.advance(by: 2)
        harness.model.beginRemove("Claude_208")
        await harness.model.confirmRemove()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(harness.facade.recordedActions(), [.remove(folder: profile("Claude_203"))])
        // Both stay off the list: one sent, one still waiting.
        XCTAssertEqual(harness.state.others.map(\.id), ["Claude"])
        XCTAssertEqual(harness.state.hud?.text, "已移除 208")
        // When the first note would have run out, the second still waits for its own.
        harness.clock.advance(by: 2.5)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(harness.facade.recordedActions(), [.remove(folder: profile("Claude_203"))])
        harness.model.undoRemoval()
        XCTAssertEqual(harness.state.others.map(\.id), ["Claude", "Claude_208"])
        harness.clock.advance(by: 5)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(harness.facade.recordedActions(), [.remove(folder: profile("Claude_203"))])
    }

    func testCardsShowPlaceholdersAndNoticesWhereTheirBarsGo() async {
        let loading = await Harness.make(snapshot: PanelFixtures.quotaLoadingSnapshot())
        XCTAssertEqual(loading.state.others.first { $0.id == "Claude_203" }?.quota, .loading)
        XCTAssertEqual(loading.state.others.first { $0.id == "Claude_208" }?.quota, .notice("暂时无法获取额度", .warning))
        XCTAssertEqual(loading.state.current?.quota, .figures)

        let alone = await Harness.make(snapshot: PanelFixtures.emptySeatSnapshot())
        XCTAssertNotNil(alone.state.current)
        XCTAssertTrue(alone.state.others.isEmpty)
        XCTAssertNil(alone.state.recommendation)
        XCTAssertTrue(alone.state.canAddAccount)
    }

    func testFacadeScenesAreTheMappedPanelStates() {
        XCTAssertEqual(
            PanelFixtures.scenes.map(\.name),
            [
                "main",
                "switch-ask",
                "switching",
                "switch-failed",
                "task-guard",
                "waiting-for-sign-in",
                "signed-out",
                "awaiting-sign-in",
                "settings",
                "settings-ignored",
                "settings-plugin-update-failed",
                "remove-confirm",
                "plugin-ask",
                "rename",
                "quota-loading",
                "empty-seat",
                "duplicate",
                "duplicate-add",
                "importing-history",
                "quota-keychain",
                "reset-passed",
                "history-paused",
                "found-account",
                "switch-warning",
                "compacting-first",
                "returned-previous",
                "auto-compacted",
                "many-accounts",
                "recommend",
                "recommend-none",
                "auto-switch-limit-repeated",
                "auto-switch-account-restricted",
            ]
        )
    }
}

private func profile(_ name: String) -> ProfileFolder {
    guard let folder = try? ProfileFolder(name) else {
        preconditionFailure("Fixture folder \(name) is not a single path component.")
    }
    return folder
}

private func account(
    _ name: String,
    display: String,
    status: AccountSummary.Status = .signedIn,
    email: String? = nil,
    plan: String? = "Pro",
    channel: SubscriptionChannel = .web,
    duplicateOf: ProfileFolder? = nil,
    seed: String? = nil,
    freshness: QuotaFreshness = .fresh
) -> AccountSummary {
    let folder = profile(name)
    return AccountSummary(
        folder: folder,
        displayName: display,
        status: status,
        email: email,
        plan: plan,
        channel: channel,
        quota: QuotaSnapshot(
            folder: folder,
            accountUUID: seed ?? name,
            organizationUUID: "org",
            plan: plan,
            email: email,
            channel: channel,
            fiveHour: QuotaWindow(usedPercent: 28, resetsAt: PanelFixtures.date(2026, 10, 25, 21, 0)),
            sevenDay: QuotaWindow(usedPercent: 40, resetsAt: PanelFixtures.date(2026, 10, 29, 21, 0)),
            fetchedAt: PanelFixtures.now,
            source: .network
        ),
        quotaFreshness: freshness,
        duplicateOf: duplicateOf
    )
}

private func snapshot(
    accounts: [AccountSummary],
    current: String?,
    version: String = "0.1.0"
) -> CompanionSnapshot {
    CompanionSnapshot(
        accounts: accounts,
        currentFolder: current.map(profile),
        appVersion: version
    )
}

private func quotaSnapshot(
    fiveUsed: Double? = nil,
    fiveReset: Date? = nil,
    weekUsed: Double? = 10,
    weekReset: Date? = nil,
    fetchedAt: Date = PanelFixtures.now,
    freshness: QuotaFreshness,
    includeQuota: Bool = true
) -> CompanionSnapshot {
    let folder = profile("Claude_204")
    let quota = includeQuota
        ? QuotaSnapshot(
            folder: folder,
            accountUUID: "seed-204",
            organizationUUID: "org",
            plan: "Max",
            email: "oli@example.com",
            channel: .web,
            fiveHour: QuotaWindow(usedPercent: fiveUsed, resetsAt: fiveReset),
            sevenDay: QuotaWindow(usedPercent: weekUsed, resetsAt: weekReset),
            fetchedAt: fetchedAt,
            source: .network
        )
        : nil
    let row = AccountSummary(
        folder: folder,
        displayName: "204",
        status: .signedIn,
        email: "oli@example.com",
        plan: "Max",
        channel: .web,
        quota: quota,
        quotaFreshness: freshness
    )
    return snapshot(accounts: [row], current: "Claude_204")
}

private func outcome(
    _ outcome: OperationResult.Outcome,
    at finished: Date,
    id: UUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
) -> OperationResult {
    OperationResult(id: id, finishedAt: finished, outcome: outcome)
}
