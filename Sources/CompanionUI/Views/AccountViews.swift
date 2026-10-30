import AppKit
import SwiftUI

struct CurrentAccountCard: View {
    let card: AccountCardState
    let actions: PanelActions
    var locked = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.l10nLanguage) private var language

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        HeroBody(card: card, actions: actions, locked: locked) {
            CardBadge(text: L10nKey.currentMarker.string(in: language), dot: palette.accentClay, color: palette.accentText)
        }
        .padding(Metrics.heroPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                .strokeBorder(palette.accentClay.opacity(Metrics.clayBorderOpacity), lineWidth: Metrics.borderWidth)
        }
        .cardMenu(id: card.id, name: card.name, isCurrent: true, locked: locked,
                  buttonTop: Metrics.heroMoreTop, buttonTrailing: Metrics.heroPadding - 2)
    }
}

/// The card under the current account, laid out the same, with the reason on its last line.
/// A click switches to it, as its tile does.
struct RecommendedCard: View {
    let state: RecommendedCardState
    let actions: PanelActions
    var locked = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.l10nLanguage) private var language

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        let shape = RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
        Button {
            guard !locked else { return }
            actions.selectAccount(state.card.id)
        } label: {
            VStack(alignment: .leading, spacing: Metrics.stackSpacing) {
                HeroBody(card: state.card, actions: actions, locked: locked) {
                    CardBadge(text: L10nKey.recommendedMarker.string(in: language), dot: palette.quotaOK,
                              color: palette.recommendText)
                }
                SlotText(text: state.reason, role: .reason, color: palette.recommendText)
            }
            .padding(Metrics.heroPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.card, in: shape)
            .overlay {
                shape.strokeBorder(palette.quotaOK.opacity(Metrics.recommendBorderOpacity), lineWidth: Metrics.borderWidth)
            }
            .contentShape(shape)
        }
        .buttonStyle(CardButtonStyle(highlights: !locked))
        .cardMenu(id: state.card.id, name: state.card.name, isCurrent: false, locked: locked,
                  buttonTop: Metrics.heroMoreTop, buttonTrailing: Metrics.heroPadding - 2)
    }
}

/// The big card's inside, the same for the current account and the one suggested under it.
private struct HeroBody<Badge: View>: View {
    let card: AccountCardState
    let actions: PanelActions
    let locked: Bool
    @ViewBuilder let badge: () -> Badge

    @Environment(\.colorScheme) private var colorScheme
    @State private var fadingResult = FadingRows<ResultRow>()

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        VStack(alignment: .leading, spacing: Metrics.stackSpacing) {
            HStack(alignment: .top, spacing: Metrics.avatarTextGap) {
                BuddyView(face: card.buddy, side: Metrics.heroAvatar, id: card.id, excited: card.status.isSwitching)
                VStack(alignment: .leading, spacing: Metrics.tightSpacing) {
                    nameRow(palette: palette)
                    if let channel = card.channelText {
                        Text(channel)
                            .font(TextRole.identity.font)
                            .lineLimit(TextChrome.lineLimit)
                            .truncationMode(TextChrome.tailTruncation)
                            .foregroundStyle(palette.textSecondary)
                    }
                    if let note = card.note {
                        CardNote(text: note)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            quotaArea(palette: palette)
            resultLine()
        }
        .fadesRows(ResultRow.rows(card.result), in: $fadingResult)
    }

    private func nameRow(palette: ThemePalette) -> some View {
        HStack(alignment: .center, spacing: Metrics.inlineGap) {
            Text(card.name)
                .font(TextRole.heroName.font)
                .lineLimit(TextChrome.lineLimit)
                .truncationMode(TextChrome.tailTruncation)
                .foregroundStyle(palette.textPrimary)
                .layoutPriority(-1)
                .frame(minWidth: 0, alignment: .leading)
            if let plan = card.planLabel {
                PlanPill(text: plan)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: Metrics.inlineGap)
            badge()
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private func quotaArea(palette: ThemePalette) -> some View {
        switch card.quota {
        case .figures:
            HStack(alignment: .top, spacing: Metrics.gridGap) {
                QuotaBlock(block: card.fiveHour)
                    .frame(maxWidth: .infinity, alignment: .leading)
                QuotaBlock(block: card.weekly)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .loading:
            HStack(alignment: .top, spacing: Metrics.gridGap) {
                QuotaSkeleton(title: card.fiveHour.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                QuotaSkeleton(title: card.weekly.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .notice(let text, let tone):
            if card.status == .signedOut {
                // A signed-out account is signed in again from here.
                Button { actions.selectAccount(card.id) } label: {
                    QuotaNotice(text: text, tone: tone)
                }
                .buttonStyle(PressButtonStyle())
                .disabled(locked)
            } else {
                QuotaNotice(text: text, tone: tone)
            }
        }
    }

    private func resultLine() -> some View {
        let current = ResultRow.rows(card.result)
        return ForEach(fadingResult.rows(current)) { row in
            CardResultText(result: row.line, dismiss: actions.dismissResult)
                .fadingRow(row, of: fadingResult, current: current)
        }
    }
}

struct AccountTile: View {
    let card: AccountCardState
    let actions: PanelActions
    var locked = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var fadingResult = FadingRows<ResultRow>()

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        Button {
            guard !locked else { return }
            actions.selectAccount(card.id)
        } label: {
            VStack(alignment: .leading, spacing: Metrics.tightSpacing) {
                HStack(alignment: .center, spacing: Metrics.avatarTextGap) {
                    BuddyView(face: card.buddy, side: Metrics.tileAvatar, id: card.id, excited: card.status.isSwitching)
                    Text(card.name)
                        .font(TextRole.tileName.font)
                        .lineLimit(TextChrome.lineLimit)
                        .truncationMode(TextChrome.tailTruncation)
                        .foregroundStyle(palette.textPrimary)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    if let plan = card.planLabel {
                        PlanPill(text: plan)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                if let channel = card.channelText {
                    Text(channel)
                        .font(Typography.caption())
                        .lineLimit(TextChrome.lineLimit)
                        .truncationMode(TextChrome.tailTruncation)
                        .foregroundStyle(palette.textTertiary)
                }
                if let note = card.note {
                    CardNote(text: note)
                }
                switch card.quota {
                case .figures:
                    QuotaBlock(block: card.fiveHour)
                    QuotaBlock(block: card.weekly)
                case .loading:
                    QuotaSkeleton(title: card.fiveHour.title)
                    QuotaSkeleton(title: card.weekly.title)
                case .notice(let text, let tone):
                    QuotaNotice(text: text, tone: tone)
                        .padding(.top, Metrics.tightSpacing)
                }
                tileResult()
            }
            .fadesRows(ResultRow.rows(card.result), in: $fadingResult)
            .padding(Metrics.tilePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(CardButtonStyle(highlights: !locked))
        .cardMenu(id: card.id, name: card.name, isCurrent: false, locked: locked,
                  buttonTop: Metrics.tileMoreTop, buttonTrailing: Metrics.tilePadding - 4)
    }

    private func tileResult() -> some View {
        let current = ResultRow.rows(card.result)
        return ForEach(fadingResult.rows(current)) { row in
            CardResultText(result: row.line, dismiss: actions.dismissResult)
                .fadingRow(row, of: fadingResult, current: current)
        }
    }
}

/// A card's result line as one of its `FadingRows`; a card has one at most.
private struct ResultRow: Identifiable, Equatable {
    let line: CardResultLine
    var id: Int { 0 }

    static func rows(_ line: CardResultLine?) -> [ResultRow] {
        line.map { [ResultRow(line: $0)] } ?? []
    }
}

/// Where a quota's bar goes while its first reading is on its way: its title, a dash and grey bars with a
/// light passing over them.
struct QuotaSkeleton: View {
    let title: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.inlineGap) {
                Text(title)
                    .font(TextRole.quotaTitle.font)
                    .lineLimit(TextChrome.lineLimit)
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 0)
                Text(QuotaMark.unavailable)
                    .font(Typography.font(size: Metrics.fontSecondary, weight: .medium, monospacedDigits: true))
                    .foregroundStyle(palette.textTertiary)
            }
            SkeletonBar(height: Metrics.barHeight)
            SkeletonBar(height: 8)
                .frame(width: Metrics.skeletonLineWidth)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A grey rounded bar with a soft light sweeping across it, again and again; still in a picture and under
/// Reduce motion.
private struct SkeletonBar: View {
    let height: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.drawsStill) private var drawsStill
    @Environment(\.motionPaused) private var paused

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        Capsule()
            .fill(palette.barTrack)
            .frame(height: height)
            .overlay {
                if !(reduceMotion || drawsStill) {
                    GeometryReader { proxy in
                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { timeline in
                            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.6), .white.opacity(0)],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: proxy.size.width * 0.6)
                                .offset(x: proxy.size.width * Self.lead(at: timeline.date))
                        }
                    }
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                }
            }
    }

    /// The light's left edge, in bar widths: from just off the left end to past the right one each 1.3 s.
    static func lead(at date: Date) -> Double {
        let pass = 1.3
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: pass) / pass
        return -0.6 + 1.7 * BuddyEase.inOut.apply(phase)
    }
}

/// Why a card has no quota bars: a short line with an icon in a tinted box, yellow when it can't be read
/// just now, red when it needs a new sign-in, clay while it waits for one.
struct QuotaNotice: View {
    let text: String
    let tone: CardNoticeTone

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        let colors: (text: Color, fill: Color, symbol: String) = switch tone {
        case .warning: (palette.quotaMidText, palette.quotaMid.opacity(0.16), "icloud.slash")
        case .failure: (palette.quotaLowText, palette.quotaLow.opacity(0.12), "rectangle.portrait.and.arrow.right")
        case .progress: (palette.accentText, palette.accentClay.opacity(0.12), "hourglass")
        }
        HStack(spacing: Metrics.inlineGap) {
            Image(systemName: colors.symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(TextRole.statusLine.font)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(colors.text)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(colors.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct CardNote: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(TextRole.stepLabel.font)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Theme.palette(for: colorScheme).textSecondary)
    }
}

struct CardResultText: View {
    let result: CardResultLine
    let dismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        let color = color(for: result.tone, palette: palette)
        if result.canDismiss {
            Button(action: dismiss) {
                HStack(alignment: .top, spacing: Metrics.tightSpacing) {
                    resultText(color)
                    Image(systemName: "xmark")
                        .font(.system(size: Metrics.fontCaption, weight: .medium))
                        .foregroundStyle(palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressButtonStyle())
        } else {
            resultText(color)
        }
    }

    private func resultText(_ color: Color) -> some View {
        Text(result.text)
            .font(TextRole.statusLine.font)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for tone: CardResultLine.Tone, palette: ThemePalette) -> Color {
        switch tone {
        case .success: palette.quotaOKText
        case .warning: palette.quotaMidText
        case .failure: palette.quotaLowText
        case .progress: palette.accentText
        }
    }
}

/// The list's place when there is no other account: a dashed seat waiting for one, with the reason to add it.
struct EmptySeat: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.l10nLanguage) private var language

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        let dash = StrokeStyle(lineWidth: 1.5, dash: [Metrics.dashLength, Metrics.dashGap])
        VStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.textTertiary)
                .frame(width: 36, height: 36)
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.dashed, style: dash) }
                .modifier(Swaying())
                .padding(.bottom, Metrics.tightSpacing)
            Text(L10nKey.emptySeatTitle.string(in: language))
                .font(TextRole.seatTitle.font)
                .lineLimit(TextChrome.lineLimit)
                .foregroundStyle(palette.textPrimary)
            SlotText(text: L10nKey.emptySeatBody.string(in: language), role: .seatBody, color: palette.textSecondary,
                     centred: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous).strokeBorder(palette.dashed, style: dash)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Rocks gently from side to side, every 5 s, as a calm buddy does.
private struct Swaying: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.drawsStill) private var drawsStill
    @Environment(\.motionPaused) private var paused

    func body(content: Content) -> some View {
        if reduceMotion || drawsStill {
            content
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { timeline in
                content.rotationEffect(.degrees(BuddyMoves.sway.looping(at: timeline.date.timeIntervalSinceReferenceDate, pace: 1).turn),
                                       anchor: .bottom)
            }
        }
    }
}

/// The add button under the cards, in the middle: a clay capsule with a plus; it rests while something runs.
struct AddAccountButton: View {
    let enabled: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.l10nLanguage) private var language
    @State private var hovering = false

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        Button(action: action) {
            HStack(spacing: Metrics.tightSpacing) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                Text(L10nKey.addAccount.string(in: language))
                    .font(TextRole.addPill.font)
                    .lineLimit(TextChrome.lineLimit)
            }
            .foregroundStyle(palette.accentText)
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: Metrics.addPillHeight)
            .background(palette.accentClay.opacity(enabled && hovering ? 0.22 : 0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(AddPillStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .motion(Motion.touch, value: [hovering, enabled])
        .frame(maxWidth: .infinity)
    }
}

private struct AddPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .motion(Motion.touch, value: configuration.isPressed)
    }
}

extension View {
    /// A card's menu: on a right click, or under its "⋯" button, which shows while the pointer is over the
    /// card, the button has the focus or the menu is open. Nothing opens while the panel is busy.
    func cardMenu(id: String, name: String, isCurrent: Bool, locked: Bool, buttonTop: CGFloat,
                  buttonTrailing: CGFloat) -> some View {
        modifier(CardMenuAccess(id: id, name: name, isCurrent: isCurrent, locked: locked, buttonTop: buttonTop,
                                buttonTrailing: buttonTrailing))
    }
}

private struct ShownMenuKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The account whose menu is open, if any.
    var shownMenuID: String? {
        get { self[ShownMenuKey.self] }
        set { self[ShownMenuKey.self] = newValue }
    }
}

private struct CardMenuAccess: ViewModifier {
    let id: String
    let name: String
    let isCurrent: Bool
    let locked: Bool
    let buttonTop: CGFloat
    let buttonTrailing: CGFloat

    @Environment(\.openCardMenu) private var open
    @Environment(\.shownMenuID) private var shownMenuID
    @Environment(\.l10nLanguage) private var language
    @State private var hovering = false
    @State private var probe = PanelFrameProbe()
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        let shown = !locked && (hovering || focused || shownMenuID == id)
        content
            .environment(\.buddyHovered, hovering)
            .overlay {
                SecondaryClickArea { point in
                    request(CGRect(origin: point, size: .zero), fromButton: false, keyboard: false)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    request(probe.frame ?? .zero, fromButton: true, keyboard: NSApp.currentEvent?.type == .keyDown)
                } label: {
                    MoreDots()
                }
                .buttonStyle(MoreButtonStyle())
                .background(PanelFrameReader(probe: probe))
                .focused($focused)
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .padding(.top, buttonTop)
                .padding(.trailing, buttonTrailing)
                .accessibilityLabel(L10nKey.moreActions.string(in: language, parameters: ["name": name]))
                .motion(Motion.touch, value: shown)
            }
            .onHover { hovering = $0 }
            // VoiceOver reaches the menu from the card itself: the "⋯" shows only under the pointer.
            .accessibilityAction(named: Text(L10nKey.moreActions.string(in: language, parameters: ["name": name]))) {
                request(probe.frame ?? .zero, fromButton: true, keyboard: true)
            }
    }

    private func request(_ anchor: CGRect, fromButton: Bool, keyboard: Bool) {
        guard !locked else { return }
        open?(CardMenuRequest(id: id, name: name, isCurrent: isCurrent, anchor: anchor, fromButton: fromButton,
                              fromKeyboard: keyboard))
    }
}

/// Three dots in a row.
private struct MoreDots: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().frame(width: 3.4, height: 3.4)
            }
        }
        .frame(width: Metrics.moreButtonWidth, height: Metrics.moreButtonHeight)
    }
}

/// The "⋯" button: on the card's colour so it covers what is under it, a grey wash under the pointer.
private struct MoreButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MoreButtonBody(configuration: configuration)
    }
}

private struct MoreButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        configuration.label
            .foregroundStyle(palette.textSecondary)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.gray.opacity(configuration.isPressed ? 0.24 : hovering ? 0.16 : 0))
            }
            .onHover { hovering = $0 }
            .motion(Motion.touch, value: [hovering, configuration.isPressed])
    }
}
