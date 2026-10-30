import SwiftUI
import XCTest
@testable import CompanionUI

@MainActor
final class SheetSizingTests: XCTestCase {
    func testQuotaErrorsAndDuplicateNotesWrapAtTheActualSmallCardWidth() throws {
        for language in L10nLanguage.allCases {
            let baseline = try XCTUnwrap(height(of: QuotaNotice(text: "—", tone: .warning)
                .frame(width: Metrics.tileInnerWidth)))
            for key in [L10nKey.quotaTimedOut, .quotaReadFailed] {
                let notice = QuotaNotice(text: key.string(in: language), tone: .warning)
                    .frame(width: Metrics.tileInnerWidth)
                let noticeHeight = try XCTUnwrap(height(of: notice))
                if language == .en {
                    XCTAssertGreaterThan(noticeHeight, baseline,
                                         "the icon and padding leave too little room for a single English line")
                } else { XCTAssertGreaterThanOrEqual(noticeHeight, baseline) }
            }
            // Any reason takes two lines at most; a rate limit is an hour at most, so it names a clock.
            let twoLines = try XCTUnwrap(height(of: QuotaNotice(text: "—\n—", tone: .warning)
                .frame(width: Metrics.tileInnerWidth)))
            for key in [L10nKey.quotaTimedOut, .quotaReadFailed, .quotaRefused, .quotaRateLimited] {
                let notice = QuotaNotice(text: key.string(in: language, parameters: ["time": "23:59"]), tone: .warning)
                    .frame(width: Metrics.tileInnerWidth)
                XCTAssertLessThanOrEqual(try XCTUnwrap(height(of: notice)), twoLines, "\(key.rawValue) runs past two lines")
            }
            let error = L10nKey.quotaCachedFailure.string(in: language,
                parameters: ["reason": L10nKey.quotaTimedOut.string(in: language)])
            let duplicate = L10nKey.duplicateNote.string(in: language, parameters: ["name": "203"])
            let errorHeight = try XCTUnwrap(height(of: CardNote(text: error).frame(width: Metrics.tileInnerWidth)))
            let shortNoteHeight = try XCTUnwrap(height(of: CardNote(text: L10nKey.quotaPreviousData.string(in: language))
                .frame(width: Metrics.tileInnerWidth)))
            XCTAssertGreaterThan(errorHeight, shortNoteHeight, "the full cached-data warning must wrap")
            let combinedHeight = try XCTUnwrap(height(of: CardNote(text: error + "\n" + duplicate)
                .frame(width: Metrics.tileInnerWidth)))
            XCTAssertGreaterThan(combinedHeight, errorHeight, "the duplicate note must remain visible below the error")
        }
    }

    /// Without account cards the page is short, so the task-guard question is taller than the page under it.
    func testThePanelGrowsToFitADialogTallerThanItsPage() async throws {
        var state = try await FixtureScene.taskGuard.make(.zhHans)
        state.current = nil
        state.recommendation = nil
        state.others = []
        state.banners = []
        var page = state
        page.switchDialog = nil
        let question = try XCTUnwrap(state.switchDialog, "the scene no longer shows the switch's dialog")
        guard case .taskGuard = question.phase else {
            return XCTFail("the scene no longer asks about the running task")
        }
        let dialog = try XCTUnwrap(height(of: SwitchDialog(state: question, actions: .noop)
            .padding(Metrics.panelPadding)
            .environment(\.l10nLanguage, state.language)
            .environment(\.drawsStill, true)))
        let pageHeight = try XCTUnwrap(height(of: PanelView(state: page, actions: .noop)))
        XCTAssertLessThan(pageHeight, dialog, "the scene no longer has a dialog taller than its page")
        let panelHeight = try XCTUnwrap(height(of: PanelView(state: state, actions: .noop)))
        XCTAssertGreaterThanOrEqual(panelHeight, dialog)
    }

    private func height(of view: some View) -> CGFloat? {
        let renderer = ImageRenderer(content: view.environment(\.drawsStill, true))
        renderer.proposedSize = ProposedViewSize(width: Metrics.panelWidth, height: nil)
        renderer.scale = 1
        return renderer.cgImage.map { CGFloat($0.height) }
    }
}
