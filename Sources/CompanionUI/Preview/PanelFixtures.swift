import Foundation
import CompanionCore

public enum FixtureScene: String, CaseIterable, Sendable {
    case main
    case switchAsk = "switch-ask"
    case switching
    case switchFailed = "switch-failed"
    case taskGuard = "task-guard"
    case waitingForSignIn = "waiting-for-sign-in"
    case signedOut = "signed-out"
    case awaitingSignIn = "awaiting-sign-in"
    case settings
    case settingsIgnored = "settings-ignored"
    case settingsPluginUpdateFailed = "settings-plugin-update-failed"
    case removeConfirm = "remove-confirm"
    case pluginAsk = "plugin-ask"
    case rename
    case quotaLoading = "quota-loading"
    case emptySeat = "empty-seat"
    case duplicate
    case duplicateAdd = "duplicate-add"
    case importingHistory = "importing-history"
    case quotaKeychain = "quota-keychain"
    case resetPassed = "reset-passed"
    case historyPaused = "history-paused"
    case foundAccount = "found-account"
    case switchWarning = "switch-warning"
    case compactingFirst = "compacting-first"
    case returnedPrevious = "returned-previous"
    case autoCompacted = "auto-compacted"
    case manyAccounts = "many-accounts"
    case recommend
    case recommendNone = "recommend-none"
    case autoSwitchLimitRepeated = "auto-switch-limit-repeated"
    case autoSwitchAccountRestricted = "auto-switch-account-restricted"

    public var name: String { rawValue }

    /// Builds the scene through `PanelViewModel`, so the picture is the real mapping.
    @MainActor
    public func make(_ language: L10nLanguage) async throws -> PanelViewState {
        switch self {
        case .main:
            return try await PanelFixtures.load(PanelFixtures.mainSnapshot(), language: language)
        case .switchAsk:
            return try await PanelFixtures.load(PanelFixtures.mainSnapshot(), language: language) { model in
                await model.select("Claude_203")
            }
        case .switching:
            return try await PanelFixtures.load(PanelFixtures.switchingSnapshot(), language: language)
        case .switchFailed:
            return try await PanelFixtures.load(PanelFixtures.switchFailedSnapshot(), language: language)
        case .taskGuard:
            return try await PanelFixtures.load(PanelFixtures.taskGuardSnapshot(), language: language)
        case .waitingForSignIn:
            return try await PanelFixtures.load(PanelFixtures.waitingSnapshot(), language: language)
        case .signedOut:
            return try await PanelFixtures.load(PanelFixtures.signedOutSnapshot(), language: language)
        case .awaitingSignIn:
            return try await PanelFixtures.load(PanelFixtures.awaitingSnapshot(), language: language)
        case .settings:
            return try await PanelFixtures.load(PanelFixtures.mainSnapshot(), language: language) { model in
                model.openSettings()
            }
        case .settingsIgnored:
            return try await PanelFixtures.load(PanelFixtures.ignoredSnapshot(), language: language) { model in
                model.openSettings()
            }
        case .settingsPluginUpdateFailed:
            var snapshot = PanelFixtures.mainSnapshot()
            snapshot.pluginUpdateFailed = true
            return try await PanelFixtures.load(snapshot, language: language) { model in
                model.openSettings()
            }
        case .removeConfirm:
            return try await PanelFixtures.load(PanelFixtures.mainSnapshot(), language: language) { model in
                model.beginRemove("Claude_203")
            }
        case .pluginAsk:
            var snapshot = PanelFixtures.mainSnapshot()
            snapshot.settings.autoSwitchOnQuota = false
            snapshot.pluginReady = false
            return try await PanelFixtures.load(snapshot, language: language) { model in
                model.openSettings()
                await model.setAutoSwitch(true)
            }
        case .rename:
            return try await PanelFixtures.load(PanelFixtures.mainSnapshot(), language: language) { model in
                model.beginRename("Claude_203")
            }
        case .quotaLoading:
            return try await PanelFixtures.load(PanelFixtures.quotaLoadingSnapshot(), language: language)
        case .emptySeat:
            return try await PanelFixtures.load(PanelFixtures.emptySeatSnapshot(), language: language)
        case .duplicate:
            return try await PanelFixtures.load(PanelFixtures.duplicateSnapshot(), language: language)
        case .duplicateAdd:
            return try await PanelFixtures.load(PanelFixtures.duplicateAddSnapshot(), language: language)
        case .importingHistory:
            return try await PanelFixtures.load(PanelFixtures.importingSnapshot(), language: language)
        case .quotaKeychain:
            return try await PanelFixtures.load(PanelFixtures.keychainSnapshot(), language: language)
        case .resetPassed:
            return try await PanelFixtures.load(PanelFixtures.resetPassedSnapshot(), language: language)
        case .historyPaused:
            return try await PanelFixtures.load(PanelFixtures.historySnapshot(), language: language)
        case .foundAccount:
            return try await PanelFixtures.load(PanelFixtures.foundSnapshot(), language: language)
        case .switchWarning:
            return try await PanelFixtures.load(PanelFixtures.warningSnapshot(), language: language)
        case .compactingFirst:
            return try await PanelFixtures.load(PanelFixtures.compactingFirstSnapshot(), language: language)
        case .returnedPrevious:
            return try await PanelFixtures.load(PanelFixtures.returnedPreviousSnapshot(), language: language)
        case .manyAccounts:
            return try await PanelFixtures.load(PanelFixtures.manyAccountsSnapshot(), language: language)
        case .autoCompacted:
            return try await PanelFixtures.load(PanelFixtures.autoCompactedSnapshot(), language: language)
        case .recommend:
            return try await PanelFixtures.load(PanelFixtures.recommendSnapshot(), language: language)
        case .recommendNone:
            return try await PanelFixtures.load(PanelFixtures.recommendNoneSnapshot(), language: language)
        case .autoSwitchLimitRepeated:
            var snapshot = PanelFixtures.mainSnapshot()
            snapshot.banners = [.autoSwitchPaused(.limitRepeated)]
            return try await PanelFixtures.load(snapshot, language: language)
        case .autoSwitchAccountRestricted:
            var snapshot = PanelFixtures.mainSnapshot()
            snapshot.banners = [.autoSwitchPaused(.accountRestricted)]
            return try await PanelFixtures.load(snapshot, language: language)
        }
    }
}

public enum PanelFixtures {
    public static let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
    public static let now = date(2026, 10, 25, 18, 30)

    public static var scenes: [FixtureScene] { FixtureScene.allCases }

    @MainActor
    public static func load(
        _ snapshot: CompanionSnapshot,
        language: L10nLanguage,
        configure: (PanelViewModel) async -> Void = { _ in }
    ) async throws -> PanelViewState {
        let facade = FakeCompanionFacade(snapshot: snapshot)
        let preferred = language == .zhHans ? ["zh-Hans"] : ["en"]
        let model = PanelViewModel(
            facade: facade,
            clock: FrozenClock(instant: now),
            timeZone: timeZone,
            preferredLanguages: preferred
        )
        guard await model.waitUntilApplied() else {
            throw FixtureLoadError.snapshotNotApplied
        }
        await configure(model)
        return model.state
    }

    public static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    static func mainSnapshot() -> CompanionSnapshot {
        base(accounts: roster())
    }

    static func switchingSnapshot() -> CompanionSnapshot {
        var snapshot = mainSnapshot()
        snapshot.operation = .switching(
            target: folder("Claude"),
            step: .syncingSessions,
            completedSteps: [.closingClaude]
        )
        return snapshot
    }

    /// Claude did not open on 201, and the switch went no further.
    static func switchFailedSnapshot() -> CompanionSnapshot {
        var snapshot = mainSnapshot()
        snapshot.lastResult = OperationResult(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            finishedAt: now,
            outcome: .failed(operation: .switchTo(folder("Claude")), reason: .couldNotOpenClaude)
        )
        return snapshot
    }

    static func taskGuardSnapshot() -> CompanionSnapshot {
        var snapshot = mainSnapshot()
        snapshot.taskGuardPrompt = TaskGuardPrompt(
            target: folder("Claude"),
            busyCount: 1,
            unknown: false,
            isWaiting: false
        )
        return snapshot
    }

    static func waitingSnapshot() -> CompanionSnapshot {
        var snapshot = mainSnapshot()
        let pending = folder("Claude_new")
        snapshot.operation = .addingAccount(phase: .waitingForSignIn)
        snapshot.pendingAdd = PendingAddState(folder: pending, phase: .waitingForSignIn)
        return snapshot
    }

    static func signedOutSnapshot() -> CompanionSnapshot {
        var rows = roster()
        rows[1].quotaFreshness = .unavailable
        rows[2].status = .signedOut
        rows[3].status = .unreadable
        return base(accounts: rows)
    }

    static func awaitingSnapshot() -> CompanionSnapshot {
        var rows = roster()
        rows[2].status = .awaitingSignIn
        return base(accounts: rows)
    }

    /// 203's quota has not come back yet; 208's could not be read.
    static func quotaLoadingSnapshot() -> CompanionSnapshot {
        var rows = roster()
        rows[2].quota = nil
        rows[2].quotaFreshness = .refreshing
        rows[3].quotaFreshness = .unavailable
        return base(accounts: rows)
    }

    /// Only the account in use, so there is nothing to switch to.
    static func emptySeatSnapshot() -> CompanionSnapshot {
        base(accounts: Array(roster().prefix(1)))
    }

    static func ignoredSnapshot() -> CompanionSnapshot {
        var snapshot = mainSnapshot()
        snapshot.ignoredFolders = [folder("Claude_206")]
        return snapshot
    }

    static func duplicateSnapshot() -> CompanionSnapshot {
        var rows = roster()
        rows[0].duplicateOf = folder("Claude_203")
        rows[2].duplicateOf = folder("Claude_204")
        return base(accounts: rows)
    }

    static func duplicateAddSnapshot() -> CompanionSnapshot {
        var snapshot = mainSnapshot()
        let pending = folder("Claude_new")
        snapshot.operation = .addingAccount(phase: .waitingForSignIn)
        snapshot.pendingAdd = PendingAddState(
            folder: pending,
            phase: .waitingForSignIn,
            duplicateOf: folder("Claude_204")
        )
        return snapshot
    }

    static func importingSnapshot() -> CompanionSnapshot {
        var snapshot = mainSnapshot()
        snapshot.operation = .addingAccount(phase: .importingHistory)
        return snapshot
    }

    static func keychainSnapshot() -> CompanionSnapshot {
        var snapshot = mainSnapshot()
        snapshot.banners = [.quotaUnavailable]
        return snapshot
    }

    static func resetPassedSnapshot() -> CompanionSnapshot {
        var rows = roster()
        rows[0].quotaFreshness = .resetPassed
        if var quota = rows[0].quota {
            // Only the 5-hour window has crossed its reset. Weekly still runs until 10月29日.
            quota.fiveHour.resetsAt = date(2026, 10, 25, 18, 0)
            rows[0].quota = quota
        }
        return base(accounts: rows)
    }

    static func historySnapshot() -> CompanionSnapshot {
        var snapshot = mainSnapshot()
        snapshot.banners = [.historyImportPaused(folder: folder("Claude"), issue: .failed)]
        return snapshot
    }

    static func foundSnapshot() -> CompanionSnapshot {
        var snapshot = mainSnapshot()
        snapshot.banners = [.foundAccount(folder: folder("Claude_9"))]
        return snapshot
    }

    /// The current account, 204, is down to 7 % of its 5 hours, so the card under it suggests 208,
    /// whose week resets soonest.
    static func recommendSnapshot() -> CompanionSnapshot {
        var snapshot = mainSnapshot()
        snapshot.accounts[0].quota?.fiveHour.usedPercent = 93
        return snapshot
    }

    /// No account can be used for now: 204, 201 and 208 have under 10 % of their 5 hours, 203 has used its week.
    static func recommendNoneSnapshot() -> CompanionSnapshot {
        var rows = roster()
        setUsed(&rows[0], five: 95, week: 54)
        setUsed(&rows[1], five: 95, week: 19)
        setUsed(&rows[2], five: 45, week: 100)
        setUsed(&rows[3], five: 92, week: 91)
        return base(accounts: rows)
    }

    private static func setUsed(_ account: inout AccountSummary, five: Double, week: Double) {
        account.quota?.fiveHour.usedPercent = five
        if account.quota?.fiveHour.resetsAt == nil {
            account.quota?.fiveHour.resetsAt = date(2026, 10, 25, 20, 40)
        }
        account.quota?.sevenDay.usedPercent = week
    }

    /// More accounts than the panel holds, so the list scrolls.
    static func manyAccountsSnapshot() -> CompanionSnapshot {
        let extra = (210...215).map { number in
            summary(folder: "Claude_\(number)", name: "\(number)", email: nil, plan: "Pro", channel: .web,
                    seed: "seed-\(number)", five: (60, date(2026, 10, 25, 22, 0)), week: (30, date(2026, 10, 30, 9, 0)))
        }
        return base(accounts: roster() + extra)
    }

    static func compactingFirstSnapshot() -> CompanionSnapshot {
        var snapshot = mainSnapshot()
        snapshot.operation = .switching(target: folder("Claude_203"), step: .compactingConversation, completedSteps: [])
        return snapshot
    }

    static func returnedPreviousSnapshot() -> CompanionSnapshot {
        var snapshot = mainSnapshot()
        snapshot.lastResult = OperationResult(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            finishedAt: now,
            outcome: .failed(operation: .switchTo(folder("Claude")), reason: .returnedToPreviousAccount)
        )
        return snapshot
    }

    static func autoCompactedSnapshot() -> CompanionSnapshot {
        var snapshot = mainSnapshot()
        let result = AutoCompactResult(trigger: .hard, outcome: .compacted, tokensBefore: 812_000, tokensAfter: 74_000,
                                       finishedAt: now, resumed: true)
        snapshot.banners = [.autoCompacted(result)]
        snapshot.autoCompact = AutoCompactSummary(status: AutoCompactStatus(lastReport: now, liveConversations: 1), lastResult: result)
        return snapshot
    }

    static func warningSnapshot() -> CompanionSnapshot {
        var snapshot = mainSnapshot()
        snapshot.lastResult = OperationResult(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            finishedAt: now,
            outcome: .switched(to: folder("Claude_204"), warnings: [.sessionsNotSynced(count: 3)])
        )
        return snapshot
    }

    private static func base(accounts: [AccountSummary]) -> CompanionSnapshot {
        CompanionSnapshot(
            accounts: accounts,
            currentFolder: folder("Claude_204"),
            settings: Settings(),
            appVersion: "0.1.0"
        )
    }

    /// 204 is current, then 201, 203, and 208. Registry order is the card order.
    private static func roster() -> [AccountSummary] {
        [
            summary(
                folder: "Claude_204",
                name: "204",
                email: "oli@example.com",
                plan: "Max",
                channel: .web,
                seed: "seed-204",
                five: (28, date(2026, 10, 25, 21, 0)),
                week: (54, date(2026, 10, 29, 21, 0))
            ),
            summary(
                folder: "Claude",
                name: "201",
                email: "anna@example.com",
                plan: "Pro",
                channel: .appStore,
                seed: "seed-201",
                five: (82, date(2026, 10, 25, 19, 5)),
                week: (19, date(2026, 11, 1, 9, 0))
            ),
            summary(
                folder: "Claude_203",
                name: "203",
                email: "kai@example.com",
                plan: "Max 5×",
                channel: .web,
                seed: "seed-203",
                five: (45, date(2026, 10, 25, 23, 10)),
                week: (72, date(2026, 10, 31, 18, 0))
            ),
            summary(
                folder: "Claude_208",
                name: "208",
                email: nil,
                plan: "Team",
                channel: .googlePlay,
                seed: "Claude_208",
                five: (nil, nil),
                week: (91, date(2026, 10, 26, 8, 15))
            ),
        ]
    }

    private static func summary(
        folder folderName: String,
        name: String,
        email: String?,
        plan: String,
        channel: SubscriptionChannel,
        seed: String,
        five: (Double?, Date?),
        week: (Double?, Date?)
    ) -> AccountSummary {
        let profile = folder(folderName)
        return AccountSummary(
            folder: profile,
            displayName: name,
            status: .signedIn,
            email: email,
            plan: plan,
            channel: channel,
            quota: QuotaSnapshot(
                folder: profile,
                accountUUID: seed,
                organizationUUID: "org-\(name)",
                plan: plan,
                email: email,
                channel: channel,
                fiveHour: QuotaWindow(usedPercent: five.0, resetsAt: five.1),
                sevenDay: QuotaWindow(usedPercent: week.0, resetsAt: week.1),
                fetchedAt: now,
                source: .network
            ),
            quotaFreshness: .fresh
        )
    }

    private static func folder(_ name: String) -> ProfileFolder {
        do {
            return try ProfileFolder(name)
        } catch {
            preconditionFailure("Fixture folder \(name) is not a single path component.")
        }
    }
}

enum FixtureLoadError: Error {
    case snapshotNotApplied
}
