import SwiftUI

/// A dialog's card in the middle of the panel: a picture, words and answers stacked in the middle.
struct DialogCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        VStack(spacing: Metrics.stackSpacing) {
            content()
        }
        .padding(.horizontal, Metrics.dialogPadding)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .frame(width: Metrics.contentWidth)
        .background(palette.card, in: RoundedRectangle(cornerRadius: Metrics.dialogCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.24), radius: 18, y: 14)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// A dialog's answer, full width: filled clay for the main one, red for one that removes, grey words
/// for the rest, red words for one that interrupts. A dialog can pop up right under the pointer: a click
/// in its first moments was meant for what was there before, so it does nothing.
struct DialogButton: View {
    enum Style {
        case primary
        case danger
        case plain
        case dangerText
    }

    let title: String
    var style: Style = .plain
    let armedAt: Date
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        let filled = style == .primary || style == .danger
        Button {
            guard Date().timeIntervalSince(armedAt) >= Metrics.bannerTapDelay else { return }
            action()
        } label: {
            Text(title)
                .font(TextRole.button.font)
                .lineLimit(TextChrome.lineLimit)
                .truncationMode(TextChrome.tailTruncation)
                .foregroundStyle(filled ? Theme.onButton : style == .dangerText ? palette.quotaLowText : palette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.buttonVerticalPadding + 1)
                .background(style == .danger ? Theme.dangerButton : style == .primary ? Theme.primaryButton : .clear,
                            in: RoundedRectangle(cornerRadius: Metrics.settingsRowRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressButtonStyle())
        .keyboardShortcut(filled ? .defaultAction : nil)
    }
}

/// A dialog's picture: a buddy, or a pastel tile with a line symbol, with a small round badge at its corner.
private struct DialogBadge: View {
    enum Mark: Equatable {
        case spinner
        case tick
        case alert
        case cross
        case equal
    }

    let mark: Mark
    let color: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        ZStack {
            Circle().fill(color)
            switch mark {
            case .spinner:
                ActivitySpinner(side: 11)
                    .foregroundStyle(.white)
            case .tick:
                TickMark()
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 11, height: 11)
            case .alert:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
            case .cross:
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
            case .equal:
                Image(systemName: "equal")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 19, height: 19)
        .overlay { Circle().strokeBorder(palette.card, lineWidth: 2) }
        .popsIn(key: mark)
    }
}

/// A rounded pastel square with a line symbol, for a dialog about one account.
private struct DialogTile: View {
    let colors: (UInt32, UInt32)
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Color(hex: colors.1))
            .frame(width: Metrics.dialogIcon, height: Metrics.dialogIcon)
            .background(Color(hex: colors.0), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Something the dialog is waiting for, with a turning arc.
private struct DialogWaiting: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        HStack(spacing: Metrics.inlineGap) {
            ActivitySpinner()
                .foregroundStyle(palette.accentText)
            Text(text)
                .font(TextRole.dialogBody.font)
                .lineLimit(TextChrome.lineLimit)
                .foregroundStyle(palette.accentText)
        }
        .padding(.vertical, 6)
    }
}

/// A small box that ticks, and its words; the whole row toggles it.
private struct DialogCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: Metrics.inlineGap) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOn ? palette.accentClay : .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(isOn ? palette.accentClay : palette.textTertiary, lineWidth: 1.2)
                    }
                    .overlay {
                        if isOn {
                            TickMark()
                                .stroke(.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                                .frame(width: 11, height: 11)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .frame(width: 14, height: 14)
                Text(title)
                    .font(TextRole.dialogBody.font)
                    .lineLimit(TextChrome.lineLimit)
                    .foregroundStyle(palette.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressButtonStyle())
        .motion(Motion.bounce, value: isOn)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "1" : "0")
    }
}

/// Three dots that bounce in turn, from the account in use to the one switched to; still when it stops.
private struct RunningDots: View {
    let running: Bool
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.drawsStill) private var drawsStill
    @Environment(\.motionPaused) private var paused

    var body: some View {
        let moving = running && !(reduceMotion || drawsStill)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving || paused)) { timeline in
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let lift = moving ? Self.lift(at: timeline.date, delay: Double(index) * 0.15) : (0.0, 1.0)
                    Circle()
                        .fill(color)
                        .frame(width: 5, height: 5)
                        .opacity(lift.1)
                        .offset(y: -lift.0)
                }
            }
        }
        .motion(Motion.fade, value: color)
        .accessibilityHidden(true)
    }

    /// Each dot rises 3 pt and brightens, then settles, over 0.9 s.
    static func lift(at date: Date, delay: Double) -> (Double, Double) {
        let turn = 0.9
        let phase = (date.timeIntervalSinceReferenceDate - delay).truncatingRemainder(dividingBy: turn) / turn
        let up = phase < 0.4 ? phase / 0.4 : max(0, 1 - (phase - 0.4) / 0.6)
        let eased = BuddyEase.inOut.apply(up)
        return (3 * eased, 0.25 + 0.75 * eased)
    }
}

/// A switch from the question to its end, in one dialog: the account in use and the one switched to side
/// by side, dots running between them, then the question, the Code tasks still running, the long chat
/// being compacted first, or the four steps ticking off. Done: a tick on the new buddy, which perks up,
/// and the dialog goes. Failed: the step that failed crossed out, the new buddy sighs, and a retry.
struct SwitchDialog: View {
    let state: SwitchDialogState
    let actions: PanelActions

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.l10nLanguage) private var language
    @State private var armedAt = Date()
    @State private var stopAsking = false
    @State private var cueCount = 0
    @State private var cue: BuddyCue?

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        DialogCard {
            pair(palette)
                .padding(.bottom, 2)
            SlotText(text: title, role: .dialogTitle, color: palette.textPrimary, centred: true)
            content(palette)
        }
        .dialogKeys {
            switch state.phase {
            case .asking: actions.cancelSwitchQuestion()
            case .failed: actions.closeSwitchResult()
            case .taskGuard: actions.cancelTaskGuard()
            default: return .ignored
            }
            return .handled
        }
        .onChange(of: endingKind, initial: true) { _, kind in
            guard let kind else { return }
            cueCount += 1
            cue = BuddyCue(kind: kind, serial: cueCount)
        }
        // New answers in the same place wait their moment too: a second click on "switch" must not
        // land on the task guard's "wait".
        .onChange(of: phaseKind) { armedAt = Date() }
        .motion(Motion.pop, value: phaseKind)
    }

    private enum PhaseKind: Equatable {
        case asking, taskGuard, compacting, running, done, failed
    }

    private var phaseKind: PhaseKind {
        switch state.phase {
        case .asking: .asking
        case .taskGuard: .taskGuard
        case .compacting: .compacting
        case .running: .running
        case .done: .done
        case .failed: .failed
        }
    }

    private var endingKind: BuddyCue.Kind? {
        switch state.phase {
        case .done: .perk
        case .failed: .sigh
        default: nil
        }
    }

    private var title: String {
        let name = ["name": state.targetName]
        return switch state.phase {
        case .asking: L10nKey.switchAskTitle.string(in: language, parameters: name)
        case .taskGuard(let title, _): title
        case .compacting: L10nKey.compactFirstTitle.string(in: language)
        case .running: L10nKey.switchingTo.string(in: language, parameters: name)
        case .done: L10nKey.switchedTo.string(in: language, parameters: name)
        case .failed: L10nKey.switchFailedTitle.string(in: language, parameters: name)
        }
    }

    /// Back on the account in use, its buddy is itself again; while it is left, it fades and shrinks.
    private var sourceFaded: Bool {
        switch state.phase {
        case .running(_, let done): done >= 1
        case .done: true
        default: false
        }
    }

    private var dotsRun: Bool {
        switch state.phase {
        case .running, .compacting: true
        case .taskGuard(_, let waiting): waiting
        default: false
        }
    }

    private func pair(_ palette: ThemePalette) -> some View {
        HStack(spacing: 12) {
            if let source = state.sourceBuddy {
                BuddyView(face: source, side: Metrics.dialogBuddy, id: "dialog:" + (state.sourceName ?? ""))
                    .opacity(sourceFaded ? 0.45 : 1)
                    .scaleEffect(sourceFaded ? 0.88 : 1)
                    .motion(Motion.value, value: sourceFaded)
                RunningDots(running: dotsRun, color: failed ? palette.textTertiary : palette.accentClay)
            }
            BuddyView(face: state.targetBuddy, side: Metrics.dialogBuddy, id: "dialog:" + state.targetID,
                      excited: dotsRun, cue: cue)
                .overlay(alignment: .bottomTrailing) {
                    switch state.phase {
                    case .done:
                        DialogBadge(mark: .tick, color: palette.quotaOK).offset(x: 4, y: 4)
                    case .failed:
                        DialogBadge(mark: .alert, color: palette.quotaLow).offset(x: 4, y: 4)
                    default:
                        EmptyView()
                    }
                }
        }
    }

    private var failed: Bool {
        if case .failed = state.phase { return true }
        return false
    }

    @ViewBuilder
    private func content(_ palette: ThemePalette) -> some View {
        switch state.phase {
        case .asking:
            line(L10nKey.switchAskBody.string(in: language, parameters: ["name": state.targetName]), palette)
            DialogCheckbox(title: L10nKey.dontAskAgain.string(in: language), isOn: $stopAsking)
                .padding(.top, 2)
            if stopAsking {
                Text(L10nKey.dontAskAgainHint.string(in: language))
                    .font(TextRole.dialogHint.font)
                    .lineLimit(TextChrome.lineLimit)
                    .foregroundStyle(palette.textTertiary)
                    .transition(.opacity)
            }
            answers {
                DialogButton(title: L10nKey.switchAction.string(in: language), style: .primary, armedAt: armedAt) {
                    actions.confirmSwitch(stopAsking)
                }
                DialogButton(title: L10nKey.cancel.string(in: language), armedAt: armedAt, action: actions.cancelSwitchQuestion)
            }
        case .taskGuard(_, let waiting):
            line(L10nKey.taskGuardBody.string(in: language, parameters: ["name": state.targetName]), palette)
            answers {
                if waiting {
                    DialogWaiting(text: L10nKey.waitingForTasks.string(in: language))
                } else {
                    DialogButton(title: L10nKey.taskGuardWait.string(in: language), style: .primary, armedAt: armedAt,
                                 action: actions.waitForTasks)
                }
                DialogButton(title: L10nKey.taskGuardSwitchNow.string(in: language), style: .dangerText, armedAt: armedAt,
                             action: actions.switchNow)
                DialogButton(title: L10nKey.cancel.string(in: language), armedAt: armedAt, action: actions.cancelTaskGuard)
            }
        case .compacting:
            line(L10nKey.compactFirstBody.string(in: language, parameters: ["name": state.targetName]), palette)
            DialogWaiting(text: L10nKey.compactFirstWaiting.string(in: language))
            answers {
                DialogButton(title: L10nKey.compactFirstSkip.string(in: language), armedAt: armedAt, action: actions.skipCompaction)
            }
        case .running(_, let done):
            steps(done: done, failedStep: nil, palette)
            bar(done: done, palette: palette, color: palette.accentClay, sheen: true)
        case .done:
            steps(done: Metrics.switchStepCount, failedStep: nil, palette)
            bar(done: Metrics.switchStepCount, palette: palette, color: palette.quotaOK, sheen: false)
        case .failed(let failedStep, let message):
            if let failedStep {
                steps(done: failedStep, failedStep: failedStep, palette)
                bar(done: failedStep, palette: palette, color: palette.quotaLow, sheen: false)
            }
            line(message, palette)
            answers {
                DialogButton(title: L10nKey.retry.string(in: language), style: .primary, armedAt: armedAt, action: actions.retrySwitch)
                DialogButton(title: L10nKey.close.string(in: language), armedAt: armedAt, action: actions.closeSwitchResult)
            }
        }
    }

    private func line(_ text: String, _ palette: ThemePalette) -> some View {
        SlotText(text: text, role: .dialogBody, color: palette.textSecondary, centred: true)
    }

    private func answers<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 2) {
            content()
        }
        .padding(.top, Metrics.tightSpacing)
    }

    /// The four steps: done ones ticked, the one under way turning, a failed one crossed out, the rest waiting.
    /// They sit as a block in the middle, or take the width and truncate when a long name will not fit.
    private func steps(done: Int, failedStep: Int?, _ palette: ThemePalette) -> some View {
        let rows = VStack(alignment: .leading, spacing: 7) {
            ForEach(state.steps.indices, id: \.self) { index in
                let row: StepRow.Kind = if index == failedStep {
                    .failed
                } else if index < done {
                    .done
                } else if index == done, failedStep == nil, !isDone {
                    .now
                } else {
                    .waiting
                }
                StepRow(title: state.steps[index], kind: row)
            }
        }
        return ViewThatFits(in: .horizontal) {
            rows.fixedSize()
            rows.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private var isDone: Bool {
        if case .done = state.phase { return true }
        return false
    }

    private func bar(done: Int, palette: ThemePalette, color: Color, sheen: Bool) -> some View {
        QuotaBar(
            fraction: Double(done) / Double(Metrics.switchStepCount),
            fill: color,
            track: palette.barTrack,
            sheen: sheen ? Self.stepUnderWay(done: done) : nil
        )
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    /// The step under way, as fractions of the bar, where its light passes; none once all are done.
    static func stepUnderWay(done: Int) -> ClosedRange<Double>? {
        guard (0..<Metrics.switchStepCount).contains(done) else { return nil }
        let step = 1 / Double(Metrics.switchStepCount)
        return Double(done) * step...Double(done + 1) * step
    }
}

/// One step of a switch in its dialog.
private struct StepRow: View {
    enum Kind: Equatable {
        case done
        case now
        case failed
        case waiting
    }

    let title: String
    let kind: Kind

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        HStack(spacing: Metrics.inlineGap + 2) {
            ZStack {
                switch kind {
                case .done:
                    Circle().fill(palette.quotaOK)
                        .overlay {
                            TickMark()
                                .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                .frame(width: 9, height: 9)
                        }
                        .popsIn(key: kind)
                case .failed:
                    Circle().fill(palette.quotaLow)
                        .overlay {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .heavy))
                                .foregroundStyle(.white)
                        }
                        .popsIn(key: kind)
                case .now:
                    ActivitySpinner(side: 14)
                        .foregroundStyle(palette.accentClay)
                case .waiting:
                    Circle()
                        .strokeBorder(palette.textTertiary, lineWidth: 1.5)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: 16, height: 16)
            Text(title)
                .font(TextRole.stepRow.font)
                .fontWeight(kind == .now || kind == .failed ? .medium : .regular)
                .lineLimit(TextChrome.lineLimit)
                .truncationMode(TextChrome.tailTruncation)
                .foregroundStyle(color(palette))
        }
        .motion(Motion.fade, value: kind)
    }

    private func color(_ palette: ThemePalette) -> Color {
        switch kind {
        case .done: palette.textSecondary
        case .now: palette.textPrimary
        case .failed: palette.quotaLowText
        case .waiting: palette.textTertiary
        }
    }
}

/// Adding an account, in its dialog: a buddy that waits while Claude closes, the new account signs in and
/// its history comes in; then green with a tick once added, yellow when the account was already in the list,
/// grey when it could not be added.
struct AddDialog: View {
    let state: AddDialogState
    let actions: PanelActions

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.l10nLanguage) private var language
    @State private var armedAt = Date()

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        DialogCard {
            BuddyView(face: face, side: Metrics.dialogIcon, id: "dialog:add", cue: cue)
                .overlay(alignment: .bottomTrailing) {
                    DialogBadge(mark: badge.mark, color: badge.color(palette)).offset(x: 4, y: 4)
                }
                .padding(.bottom, 2)
            SlotText(text: title, role: .dialogTitle, color: palette.textPrimary, centred: true)
            if let body = bodyText {
                SlotText(text: body, role: .dialogBody, color: palette.textSecondary, centred: true)
            }
            answers
        }
        .dialogKeys {
            switch state {
            case .closingClaude, .waitingForSignIn: actions.cancelAdd()
            case .duplicate: actions.discardNewAccount()
            case .failed: actions.closeAddResult()
            default: return .ignored
            }
            return .handled
        }
        .motion(Motion.pop, value: state)
    }

    private var face: BuddyFace {
        switch state {
        case .added: BuddyFace(mood: .happy, color: .ok)
        case .duplicate: BuddyFace(mood: .content, color: .mid)
        case .failed: BuddyFace(mood: .tired, color: .empty)
        default: BuddyFace(mood: .content, color: .fair)
        }
    }

    private var cue: BuddyCue? {
        switch state {
        case .added: BuddyCue(kind: .perk, serial: 1)
        case .failed: BuddyCue(kind: .sigh, serial: 1)
        default: nil
        }
    }

    private var badge: (mark: DialogBadge.Mark, color: (ThemePalette) -> Color) {
        switch state {
        case .added: (.tick, { $0.quotaOK })
        case .duplicate: (.equal, { $0.quotaMid })
        case .failed: (.cross, { $0.textTertiary })
        default: (.spinner, { $0.accentClay })
        }
    }

    private var title: String {
        switch state {
        case .closingClaude: L10nKey.closingClaude.string(in: language)
        case .waitingForSignIn: L10nKey.addSignInTitle.string(in: language)
        case .importingHistory: L10nKey.importingHistory.string(in: language)
        case .openingClaude: L10nKey.openingClaude.string(in: language)
        case .added(let name, _): L10nKey.addedAccount.string(in: language, parameters: ["name": name])
        case .duplicate(let name): L10nKey.duplicateAccount.string(in: language, parameters: ["name": name])
        case .failed: L10nKey.addFailedTitle.string(in: language)
        }
    }

    private var bodyText: String? {
        switch state {
        case .closingClaude, .waitingForSignIn: L10nKey.addSignInBody.string(in: language)
        case .importingHistory: L10nKey.addImportingBody.string(in: language)
        case .openingClaude: nil
        case .added(_, let detail): detail
        case .duplicate(let name): L10nKey.duplicateNote.string(in: language, parameters: ["name": name])
        case .failed(let message): message
        }
    }

    @ViewBuilder
    private var answers: some View {
        switch state {
        case .closingClaude, .waitingForSignIn:
            DialogButton(title: L10nKey.cancelAdd.string(in: language), armedAt: armedAt, action: actions.cancelAdd)
                .padding(.top, Metrics.tightSpacing)
        case .duplicate:
            VStack(spacing: 2) {
                DialogButton(title: L10nKey.keepBoth.string(in: language), style: .primary, armedAt: armedAt,
                             action: actions.keepBothAccounts)
                DialogButton(title: L10nKey.discardNew.string(in: language), style: .dangerText, armedAt: armedAt,
                             action: actions.discardNewAccount)
            }
            .padding(.top, Metrics.tightSpacing)
        case .failed:
            VStack(spacing: 2) {
                DialogButton(title: L10nKey.retry.string(in: language), style: .primary, armedAt: armedAt, action: actions.retryAdd)
                DialogButton(title: L10nKey.close.string(in: language), armedAt: armedAt, action: actions.closeAddResult)
            }
            .padding(.top, Metrics.tightSpacing)
        case .importingHistory, .openingClaude, .added:
            Color.clear.frame(height: Metrics.tightSpacing)
        }
    }
}

/// A new name for an account: the field takes the focus with the name selected; Return saves, Esc cancels.
/// Empty or longer than 20 characters says so under the field.
struct RenameDialog: View {
    let state: RenameDialogState
    let actions: PanelActions

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.l10nLanguage) private var language
    @Environment(\.drawsStill) private var drawsStill
    @State private var draft: String
    @State private var problem: NameCheck.Problem?
    @State private var armedAt = Date()
    @FocusState private var focused: Bool

    init(state: RenameDialogState, actions: PanelActions) {
        self.state = state
        self.actions = actions
        _draft = State(initialValue: state.name)
    }

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        DialogCard {
            DialogTile(colors: PaletteHex.tileCompact, symbol: "pencil")
                .padding(.bottom, 2)
            SlotText(text: L10nKey.renameTitle.string(in: language, parameters: ["name": state.name]),
                     role: .dialogTitle, color: palette.textPrimary, centred: true)
            TextField("", text: $draft, prompt: Text(L10nKey.newName.string(in: language)))
                .textFieldStyle(.plain)
                .font(Typography.tileName())
                .multilineTextAlignment(.center)
                .lineLimit(TextChrome.lineLimit)
                .focused($focused)
                .onSubmit(save)
                .onExitCommand(perform: { actions.cancelRename(state.id) })
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(palette.panel, in: RoundedRectangle(cornerRadius: Metrics.settingsRowRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.settingsRowRadius, style: .continuous)
                        .strokeBorder(problem == nil ? palette.hairline : palette.quotaLow, lineWidth: Metrics.borderWidth)
                }
                .accessibilityLabel(L10nKey.newName.string(in: language))
                .onChange(of: draft) { _, draft in
                    if problem != nil { problem = NameCheck.problem(in: draft) }
                }
            if let problem {
                Text(NameCheck.message(for: problem, language: language))
                    .font(TextRole.dialogHint.font)
                    .lineLimit(TextChrome.lineLimit)
                    .foregroundStyle(palette.quotaLowText)
                    .transition(.opacity)
            }
            VStack(spacing: 2) {
                DialogButton(title: L10nKey.save.string(in: language), style: .primary, armedAt: armedAt, action: save)
                DialogButton(title: L10nKey.cancel.string(in: language), armedAt: armedAt) { actions.cancelRename(state.id) }
            }
            .padding(.top, Metrics.tightSpacing)
        }
        .motion(Motion.fade, value: problem)
        // The field can take the keyboard only once it is in the window, a moment after it appears. A
        // picture, or the panel's unseen copy for its height, never takes it.
        .task {
            guard !drawsStill else { return }
            try? await Task.sleep(for: .milliseconds(80))
            focused = true
        }
    }

    private func save() {
        if let found = NameCheck.problem(in: draft) {
            problem = found
            return
        }
        actions.rename(state.id, draft.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Removing an account asks first: its folder goes to the archive, not away.
struct RemoveDialog: View {
    let state: RemoveDialogState
    let actions: PanelActions

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.l10nLanguage) private var language
    @State private var armedAt = Date()

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        DialogCard {
            DialogTile(colors: PaletteHex.tileQuit, symbol: "archivebox")
                .padding(.bottom, 2)
            SlotText(text: L10nKey.removeConfirmTitle.string(in: language, parameters: ["name": state.name]),
                     role: .dialogTitle, color: palette.textPrimary, centred: true)
            SlotText(text: L10nKey.removeConfirmBody.string(in: language), role: .dialogBody, color: palette.textSecondary,
                     centred: true)
            VStack(spacing: 2) {
                DialogButton(title: L10nKey.remove.string(in: language), style: .danger, armedAt: armedAt,
                             action: actions.confirmRemove)
                DialogButton(title: L10nKey.cancel.string(in: language), armedAt: armedAt, action: actions.dismissSheet)
            }
            .padding(.top, Metrics.tightSpacing)
        }
        .dialogKeys {
            actions.dismissSheet()
            return .handled
        }
    }
}

/// Turning on a feature that needs the plugin while it is missing: what installing changes, the install under
/// way, and how it went. Closing it while it asks or after a failure leaves the feature off.
struct PluginDialog: View {
    let state: PluginDialogState
    let actions: PanelActions

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.l10nLanguage) private var language
    @State private var armedAt = Date()

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        DialogCard {
            DialogTile(colors: PaletteHex.tileCompact, symbol: "puzzlepiece.extension")
                .overlay(alignment: .bottomTrailing) {
                    if let badge {
                        DialogBadge(mark: badge.mark, color: badge.color(palette)).offset(x: 4, y: 4)
                    }
                }
                .padding(.bottom, 2)
            SlotText(text: text(title), role: .dialogTitle, color: palette.textPrimary, centred: true)
            SlotText(text: text(bodyText), role: .dialogBody, color: palette.textSecondary, centred: true)
            answers
        }
        .dialogKeys {
            guard state.phase != .installing else { return .ignored }
            actions.closePluginDialog()
            return .handled
        }
        .motion(Motion.pop, value: state)
    }

    private func text(_ key: L10nKey) -> String { key.string(in: language) }

    private var badge: (mark: DialogBadge.Mark, color: (ThemePalette) -> Color)? {
        switch state.phase {
        case .asking: nil
        case .installing: (.spinner, { $0.accentClay })
        case .done: (.tick, { $0.quotaOK })
        case .installedButOff, .failed: (.cross, { $0.textTertiary })
        }
    }

    private var title: L10nKey {
        switch (state.phase, state.feature) {
        case (.asking, .autoSwitch): .pluginNeededForAutoSwitch
        case (.asking, .autoCompact): .pluginNeededForAutoCompact
        case (.installing, _): .pluginInstalling
        case (.done, .autoSwitch): .autoSwitchTurnedOn
        case (.done, .autoCompact): .autoCompactTurnedOn
        case (.installedButOff, _): .pluginInstalledFeatureOff
        case (.failed, _): .pluginNotInstalled
        }
    }

    private var bodyText: L10nKey {
        switch state.phase {
        case .asking: .pluginNeededBody
        case .installing: .pluginInstallingBody
        case .done: .pluginReloadConversations
        case .installedButOff: state.feature == .autoSwitch ? .autoSwitchNotTurnedOn : .autoCompactNotTurnedOn
        case .failed(.claudeCodeMissing): .pluginClaudeCodeMissing
        case .failed(.settingsUnusable): .pluginSettingsUnusable
        case .failed(.notFinished): .pluginNotFinished
        }
    }

    @ViewBuilder
    private var answers: some View {
        switch state.phase {
        case .asking:
            VStack(spacing: 2) {
                DialogButton(title: text(.installAndTurnOn), style: .primary, armedAt: armedAt, action: actions.installPlugin)
                DialogButton(title: text(.cancel), armedAt: armedAt, action: actions.closePluginDialog)
            }
            .padding(.top, Metrics.tightSpacing)
        case .installing:
            Color.clear.frame(height: Metrics.tightSpacing)
        case .done, .installedButOff:
            DialogButton(title: text(.dismissNotice), style: .primary, armedAt: armedAt, action: actions.closePluginDialog)
                .padding(.top, Metrics.tightSpacing)
        case .failed:
            VStack(spacing: 2) {
                DialogButton(title: text(.retry), style: .primary, armedAt: armedAt, action: actions.installPlugin)
                DialogButton(title: text(.close), armedAt: armedAt, action: actions.closePluginDialog)
            }
            .padding(.top, Metrics.tightSpacing)
        }
    }
}

extension View {
    /// Takes the keyboard when the dialog appears, so Esc answers `escape`; Return presses its main button.
    func dialogKeys(escape: @escaping () -> KeyPress.Result) -> some View {
        modifier(DialogKeys(escape: escape))
    }

    /// Pops in from nothing with a little overshoot each time `key` changes to what shows it.
    func popsIn<Key: Equatable>(key: Key) -> some View {
        modifier(PopsIn(key: key))
    }
}

private struct PopsIn<Key: Equatable>: ViewModifier {
    let key: Key

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.drawsStill) private var drawsStill
    @State private var shown = false

    func body(content: Content) -> some View {
        let still = reduceMotion || drawsStill
        content
            .scaleEffect(shown || still ? 1 : 0.01)
            .onAppear {
                guard !still else { return }
                withAnimation(Motion.bounce) { shown = true }
            }
            .onChange(of: key) { _, _ in
                guard !still else { return }
                shown = false
                withAnimation(Motion.bounce) { shown = true }
            }
    }
}

private struct DialogKeys: ViewModifier {
    let escape: () -> KeyPress.Result

    @Environment(\.drawsStill) private var drawsStill
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.escape) { escape() }
            // A picture, or the panel's unseen copy for its height, never takes the keyboard.
            .onAppear { if !drawsStill { focused = true } }
    }
}
