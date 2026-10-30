import SwiftUI

struct QuotaBlock: View {
    let block: QuotaBlockState

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        let fill = palette.quotaColor(block.level)
        VStack(alignment: .leading, spacing: Metrics.tightSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.inlineGap) {
                Text(block.title)
                    .font(TextRole.quotaTitle.font)
                    .lineLimit(TextChrome.lineLimit)
                    .truncationMode(TextChrome.tailTruncation)
                    .foregroundStyle(palette.textSecondary)
                Spacer(minLength: 0)
                Following(block, animation: Motion.value) { shown in
                    Text(shown.percentText ?? "—")
                        .font(Typography.font(size: Metrics.fontSecondary, weight: .medium, monospacedDigits: true))
                        .lineLimit(TextChrome.lineLimit)
                        .foregroundStyle(percentColor(shown, palette))
                        .contentTransition(.numericText(value: Double(shown.remainingPercent ?? 0)))
                        .modifier(RefreshPulse())
                }
            }
            QuotaBar(fraction: block.fillFraction, fill: fill, track: palette.barTrack)
            HStack(alignment: .center, spacing: Metrics.resetSymbolGap) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: Metrics.refreshSymbol, weight: .regular))
                    .frame(width: Metrics.refreshSymbol, height: Metrics.refreshSymbol)
                    .foregroundStyle(palette.textTertiary)
                Text(block.resetLine)
                    .font(TextRole.resetLine.font)
                    .lineLimit(TextChrome.lineLimit)
                    .truncationMode(TextChrome.tailTruncation)
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .help(block.tooltip)
    }

    private func percentColor(_ block: QuotaBlockState, _ palette: ThemePalette) -> Color {
        guard block.remainingPercent != nil else { return palette.textTertiary }
        return palette.quotaTextColor(block.level)
    }
}

/// Pulses a figure while every quota is read from the header, and pops it once when the new figures
/// come in. Still in a picture and under Reduce motion.
private struct RefreshPulse: ViewModifier {
    @Environment(\.quotaRefresh) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.drawsStill) private var drawsStill
    @Environment(\.motionPaused) private var paused
    @State private var pops = 0

    func body(content: Content) -> some View {
        let moving = !(reduceMotion || drawsStill)
        let pulsing = moving && phase == .refreshing
        TimelineView(.animation(minimumInterval: nil, paused: !pulsing || paused)) { timeline in
            content.opacity(pulsing ? Self.pulse(at: timeline.date) : 1)
        }
        .keyframeAnimator(initialValue: 1.0, trigger: pops) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            // A jump, not a fast move: a spring starting from a fast move overshoots wildly.
            MoveKeyframe(1.25)
            SpringKeyframe(1, duration: 0.5, spring: .bouncy)
        }
        .onChange(of: phase) { _, phase in
            if phase == .updated, moving { pops += 1 }
        }
    }

    /// Between full and a third, and back, every 0.9 s.
    static func pulse(at date: Date) -> Double {
        let turn = 0.9
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: turn) / turn
        return 0.65 + 0.35 * cos(phase * 2 * .pi)
    }
}

private struct QuotaRefreshKey: EnvironmentKey {
    static let defaultValue = QuotaRefreshPhase.idle
}

extension EnvironmentValues {
    /// Where a read of every quota from the header is, for the figures on the cards.
    var quotaRefresh: QuotaRefreshPhase {
        get { self[QuotaRefreshKey.self] }
        set { self[QuotaRefreshKey.self] = newValue }
    }
}
