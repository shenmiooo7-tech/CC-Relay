import SwiftUI

struct QuotaBar: View {
    var fraction: Double
    var fill: Color
    var track: Color
    /// The part of the bar, as fractions of its width, that a light passes over: a step under way.
    var sheen: ClosedRange<Double>? = nil

    var body: some View {
        Following(Fill(fraction: fraction, color: fill), animation: Motion.value) { shown in
            GeometryReader { proxy in
                let width = max(0, min(proxy.size.width, proxy.size.width * shown.fraction))
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    Capsule().fill(shown.color).frame(width: width)
                }
            }
        }
        .overlay { if let sheen { Sheen(span: sheen, color: fill) } }
        .frame(height: Metrics.barHeight)
    }

    private struct Fill: Equatable {
        var fraction: Double
        var color: Color
    }
}

/// Plain look, but a press shows. `.plain` gives no feedback at all.
struct PressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? Metrics.pressedOpacity : 1)
            .motion(Motion.touch, value: configuration.isPressed)
    }
}

/// An account or add tile: a clay outline on hover and a press like `PressButtonStyle`.
/// The label must carry the whole tile, so the outline sits on its edge.
struct CardButtonStyle: ButtonStyle {
    var highlights = true

    func makeBody(configuration: Configuration) -> some View {
        CardButtonBody(configuration: configuration, highlights: highlights)
    }
}

private struct CardButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let highlights: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        let shown = highlights && hovering
        let pressed = highlights && configuration.isPressed
        configuration.label
            .environment(\.buddyHovered, hovering)
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(
                        palette.accentClay.opacity(shown ? Metrics.hoverBorderOpacity : 0),
                        lineWidth: Metrics.borderWidth
                    )
            }
            .opacity(pressed ? Metrics.pressedOpacity : 1)
            .scaleEffect(pressed && !reduceMotion ? Metrics.pressedScale : 1)
            .motion(Motion.touch, value: [shown, pressed])
            .onHover { hovering = $0 }
    }
}

/// A plan label like a game's rare card: its colours flowing sideways under a gloss split at the
/// middle, a light rim, a glow, bold white text and a light passing over it now and then. It stands
/// still in a picture, which ImageRenderer draws, and when macOS is asked to reduce motion.
struct PlanPill: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.drawsStill) private var drawsStill
    @Environment(\.motionPaused) private var paused

    var body: some View {
        let style = Theme.plan(PlanTier(label: text) ?? .other)
        let moving = !(reduceMotion || drawsStill)
        Text(text)
            .font(Typography.font(size: Metrics.fontCaption, weight: .bold, monospacedDigits: false))
            .lineLimit(TextChrome.lineLimit)
            .truncationMode(TextChrome.tailTruncation)
            .foregroundStyle(style.text)
            .shadow(color: style.ink, radius: 0, y: 1)
            .padding(.horizontal, Metrics.planPillHorizontalPadding)
            .padding(.vertical, Metrics.planPillVerticalPadding)
            .background { PlanFill(style: style, moving: moving) }
            .overlay { if moving && !paused { PlanShine() } }
            .clipShape(Capsule())
            .overlay {
                Capsule().strokeBorder(style.rim, lineWidth: 1)
                Capsule()
                    .inset(by: 1)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0)],
                                                 startPoint: .top, endPoint: .center), lineWidth: 1)
            }
            .shadow(color: style.glow, radius: 3)
    }
}

/// A plan label's fill: its colours sliding left under a gloss, one turn every 4 s.
private struct PlanFill: View {
    let style: PlanStyle
    let moving: Bool

    @Environment(\.motionPaused) private var paused

    var body: some View {
        GeometryReader { proxy in
            if moving {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { timeline in
                    colours(width: proxy.size.width, at: Self.flow(at: timeline.date))
                }
            } else {
                colours(width: proxy.size.width, at: 0)
            }
        }
        .overlay {
            LinearGradient(stops: [
                .init(color: .white.opacity(0.38), location: 0),
                .init(color: .white.opacity(0.12), location: 0.48),
                .init(color: .black.opacity(0), location: 0.52),
                .init(color: .black.opacity(0.14), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
    }

    /// Two strips of the colours, each twice the label's width, side by side and moved left by `phase` of one.
    private func colours(width: CGFloat, at phase: Double) -> some View {
        let span = width * 2
        let colours = LinearGradient(colors: style.stops, startPoint: .leading, endPoint: .trailing)
        return HStack(spacing: 0) {
            colours.frame(width: span)
            colours.frame(width: span)
        }
        .offset(x: -span * phase)
        .frame(width: width, alignment: .leading)
        .clipped()
    }

    /// How far through its 4 s turn the rainbow is at `date`, from 0 to 1.
    static func flow(at date: Date) -> Double {
        let turn = 4.0
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: turn) / turn
    }
}

/// A slanted light that waits off the label's left end, then sweeps across it, every 3.4 s. Drawn
/// only while it sweeps.
private struct PlanShine: View {
    var body: some View {
        TimelineView(ShineSchedule()) { timeline in
            GeometryReader { proxy in
                LinearGradient(colors: [.white.opacity(0), .white.opacity(0.85), .white.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.45, height: proxy.size.height * 2)
                    .rotationEffect(.degrees(22))
                    .offset(x: proxy.size.width * ShineSchedule.lead(at: timeline.date), y: -proxy.size.height / 2)
            }
        }
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    }
}

/// Frames for `PlanShine`: one when the light comes to rest off the left end, then a frame a display
/// refresh apart only while it sweeps.
struct ShineSchedule: TimelineSchedule {
    static let turn = 3.4
    /// The part of a turn the light waits before it sweeps.
    static let rest = 0.62
    static let frame = 1.0 / 60

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(upcoming: startDate, lowFrequency: mode == .lowFrequency)
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: Date
        let lowFrequency: Bool

        mutating func next() -> Date? {
            let date = upcoming
            let phase = ShineSchedule.phase(at: date)
            let wait = (ShineSchedule.rest - phase) * ShineSchedule.turn
            if lowFrequency {
                upcoming = date + (1 - phase) * ShineSchedule.turn
            } else if wait > ShineSchedule.frame {
                upcoming = date + wait
            } else {
                upcoming = date + ShineSchedule.frame
            }
            return date
        }
    }

    static func phase(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: turn) / turn
    }

    /// The light's left edge at `date`, in label widths: -0.7 while it waits, then easing across to 1.4.
    static func lead(at date: Date) -> Double {
        let phase = phase(at: date)
        guard phase > rest else { return -0.7 }
        let sweep = (phase - rest) / (1 - rest)
        let eased = sweep * sweep * (3 - 2 * sweep)
        return -0.7 + 2.1 * eased
    }
}

/// A dot and a word at the end of a big card's name row: current, suggested, or next.
struct CardBadge: View {
    let text: String
    let dot: Color
    let color: Color

    var body: some View {
        HStack(spacing: Metrics.tightSpacing) {
            Circle()
                .fill(dot)
                .frame(width: Metrics.currentDot, height: Metrics.currentDot)
            Text(text)
                .font(TextRole.badge.font)
                .lineLimit(TextChrome.lineLimit)
                .truncationMode(TextChrome.tailTruncation)
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }
}
