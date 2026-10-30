import AppKit
import XCTest
import CompanionCore
@testable import CompanionUI

@MainActor
final class TextFitTests: XCTestCase {
    nonisolated override func setUp() {
        super.setUp()
        XCTAssertTrue(TestFonts.loaded)
    }

    func testStringsFitTheirSlots() {
        var margins: [(slack: CGFloat, name: String)] = []
        for key in L10nKey.allCases {
            // These wrap inside the card. SheetSizingTests renders their actual narrow layout,
            // including the quota notice's icon and padding, instead of assuming a single text line.
            if [.quotaTimedOut, .quotaReadFailed, .quotaRefused, .quotaRateLimited, .quotaCachedFailure].contains(key) { continue }
            let role = role(for: key)
            for language in L10nLanguage.allCases {
                let text = render(key, language)
                record(text, name: "\(key.rawValue).\(language.fileToken)", role: role, into: &margins)
            }
        }
        let dynamics: [(String, TextRole)] = [
            ("12月31日 周三 23:59", .resetLine),
            ("23:59 · 4 小时 59 分后", .resetLine),
            ("Wed, Dec 31, 23:59", .resetLine),
            ("23:59 · in 4h 59m", .resetLine),
        ]
        for (text, role) in dynamics {
            record(text, name: "dynamic.\(text)", role: role, into: &margins)
        }
        // Every suggestion line as the card builds it, with the widest day and numbers.
        let decisions: [Recommendation] = [
            .switchTo(id: "a", reason: .currentUnknown),
            .switchTo(id: "a", reason: .currentFiveHourLow(percent: 9)),
            .switchTo(id: "a", reason: .currentWeekSpent),
            .switchTo(id: "a", reason: .noCurrent),
        ]
        for language in L10nLanguage.allCases {
            for decision in decisions {
                for day in [widestDay(language), nil] {
                    let text = RecommendationCopy.reason(for: decision, day: day, language: language)
                    record(text, name: "reason.\(decision).\(day ?? "unstarted").\(language.fileToken)", role: .reason, into: &margins)
                }
            }
        }
        let chineseName = "甲乙丙丁戊己庚辛壬癸甲乙丙丁戊己庚辛壬癸"
        let latinName = "AbcdefghijAbcdefghij"
        XCTAssertEqual(chineseName.count, 20)
        XCTAssertEqual(latinName.count, 20)
        assertTruncates(chineseName, role: .tileName)
        assertTruncates(latinName, role: .tileName)
        assertTruncates(chineseName, role: .heroName)
        XCTAssertTrue(TextRole.heroName.truncates)
        XCTAssertEqual(TextChrome.lineLimit, 1)
        XCTAssertEqual(TextChrome.tailTruncation, .tail)
        XCTAssertTrue(TextRole.heroName.truncates)
        XCTAssertTrue(TextRole.tileName.truncates)
        XCTAssertTrue(TextRole.identity.truncates)

        margins.sort { $0.slack < $1.slack }
        print("Text-fit margins (pt), tightest first")
        for row in margins {
            print(String(format: "%7.1f  %@", row.slack, row.name))
        }
    }

    func testParagraphLinesArePrebrokenAndFit() {
        for language in L10nLanguage.allCases {
            let body = L10nKey.taskGuardBody.template(language).components(separatedBy: "\n")
            XCTAssertLessThanOrEqual(body.count, 4, language.fileToken)
            XCTAssertFalse(body.contains(where: \.isEmpty))
            let compacting = L10nKey.compactFirstBody.template(language).components(separatedBy: "\n")
            XCTAssertEqual(compacting.count, 2, language.fileToken)
            XCTAssertFalse(compacting.contains(where: \.isEmpty))
            XCTAssertFalse(L10nKey.removeConfirmBody.template(language).contains("\n"))
        }
        XCTAssertEqual(L10nKey.removeConfirmBody.template(.en).components(separatedBy: "\n").count, 1)
    }

    /// The header letters the name in two fixed parts, so it never breaks across lines.
    func testTheProductNameIsLetteredInTwoParts() {
        for language in L10nLanguage.allCases {
            let words = Wordmark.split(L10nKey.productName.template(language))
            XCTAssertEqual(words.lead, "CC-", language.fileToken)
            XCTAssertEqual(words.rest, "Relay", language.fileToken)
        }
    }

    /// The wordmark's face ships beside its licence, in the folder the app's Info.plist activates.
    func testTheWordmarkFaceShipsWithItsLicence() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: TestFonts.folder.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(Set(files), ["DynaPuff-Bold.ttf", "OFL.txt"])
        let plist = TestFonts.folder.deletingLastPathComponent().appendingPathComponent("Info.plist.template")
        XCTAssertTrue(try String(contentsOf: plist, encoding: .utf8).contains("<key>ATSApplicationFontsPath</key>\n\t<string>Fonts</string>"))
        XCTAssertEqual(NSFont(name: try XCTUnwrap(TextRole.headerTitle.bundledFace), size: 12)?.familyName, "DynaPuff")
    }

    func testResultCopyFitsHeroAndBanner() throws {
        let hanzi = "甲乙丙丁戊己庚辛壬癸甲乙丙丁戊己庚辛壬癸"
        let latin = "AbcdefghijAbcdefghij"
        XCTAssertEqual(hanzi.count, Metrics.maxNameCharacters)
        XCTAssertEqual(latin.count, Metrics.maxNameCharacters)
        let hero = try ProfileFolder("HeroAcct")
        let tile = try ProfileFolder("TileAcct")
        let warnings = everyWarning()
        let reasons = everyReason()

        for language in L10nLanguage.allCases {
            for name in [hanzi, latin] {
                for warning in warnings {
                    try expectResult(
                        .switched(to: hero, warnings: [warning]),
                        language: language, hero: hero, tile: tile, heroName: name, tileName: name,
                        onHero: true, label: "switch hero \(warning) \(language.fileToken)"
                    )
                    try expectResult(
                        .switched(to: tile, warnings: [warning]),
                        language: language, hero: hero, tile: tile, heroName: name, tileName: name,
                        onHero: false, label: "switch tile \(warning) \(language.fileToken)"
                    )
                    try expectResult(
                        .added(folder: hero, warnings: [warning]),
                        language: language, hero: hero, tile: tile, heroName: name, tileName: name,
                        onHero: true, label: "add hero \(warning) \(language.fileToken)"
                    )
                    try expectResult(
                        .added(folder: tile, warnings: [warning]),
                        language: language, hero: hero, tile: tile, heroName: name, tileName: name,
                        onHero: false, label: "add tile \(warning) \(language.fileToken)"
                    )
                }
                for bundle in [[OperationWarning](), warnings] {
                    try expectResult(
                        .switched(to: hero, warnings: bundle),
                        language: language, hero: hero, tile: tile, heroName: name, tileName: name,
                        onHero: true, label: "switch bundle \(bundle.count) \(language.fileToken)"
                    )
                    try expectResult(
                        .added(folder: hero, warnings: bundle),
                        language: language, hero: hero, tile: tile, heroName: name, tileName: name,
                        onHero: true, label: "add hero bundle \(bundle.count) \(language.fileToken)"
                    )
                    try expectResult(
                        .added(folder: tile, warnings: bundle),
                        language: language, hero: hero, tile: tile, heroName: name, tileName: name,
                        onHero: false, label: "add bundle \(bundle.count) \(language.fileToken)"
                    )
                }
                for partial in [false, true] {
                    try expectResult(
                        .removed(folder: hero, partialCleanup: partial),
                        language: language, hero: hero, tile: tile, heroName: name, tileName: name,
                        onHero: true, label: "remove hero \(partial)"
                    )
                    try expectResult(
                        .removed(folder: tile, partialCleanup: partial),
                        language: language, hero: hero, tile: tile, heroName: name, tileName: name,
                        onHero: false, label: "remove tile \(partial)"
                    )
                    try expectResult(
                        .removed(folder: tile, partialCleanup: partial),
                        language: language, hero: hero, tile: tile, heroName: name, tileName: name,
                        includeTile: false, known: [tile.name: name], onHero: false,
                        label: "remove gone \(partial)"
                    )
                }
                for reason in reasons {
                    try expectFailure(reason, language: language, hero: hero, tile: tile, name: name)
                }
            }
        }

        let current = try mapped(
            language: .zhHans, hero: hero, tile: tile, heroName: "204", tileName: "201",
            outcome: .switched(to: hero, warnings: [.sessionsNotSynced(count: 3)])
        )
        XCTAssertEqual(current.current?.result?.text, "已切换，但有 3 个会话没能同步")
        let clean = try mapped(
            language: .en, hero: hero, tile: tile, heroName: "204", tileName: "201",
            outcome: .switched(to: hero, warnings: [])
        )
        // A clean switch ends in its dialog, not on the card.
        XCTAssertNil(clean.current?.result)
        XCTAssertEqual(clean.switchDialog?.phase, .done)
        let tokens = try mapped(
            language: .zhHans, hero: hero, tile: tile, heroName: "204", tileName: "201",
            outcome: .switched(to: hero, warnings: [.notCompactedFirst])
        )
        XCTAssertEqual(tokens.current?.result?.text, "已切换，但对话没能先压缩")
        let returned = try mapped(
            language: .en, hero: hero, tile: tile, heroName: "204", tileName: "201",
            outcome: .failed(operation: .switchTo(tile), reason: .returnedToPreviousAccount)
        )
        XCTAssertNil(returned.current?.result)
        XCTAssertNil(returned.others.first { $0.id == tile.name }?.result)
        XCTAssertTrue(returned.banners.isEmpty)
        XCTAssertEqual(returned.switchDialog?.phase, .failed(failedStep: 2, message: "201 didn't open; back on 204."))
    }

    private func expectFailure(
        _ reason: FailureReason,
        language: L10nLanguage,
        hero: ProfileFolder,
        tile: ProfileFolder,
        name: String
    ) throws {
        let operations: [FailedOperation] = [
            .switchTo(tile),
            .addAccount,
            .remove(hero),
            .remove(tile),
            .autoCorrect,
            .historyImport(hero),
            .historyImport(tile),
        ]
        for operation in operations {
            switch operation {
            case .switchTo, .addAccount, .remove, .autoCorrect, .historyImport:
                break
            }
            let onHero: Bool
            switch operation {
            case .remove(let folder), .historyImport(let folder):
                onHero = folder == hero
            case .autoCorrect:
                onHero = true
            case .switchTo, .addAccount:
                onHero = false
            }
            try expectResult(
                .failed(operation: operation, reason: reason),
                language: language, hero: hero, tile: tile, heroName: name, tileName: name,
                onHero: onHero, label: "\(operation) \(reason) \(language.fileToken)"
            )
        }
        try expectResult(
            .failed(operation: .autoCorrect, reason: reason),
            language: language, hero: hero, tile: tile, heroName: name, tileName: name,
            currentIsNil: true, onHero: false, label: "autocorrect nowhere \(reason)"
        )
    }

    private func expectResult(
        _ outcome: OperationResult.Outcome,
        language: L10nLanguage,
        hero: ProfileFolder,
        tile: ProfileFolder,
        heroName: String,
        tileName: String,
        includeTile: Bool = true,
        known: [String: String] = [:],
        currentIsNil: Bool = false,
        onHero: Bool,
        label: String
    ) throws {
        let state = try mapped(
            language: language,
            hero: hero,
            tile: tile,
            heroName: heroName,
            tileName: tileName,
            includeTile: includeTile,
            currentIsNil: currentIsNil,
            known: known,
            outcome: outcome
        )
        XCTAssertTrue(state.others.allSatisfy { $0.result == nil }, label)
        let card = state.current?.result?.text
        let banners = state.banners.filter { $0.id.hasPrefix("result:") }
        let passing = state.hud.flatMap { $0.id.hasPrefix("result:") ? $0.text : nil }
        if Self.endsInDialog(outcome) {
            // A switch or an added account ends in its own dialog, whose words wrap: done for a moment,
            // or failed until put away.
            XCTAssertNil(card, label)
            XCTAssertTrue(banners.isEmpty, label)
            XCTAssertNil(passing, label)
            XCTAssertTrue(state.switchDialog != nil || state.addDialog != nil, label)
            if case .failed(_, let message)? = state.switchDialog?.phase { XCTAssertFalse(message.isEmpty, label) }
            if case .failed(let message)? = state.addDialog { XCTAssertFalse(message.isEmpty, label) }
        } else if onHero {
            XCTAssertNotNil(card, label)
            XCTAssertTrue(banners.isEmpty, label)
            XCTAssertNil(passing, label)
            measureResult(try XCTUnwrap(card), language: language, names: [heroName, tileName], onHero: true, label: label)
        } else if let passing {
            // A clean result passes in the middle of the panel, on two lines at most.
            XCTAssertNil(card, label)
            XCTAssertTrue(banners.isEmpty, label)
            let words = passing.split(separator: " ").map { SingleLineLayout.width(of: String($0), role: .hud) }
            XCTAssertLessThanOrEqual(words.max() ?? 0, Metrics.hudTextWidth + 0.01, label)
            XCTAssertLessThanOrEqual(SingleLineLayout.width(of: passing, role: .hud), 2 * Metrics.hudTextWidth - 20, label)
        } else {
            XCTAssertNil(card, label)
            XCTAssertEqual(banners.count, 1, label)
            measureResult(
                try XCTUnwrap(banners.first).text,
                language: language,
                names: [heroName, tileName],
                onHero: false,
                label: label
            )
        }
    }

    private static func endsInDialog(_ outcome: OperationResult.Outcome) -> Bool {
        switch outcome {
        case .switched(_, let warnings), .added(_, let warnings):
            warnings.isEmpty
        case .failed(.switchTo, let reason), .failed(.addAccount, let reason):
            reason != .cancelled
        default:
            false
        }
    }

    private func measureResult(
        _ text: String,
        language: L10nLanguage,
        names: [String],
        onHero: Bool,
        label: String
    ) {
        let allowed = resultSentences(language: language, names: names, onHero: onHero)
        for line in text.components(separatedBy: "\n") {
            XCTAssertFalse(line.isEmpty, label)
            let sentences = line.components(separatedBy: " · ")
            for sentence in sentences {
                XCTAssertTrue(
                    allowed.contains(sentence),
                    "\(label) line is not a whole sentence: \(sentence)"
                )
            }
            let width = SingleLineLayout.width(of: line, role: onHero ? .statusLine : .banner)
            let slot = onHero ? ResultLayout.heroTextWidth : Metrics.bannerTextWidth
            XCTAssertLessThanOrEqual(
                width,
                slot + 0.01,
                "\(label) is \(width) pt in a \(slot) pt \(onHero ? "hero" : "banner") line: \(line)"
            )
        }
    }

    /// Every line the panel may draw: a localized sentence or warning, never a clause cut before its name.
    private func resultSentences(language: L10nLanguage, names: [String], onHero: Bool) -> Set<String> {
        func line(_ key: L10nKey, _ parameters: [String: String] = [:]) -> String {
            key.string(in: language, parameters: parameters)
        }
        var sentences: Set<String> = [
            line(.switchedConversationNotOpened),
            line(.warningBackupFailed),
            line(.warningContinuity),
            line(.warningOrganization),
            line(.warningNotCompacted),
            line(.warningWorkContinuation),
            line(.clauseNotCompacted),
            line(.clauseBackup),
            line(.clauseContinuity),
            line(.clauseOrganization),
            line(.clauseConversation),
            line(.reasonCancelled),
            line(.returnedToPreviousAccount),
        ]
        let counts = ["99", "3", "2"]
        if onHero {
            sentences.insert(line(.switched))
            sentences.insert(line(.added))
            sentences.insert(line(.removed))
            sentences.insert(line(.removedCleanup))
            for count in counts {
                sentences.insert(line(.switchedUnsynced, ["n": count]))
                sentences.insert(line(.warningSessions, ["n": count]))
            }
        } else {
            sentences.insert(line(.cleanupUnfinished))
            for name in names {
                sentences.insert(line(.switchedTo, ["name": name]))
                sentences.insert(line(.addedAccount, ["name": name]))
                sentences.insert(line(.removedAccount, ["name": name]))
                sentences.insert(line(.removedPartial, ["name": name]))
                for count in counts {
                    sentences.insert(line(.switchedWithUnsynced, ["name": name, "n": count]))
                    sentences.insert(line(.warningSessions, ["n": count]))
                }
            }
        }
        let reasons = everyReason().map { reasonSentence($0, language: language) }
        let wrappers: [L10nKey] = [
            .switchFailed, .failedAdd, .failedRemove, .failedAutoCorrect, .failedHistoryImport,
        ]
        for reason in reasons {
            for wrapper in wrappers {
                // A localized reason may contain explicitly authored complete sentences on
                // separate lines. Permit those exact lines, never arbitrary wrapped fragments;
                // measureResult still checks each sentence and its full rendered width.
                sentences.formUnion(line(wrapper, ["reason": reason]).components(separatedBy: "\n"))
            }
        }
        return sentences
    }

    private func reasonSentence(_ reason: FailureReason, language: L10nLanguage) -> String {
        let key: L10nKey
        switch reason {
        case .couldNotCloseClaude: key = .failedToCloseClaude
        case .couldNotOpenClaude: key = .failedToOpenClaude
        case .returnedToPreviousAccount: key = .returnedToPreviousAccount
        case .transferFailedReturnedToPreviousAccount: key = .transferFailedReturnedToPreviousAccount
        case .couldNotReadProcesses: key = .reasonCouldNotReadProcesses
        case .targetMissing: key = .reasonTargetMissing
        case .targetUnreadable: key = .reasonTargetUnreadable
        case .couldNotPrepareContinuation: key = .reasonContinuationUnavailable
        case .targetCannotContinue: key = .reasonTargetCannotContinue
        case .transferFailedNotReopened: key = .transferFailedNotReopened
        case .operationInFlight: key = .reasonOperationInFlight
        case .refusedActiveAccount: key = .reasonRefusedActive
        case .refusedLastAccount: key = .reasonRefusedLast
        case .refusedWhileRunning: key = .reasonRefusedRunning
        case .runningStateUnknown: key = .reasonRunningUnknown
        case .signedInAccountDiffers: key = .reasonSignedInDiffers
        case .cancelled: key = .reasonCancelled
        }
        return key.string(in: language)
    }

    private func mapped(
        language: L10nLanguage,
        hero: ProfileFolder,
        tile: ProfileFolder,
        heroName: String,
        tileName: String,
        includeTile: Bool = true,
        currentIsNil: Bool = false,
        known: [String: String] = [:],
        outcome: OperationResult.Outcome
    ) throws -> PanelViewState {
        func row(_ folder: ProfileFolder, _ name: String) -> AccountSummary {
            AccountSummary(
                folder: folder,
                displayName: name,
                status: .signedIn,
                channel: .web
            )
        }
        var accounts = [row(hero, heroName)]
        if includeTile {
            accounts.append(row(tile, tileName))
        }
        let snapshot = CompanionSnapshot(
            accounts: accounts,
            currentFolder: currentIsNil ? nil : hero,
            lastResult: OperationResult(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!,
                finishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                outcome: outcome
            ),
            appVersion: "0.1.0"
        )
        return PanelMapper.map(
            PanelMapInput(
                snapshot: snapshot,
                now: Date(timeIntervalSince1970: 1_700_000_000),
                timeZone: TimeZone(identifier: "Asia/Shanghai") ?? .gmt,
                language: language,
                languageChoice: language == .zhHans ? .zhHans : .en,
                settings: Settings(),
                controlsEnabled: true,
                isSettingsOpen: false,
                renamingFolder: nil,
                removeConfirmFolder: nil,
                dismissedResultIDs: [],
                knownNames: known
            )
        ).panel
    }

    private func everyWarning() -> [OperationWarning] {
        let all: [OperationWarning] = [
            .sessionsNotSynced(count: 99),
            .backupFailed,
            .conversationNotReopened,
            .continuityCaptureFailed,
            .activeOrganizationUnknown,
            .notCompactedFirst,
            .workContinuationUnavailable,
        ]
        for warning in all {
            switch warning {
            case .sessionsNotSynced, .backupFailed, .conversationNotReopened,
                 .continuityCaptureFailed, .activeOrganizationUnknown, .notCompactedFirst, .workContinuationUnavailable:
                break
            }
        }
        return all
    }

    private func everyReason() -> [FailureReason] {
        let all: [FailureReason] = [
            .couldNotCloseClaude,
            .couldNotOpenClaude,
            .returnedToPreviousAccount,
            .transferFailedReturnedToPreviousAccount,
            .couldNotReadProcesses,
            .targetMissing,
            .targetUnreadable,
            .couldNotPrepareContinuation,
            .targetCannotContinue,
            .transferFailedNotReopened,
            .operationInFlight,
            .refusedActiveAccount,
            .refusedLastAccount,
            .refusedWhileRunning,
            .runningStateUnknown,
            .signedInAccountDiffers,
            .cancelled,
        ]
        for reason in all {
            switch reason {
            case .couldNotCloseClaude, .couldNotOpenClaude, .returnedToPreviousAccount, .transferFailedReturnedToPreviousAccount,
                 .couldNotReadProcesses, .targetMissing, .targetUnreadable, .couldNotPrepareContinuation, .targetCannotContinue, .transferFailedNotReopened, .operationInFlight,
                 .refusedActiveAccount, .refusedLastAccount, .refusedWhileRunning,
                 .runningStateUnknown, .signedInAccountDiffers, .cancelled:
                break
            }
        }
        return all
    }

    private func record(_ text: String, name: String, role: TextRole, into margins: inout [(slack: CGFloat, name: String)]) {
        if role.truncates {
            XCTAssertEqual(TextChrome.tailTruncation, .tail, name)
            return
        }
        let lines = role.isParagraph ? text.components(separatedBy: "\n") : [text]
        if !role.isParagraph {
            XCTAssertFalse(text.contains("\n"), "\(name) is a single-line label")
        }
        for (index, line) in lines.enumerated() {
            XCTAssertFalse(line.isEmpty, name)
            let width = SingleLineLayout.width(of: line, role: role)
            XCTAssertLessThanOrEqual(
                width,
                role.width + 0.01,
                "\(name) line \(index) is \(width) pt in a \(role.width) pt slot: \(line)"
            )
            let label = lines.count == 1 ? name : "\(name)#\(index)"
            margins.append((role.width - width, label))
        }
    }

    private func assertTruncates(_ text: String, role: TextRole) {
        XCTAssertTrue(role.truncates)
        XCTAssertGreaterThan(SingleLineLayout.width(of: text, role: role), role.width, text)
    }

    /// The widest weekly reset day either language shows.
    private func widestDay(_ language: L10nLanguage) -> String {
        language == .zhHans ? "12月31日 周三" : "Wed, Dec 31"
    }

    private func render(_ key: L10nKey, _ language: L10nLanguage) -> String {
        key.string(in: language, parameters: parameters(key, language))
    }

    private func parameters(_ key: L10nKey, _ language: L10nLanguage) -> [String: String] {
        switch key {
        case .countdownHours:
            return ["h": "5"]
        case .countdownHoursMinutes:
            return ["h": "4", "m": "59"]
        case .countdownMinutes:
            return ["m": "25"]
        case .resetLine:
            let countdown = L10nKey.countdownHoursMinutes.string(in: language, parameters: ["h": "4", "m": "59"])
            return ["time": "23:59", "countdown": countdown]
        case .switchingTo, .stepOpenClaude, .switchedTo, .taskGuardBody, .duplicateAccount, .duplicateNote,
             .autoCorrected, .removeConfirmTitle, .foundAccount, .addedAccount, .removedAccount, .removedPartial,
             .historyImportInterrupted, .historyImportFailed, .historyImportUnavailable, .compactFirstBody,
             .switchAskTitle, .switchAskBody, .switchFailedTitle, .restoredAccount, .moreActions, .renameTitle,
             .autoSwitchNeedsBypass:
            return ["name": "204"]
        case .switchFailedBack:
            return ["name": "204", "previous": "201"]
        case .switchedWithUnsynced, .watchesStayed:
            return ["name": "204", "n": "3"]
        case .warningSessions, .taskGuardCount, .switchedUnsynced, .nativeRecoveryReasonsVary,
             .nativeRecoveryEndedWithSwitch:
            return ["n": "3"]
        case .nativeRecoveryRoute:
            return ["from": "201", "to": "204"]
        case .quotaCachedFailure:
            return ["reason": L10nKey.quotaTimedOut.string(in: language)]
        case .autoCompacted, .autoCompactedBeforeSwitch:
            return language == .zhHans ? ["before": "81", "after": "7"] : ["before": "812", "after": "74"]
        case .autoCompactedSize, .autoCompactedResumed, .autoCompactedNotResumed, .autoCompactedBeforeSwitchSize:
            return ["before": language == .zhHans ? "81" : "812"]
        case .autoCompactPluginLastSeen:
            return ["time": "18:30"]
        case .autoSwitchNoAccountUntil, .autoSwitchNotReadyUntil:
            return ["time": language == .zhHans ? "12月31日 23:59" : "Dec 31, 23:59"]
        case .switchFailed, .failedAdd, .failedRemove, .failedAutoCorrect, .failedHistoryImport:
            return ["reason": L10nKey.reasonRefusedActive.string(in: language)]
        case .quotaUpdatedAt, .quotaUpdatedShort:
            return ["time": "18:30"]
        case .hudQuotaPartlyUpdated:
            return ["updated": "99", "requested": "100"]
        case .version:
            return ["version": "0.1.0 (5d42a6f+)"]
        case .resetTooltip:
            if language == .zhHans {
                return ["year": "2026", "month": "10", "day": "29", "weekday": "周四", "time": "21:00"]
            }
            return ["year": "2026", "month": "October", "day": "29", "weekday": "Thursday", "time": "21:00"]
        case .recommendResetsOn:
            return ["day": widestDay(language)]
        case .recommendCurrentFiveHourLow:
            return ["percent": "9"]
        case .recommendJoin:
            return ["first": "", "second": ""]
        default:
            return [:]
        }
    }

    private func role(for key: L10nKey) -> TextRole {
        switch key {
        case .productName:
            return .headerTitle
        case .settings:
            return .artTitle
        case .back:
            return .artBack
        case .currentMarker:
            return .badge
        case .language, .ignoredAccounts, .settingsAppearance, .settingsGeneral, .settingsSwitching,
             .settingsCompaction, .settingsOther:
            return .settingsSection
        case .addAccount:
            return .addPill
        case .fiveHour, .weekly:
            return .quotaTitle
        case .notStarted, .resetRefreshing, .countdownHours, .countdownHoursMinutes, .countdownMinutes, .resetLine,
             .quotaRefreshing, .quotaUpdatedShort:
            return .resetLine
        case .signInAgain, .quotaUnavailable, .removingAccount, .switchingBack, .waitingForSignIn:
            return .statusLine
        case .quotaTimedOut, .quotaReadFailed, .quotaRefused, .quotaRateLimited, .quotaPreviousData, .quotaCachedFailure:
            return .stepLabel
        case .channelWeb, .channelAppStore, .channelGooglePlay, .nameEmpty, .nameTooLong:
            return .stepLabel
        case .switchFailed,
             .autoSwitchNoAccount, .autoSwitchNoAccountUntil, .autoSwitchNoOtherSignIn,
             .autoSwitchCommandRunning, .autoSwitchLimitRepeated, .autoSwitchAccountRestricted, .autoSwitchNotReady, .autoSwitchNotReadyUntil,
             .autoSwitchOtherAccounts,
             .autoSwitchLastFailed, .autoSwitchNeedsBypass,
             .autoCorrected, .autoCorrectPaused, .quotaKeychain, .foundAccount,
             .autoCompacted, .autoCompactedSize, .autoCompactedResumed, .autoCompactFailed,
             .autoCompactedNotResumed, .autoCompactNotResumed, .autoCompactFailedNotResumed,
             .autoCompactedBeforeSwitch, .autoCompactedBeforeSwitchSize,
             .historyImportInterrupted, .historyImportFailed, .historyImportUnavailable,
             .warningBackupFailed, .warningContinuity, .warningOrganization, .warningNotCompacted, .warningSessions,
             .warningWorkContinuation, .nativeRecoveryStateContinuing, .nativeRecoveryStateContinued,
             .nativeRecoveryStateBlocked, .nativeRecoveryRoute, .nativeRecoveryReasonsVary, .nativeRecoveryEndedWithSwitch,
             .returnedToPreviousAccount, .transferFailedReturnedToPreviousAccount, .transferFailedNotReopened,
             .clauseBackup, .clauseContinuity, .clauseOrganization, .clauseConversation, .clauseNotCompacted,
             .failedAdd, .failedRemove, .failedAutoCorrect, .failedHistoryImport,
             .added, .removed, .removedPartial, .removedCleanup,
             .cleanupUnfinished, .switched, .switchedUnsynced, .switchedWithUnsynced, .switchedConversationNotOpened:
            return .banner
        case .stepCompactConversation, .stepCloseClaude, .stepSyncSessions, .stepOpenClaude, .stepReopenConversation:
            return .stepRow
        case .quotaUpdatedAt:
            return .tooltip
        case .nativeRecoveryMissingRecord, .nativeRecoveryIncompatibleRuntime,
             .nativeRecoveryBlocked, .nativeRecoveryRuntimeUnavailable, .nativeRecoveryExpired,
             .nativeRecoveryConversationUnavailable, .nativeRecoveryExecutionFailed, .nativeRecoveryIncomplete,
             .watchesStayed, .untitledChat, .claudeNotFound:
            return .banner
        case .failedToCloseClaude, .failedToOpenClaude, .switchFailedBack, .reasonContinuationUnavailable, .reasonTargetCannotContinue,
             .reasonCouldNotReadProcesses, .reasonTargetMissing, .reasonTargetUnreadable, .reasonOperationInFlight,
             .reasonRefusedActive, .reasonRefusedLast, .reasonRefusedRunning,
             .reasonRunningUnknown, .reasonSignedInDiffers, .reasonCancelled:
            return .dialogBody
        case .retry, .dismissNotice, .taskGuardWait, .taskGuardSwitchNow, .compactFirstSkip, .cancel, .cancelAdd,
             .keepBoth, .discardNew, .refreshQuota, .addFound, .dismissFound, .addBack, .quitConfirm,
             .switchAction, .close, .save, .openRecoveryRecords, .installAndTurnOn:
            return .button
        case .rename, .remove:
            return .menuItem
        case .menuRemoveCurrent:
            return .menuNote
        case .moreActions:
            return .menuTitle
        case .taskGuardTitle, .taskGuardCount, .taskGuardUnknown, .compactFirstTitle, .duplicateAccount,
             .removeConfirmTitle, .switchAskTitle, .switchFailedTitle, .switchingTo, .switchedTo,
             .addSignInTitle, .addFailedTitle, .addedAccount, .closingClaude, .openingClaude, .importingHistory,
             .renameTitle, .pluginNeededForAutoSwitch, .pluginNeededForAutoCompact, .pluginInstalling,
             .autoSwitchTurnedOn, .autoCompactTurnedOn, .pluginNotInstalled, .pluginInstalledFeatureOff:
            return .dialogTitle
        case .taskGuardBody, .waitingForTasks, .removeConfirmBody, .compactFirstBody, .compactFirstWaiting,
             .switchAskBody, .dontAskAgain, .addSignInBody, .addImportingBody, .duplicateNote, .newName,
             .pluginNeededBody, .pluginInstallingBody, .pluginReloadConversations, .pluginClaudeCodeMissing,
             .pluginSettingsUnusable, .pluginNotFinished, .autoSwitchNotTurnedOn, .autoCompactNotTurnedOn:
            return .dialogBody
        case .dontAskAgainHint:
            return .dialogHint
        case .launchAtLogin, .autoSync, .autoSwitch, .autoCompact, .openBackups, .confirmSwitch, .pluginUpdateFailed:
            return .settingsLabel
        case .quitApp:
            return .dangerLabel
        case .appearanceSystem, .appearanceLight, .appearanceDark:
            return .segment
        case .languageSystem, .languageZhHans, .languageEnglish:
            return .plainSegment
        case .launchAtLoginDetail, .autoSwitchDetail, .autoSyncDetail, .autoCompactDetail, .openBackupsDetail,
             .confirmSwitchDetail:
            return .settingsDetail
        case .autoCompactPluginLive, .autoCompactPluginLastSeen, .autoCompactPluginNone, .autoCompactOff:
            return .settingsStatus
        case .quitConfirmBody:
            return .settingsNote
        case .version:
            return .version
        case .resetTooltip:
            return .tooltip
        case .hudQuotaUpdated, .hudQuotaPartlyUpdated, .hudQuotaFailed, .hudQuotaNoAccounts,
             .hudVersionCopied, .hudBackupsOpened, .hudBackupsFailed, .hudRecoveryOpened, .hudRecoveryFailed,
             .removedAccount, .restoredAccount, .undo:
            return .hud
        case .recommendedMarker:
            return .badge
        case .recommendResetsOn, .recommendWeekNotStarted, .recommendJoin, .recommendCurrentUnknown,
             .recommendCurrentFiveHourLow, .recommendCurrentWeekSpent:
            return .reason
        case .recommendNoneReady:
            return .section
        case .emptySeatTitle:
            return .seatTitle
        case .emptySeatBody:
            return .seatBody
        }
    }
}
