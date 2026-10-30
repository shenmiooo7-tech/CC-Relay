import SwiftUI

/// A notice in a card in the middle of the panel, over a dimmed page: a picture of what it is about,
/// its words and its answers, the main one filled. It pops in; the next notice shows once it goes.
struct NoticeDialog: View {
    let banner: BannerState
    let actions: PanelActions

    @Environment(\.colorScheme) private var colorScheme
    @State private var shownAt = Date.distantPast
    @State private var detailsHeight: CGFloat = 0

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        VStack(spacing: Metrics.stackSpacing) {
            NoticeIcon(kind: banner.kind)
            SlotText(text: banner.text, role: .banner, color: palette.textPrimary, centred: true)
            if !banner.details.isEmpty {
                // As tall as its lines, scrolling only past 180 points.
                ScrollView {
                    details(palette)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: DetailsHeight.self, value: proxy.size.height)
                        })
                }
                .frame(height: min(max(detailsHeight, 1), 180))
                .onPreferenceChange(DetailsHeight.self) { height in
                    MainActor.assumeIsolated { detailsHeight = height }
                }
            }
            if let feedback = banner.actionFeedback {
                SlotText(text: feedback, role: .banner, color: palette.textSecondary, centred: true)
            }
            VStack(spacing: 2) {
                if let title = banner.actionTitle {
                    answer(title, filled: true, enabled: banner.actionEnabled) { actions.bannerAction(banner.id) }
                }
                if let title = banner.secondaryActionTitle {
                    answer(title, filled: false, enabled: true) { actions.bannerSecondaryAction(banner.id) }
                }
                if let title = banner.closeTitle {
                    answer(title, filled: banner.actionTitle == nil, enabled: true) { actions.closeNotice(banner.id) }
                }
            }
            .padding(.top, Metrics.tightSpacing)
        }
        .padding(.horizontal, Metrics.bannerPadding)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .frame(width: Metrics.contentWidth)
        .background(palette.card, in: RoundedRectangle(cornerRadius: Metrics.dialogCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.24), radius: 18, y: 14)
        .onAppear { shownAt = Date() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func details(_ palette: ThemePalette) -> some View {
        VStack(alignment: .leading, spacing: Metrics.stackSpacing) {
            ForEach(Array(banner.details.enumerated()), id: \.offset) { _, detail in
                Text(detail)
                    .font(TextRole.banner.font)
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    /// A dialog can pop up right under the pointer: a click that lands in its first moments was meant
    /// for what was there before, so it does nothing.
    private func answer(_ title: String, filled: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        let palette = Theme.palette(for: colorScheme)
        return Button {
            guard Date().timeIntervalSince(shownAt) >= Metrics.bannerTapDelay else { return }
            action()
        } label: {
            Text(title)
                .font(TextRole.button.font)
                .lineLimit(TextChrome.lineLimit)
                .truncationMode(TextChrome.tailTruncation)
                .foregroundStyle(filled ? Theme.onButton : palette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.buttonVerticalPadding + 1)
                .background(filled ? Theme.primaryButton : .clear,
                            in: RoundedRectangle(cornerRadius: Metrics.settingsRowRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// What a notice is about, drawn above its words: a new account is a buddy with a plus, a switch back
/// a turning arrow, something to look at a yellow mark, work still under way three dots, anything
/// else a tick.
private struct NoticeIcon: View {
    let kind: BannerKind

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        Group {
            switch kind {
            case .foundAccount:
                BuddyView(face: BuddyFace(mood: .happy, color: .ok), side: Metrics.dialogIcon)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(palette.accentClay, in: Circle())
                            .overlay { Circle().strokeBorder(palette.card, lineWidth: 2) }
                            .offset(x: 4, y: 4)
                    }
            case .autoCorrected:
                symbol("arrow.uturn.backward", tint: palette.quotaOK)
            case .autoCorrectPaused, .warning, .quotaKeychain, .historyImport:
                symbol("exclamationmark", tint: palette.quotaMid)
            case .inProgress:
                // Three dots carry less ink than the other marks: drawn larger, they weigh the same.
                symbol("ellipsis", tint: palette.quotaOK, size: 24)
            case .neutral:
                symbol("checkmark", tint: palette.quotaOK)
            }
        }
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String, tint: Color, size: CGFloat = 18) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: Metrics.dialogIcon, height: Metrics.dialogIcon)
            .background(tint.opacity(0.16), in: Circle())
    }
}

/// The natural height of a notice's detail lines.
private struct DetailsHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
