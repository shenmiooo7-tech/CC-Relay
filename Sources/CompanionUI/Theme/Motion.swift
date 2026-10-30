import SwiftUI

/// Every animation in the panel, short and quiet. With "Reduce motion" on in macOS nothing slides,
/// fades, scales or turns: changes show at once.
enum Motion {
    /// Hover outlines and presses.
    static let touch = Animation.easeOut(duration: 0.15)
    /// Banners and result lines that come and go.
    static let fadeDuration = 0.22
    static let fade = Animation.easeOut(duration: fadeDuration)
    /// A sheet rising from the bottom, the settings page coming in.
    static let slide = Animation.spring(response: 0.32, dampingFraction: 0.9)
    /// Quota bars, numbers and buddies following a new reading, and the switch's progress.
    static let value = Animation.easeOut(duration: 0.45)
    /// The cartoon buttons turning, with a little overshoot.
    static let bounce = Animation.spring(response: 0.5, dampingFraction: 0.55)
    /// A dialog or confirmation popping in.
    static let pop = Animation.spring(response: 0.34, dampingFraction: 0.62)
    /// A settings group rising into place, one after another, `riseStep` apart.
    static let rise = Animation.timingCurve(0.2, 0.9, 0.3, 1, duration: 0.42)
    static let riseStep = 0.04
    /// A switch's knob and a segmented control's highlight moving across.
    static let knob = Animation.spring(response: 0.34, dampingFraction: 0.6)
    static let segment = Animation.spring(response: 0.38, dampingFraction: 0.72)
}

extension View {
    /// `animation(_:value:)`, unless macOS is asked to reduce motion.
    func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// Shows `value` and animates a new one on a pass of its own, after the layout around it has settled.
/// A card that grows in the same moment moves its parts at once, as the panel window takes each new
/// height in one step; only the new value animates.
struct Following<Value: Equatable, Content: View>: View {
    let value: Value
    let animation: Animation
    @ViewBuilder let content: (Value) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Value

    init(_ value: Value, animation: Animation, @ViewBuilder content: @escaping (Value) -> Content) {
        self.value = value
        self.animation = animation
        self.content = content
        _shown = State(initialValue: value)
    }

    var body: some View {
        content(shown)
            .onChange(of: value) { _, value in
                withAnimation(reduceMotion ? nil : animation) { shown = value }
            }
    }
}

/// Rows that come and go without any height animating, as the panel window takes each new height in
/// one step: a row that arrives gets its space at once and fades in; one that leaves fades out where
/// it was and then gives its space up.
struct FadingRows<Row: Identifiable & Equatable> {
    /// What was last on screen, the rows that left still where they were.
    fileprivate var shown: [Row] = []
    fileprivate var leaving: Set<Row.ID> = []
    fileprivate var generation = 0

    /// `current` with the rows that left it kept in their places until they have faded.
    func rows(_ current: [Row]) -> [Row] {
        var rows = current
        for (index, row) in shown.enumerated() where !current.contains(where: { $0.id == row.id }) {
            // After the row it followed, or first.
            let previous = shown[..<index].last { prior in rows.contains { $0.id == prior.id } }
            let place = previous.flatMap { prior in rows.firstIndex { $0.id == prior.id } }.map { $0 + 1 } ?? 0
            rows.insert(row, at: place)
        }
        return rows
    }

    fileprivate func opacity(of row: Row) -> Double {
        leaving.contains(row.id) ? 0 : 1
    }
}

extension View {
    /// Keeps the rows that leave `current` on screen while they fade; on the view that holds them.
    func fadesRows<Row: Identifiable & Equatable>(_ current: [Row], in rows: Binding<FadingRows<Row>>) -> some View {
        modifier(FadesRows(current: current, rows: rows))
    }

    /// One of the rows `fadesRows` keeps.
    func fadingRow<Row: Identifiable & Equatable>(_ row: Row, of rows: FadingRows<Row>, current: [Row]) -> some View {
        let isCurrent = current.contains { $0.id == row.id }
        return opacity(rows.opacity(of: row))
            .allowsHitTesting(isCurrent)
            .accessibilityHidden(!isCurrent)
            .fadesIn()
    }

    /// Fades in when it is added and goes at once when it is removed.
    func fadesIn() -> some View {
        modifier(FadesIn())
    }
}

private struct FadesRows<Row: Identifiable & Equatable>: ViewModifier {
    let current: [Row]
    @Binding var rows: FadingRows<Row>

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onChange(of: current, initial: true) { _, current in
                let shown = rows.rows(current)
                let gone = Set(shown.map(\.id)).subtracting(current.map(\.id))
                rows.generation += 1
                if gone.isEmpty || reduceMotion {
                    rows.shown = current
                    rows.leaving = []
                } else {
                    rows.shown = shown
                    withAnimation(Motion.fade) { rows.leaving = gone }
                }
            }
            // A timer rather than the animation's end: the rows go even while the panel is closed.
            .task(id: rows.generation) {
                guard !rows.leaving.isEmpty else { return }
                try? await Task.sleep(for: .seconds(Motion.fadeDuration))
                guard !Task.isCancelled else { return }
                rows.shown = current
                rows.leaving = []
            }
    }
}

private struct FadesIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(
            reduceMotion ? .identity : .asymmetric(insertion: .opacity.animation(Motion.fade), removal: .identity)
        )
    }
}

/// An arc that turns while something is under way. It stands still in a picture, which
/// ImageRenderer draws, and when macOS is asked to reduce motion. Turned from the clock rather than
/// by a repeating animation, which keeps going once started.
struct ActivitySpinner: View {
    var side: CGFloat = 14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.drawsStill) private var drawsStill
    @Environment(\.motionPaused) private var paused

    var body: some View {
        let moving = !(reduceMotion || drawsStill)
        TimelineView(.animation(paused: !moving || paused)) { timeline in
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: side, height: side)
                .rotationEffect(.degrees(moving ? Self.angle(at: timeline.date) : -40))
        }
    }

    /// Where the arc points at `date`: a full turn every 0.9 s.
    static func angle(at date: Date) -> Double {
        let turn = 0.9
        return -40 + 360 * date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: turn) / turn
    }
}

/// A light passing again and again over the part of a bar still under way, `span` of its width. It is
/// placed from the clock at every frame rather than animated: an animation set up while the bar was
/// empty would keep to that empty part however the bar grew. Not drawn in a picture, which
/// ImageRenderer draws, or when macOS is asked to reduce motion.
struct Sheen: View {
    let span: ClosedRange<Double>
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.drawsStill) private var drawsStill
    @Environment(\.motionPaused) private var paused

    var body: some View {
        if !(reduceMotion || drawsStill) {
            GeometryReader { proxy in
                let width = proxy.size.width * (span.upperBound - span.lowerBound)
                let band = width * 0.6
                TimelineView(.animation(paused: paused)) { timeline in
                    LinearGradient(colors: [color.opacity(0), color.opacity(0.55), color.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: band)
                        .offset(x: Self.lead(at: timeline.date, width: width, band: band))
                        .frame(width: width, alignment: .leading)
                        .clipped()
                }
                .offset(x: proxy.size.width * span.lowerBound)
            }
            .clipShape(Capsule())
            .allowsHitTesting(false)
            .transaction { $0.animation = nil }
        }
    }

    /// Where the light's left edge is at `date`: each 1.2 s pass starts with the light just off the
    /// part's left end and closes with it just off the right one.
    static func lead(at date: Date, width: CGFloat, band: CGFloat) -> CGFloat {
        let pass = 1.2
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: pass) / pass
        return -band + phase * (width + band)
    }
}
