import SwiftUI

/// "CC-Relay" in bubble letters with the settings title's outline and drop, each part in its own fill.
struct Wordmark: View {
    let title: String

    var body: some View {
        ArtLettering(parts: parts, role: .headerTitle)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }

    private var parts: [(text: String, fill: Color)] {
        let words = Self.split(title)
        let rest = (text: words.rest, fill: Color(hex: PaletteHex.cartoonRefresh))
        guard let lead = words.lead else { return [rest] }
        return [(text: lead, fill: Color(hex: PaletteHex.wordmarkLead)), rest]
    }

    /// The first word with the space or hyphen after it, and the rest. A title of one word is all rest.
    static func split(_ title: String) -> (lead: String?, rest: String) {
        guard let space = title.firstIndex(where: { $0 == " " || $0 == "-" }) else { return (nil, title) }
        let rest = title[title.index(after: space)...]
        guard !rest.isEmpty else { return (nil, title) }
        return (String(title[...space]), String(rest))
    }
}

/// Words lettered like the cartoon icons: rounded and bold, filled in a pastel, outlined in the icons'
/// brown, with a small brown drop under them. Each part of the line can have its own fill.
struct ArtLettering: View {
    let parts: [(text: String, fill: Color)]
    let role: TextRole

    init(text: String, role: TextRole, fill: Color) {
        self.init(parts: [(text: text, fill: fill)], role: role)
    }

    init(parts: [(text: String, fill: Color)], role: TextRole) {
        self.parts = parts
        self.role = role
    }

    var body: some View {
        let ink = Color(hex: PaletteHex.cartoonInk)
        let edge = role.outline
        let corner = edge * 0.73
        let offsets: [CGSize] = [
            CGSize(width: edge, height: 0), CGSize(width: -edge, height: 0),
            CGSize(width: 0, height: edge), CGSize(width: 0, height: -edge),
            CGSize(width: corner, height: corner), CGSize(width: -corner, height: corner),
            CGSize(width: corner, height: -corner), CGSize(width: -corner, height: -corner),
            CGSize(width: 0, height: Metrics.artDrop),
        ]
        ZStack {
            ForEach(offsets.indices, id: \.self) { index in
                letters(ink).offset(offsets[index])
            }
            letters(nil)
        }
        .padding(.horizontal, edge)
        .padding(.top, edge)
        .padding(.bottom, Metrics.artDrop)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.map(\.text).joined())
    }

    /// The whole line in the ink, or each part in its fill.
    private func letters(_ ink: Color?) -> some View {
        parts.reduce(Text(verbatim: "")) { line, part in line + Text(part.text).foregroundStyle(ink ?? part.fill) }
            .font(role.font)
            .tracking(role.tracking)
            .lineLimit(TextChrome.lineLimit)
    }
}

/// The header's buttons and the settings page's back arrow: a drawn icon in a 28 pt square that
/// turns a little on hover and more under a press, with a bounce.
struct CartoonButtonStyle: ButtonStyle {
    var hoverTurn: Double
    var pressTurn: Double

    func makeBody(configuration: Configuration) -> some View {
        CartoonButtonBody(configuration: configuration, hoverTurn: hoverTurn, pressTurn: pressTurn)
    }
}

private struct CartoonButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let hoverTurn: Double
    let pressTurn: Double

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let pressed = isEnabled && configuration.isPressed
        let turn = pressed ? pressTurn : (isEnabled && hovering ? hoverTurn : 0)
        configuration.label
            .rotationEffect(.degrees(turn))
            .scaleEffect(pressed ? 0.9 : 1)
            .frame(width: Metrics.settingsButtonSide, height: Metrics.settingsButtonSide)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
            .motion(Motion.bounce, value: turn)
            .motion(Motion.fade, value: isEnabled)
            .onHover { hovering = $0 }
    }
}

/// A peach gear with a brown outline, a shine on its upper left and a hole the panel shows through.
struct CartoonGear: View {
    var side: CGFloat = Metrics.cartoonIcon

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let hole = Theme.palette(for: colorScheme).panel
        Canvas { context, size in
            context.scaleBy(x: size.width / 24, y: size.height / 24)
            let ink = Color(hex: PaletteHex.cartoonInk)
            let parts = CartoonPaths.gear
            for part in parts {
                context.fill(part, with: .color(ink))
                context.stroke(part, with: .color(ink), style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
            }
            for part in parts {
                context.fill(part, with: .color(Color(hex: PaletteHex.cartoonGear)))
            }
            context.stroke(CartoonPaths.gearShine, with: .color(.white.opacity(0.75)),
                           style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            let hub = Path(ellipseIn: CGRect(x: 9.3, y: 9.3, width: 5.4, height: 5.4))
            context.fill(hub, with: .color(hole))
            context.stroke(hub, with: .color(ink), lineWidth: 1.5)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// A mint arrow going round, outlined in brown. While every quota is read it spins; when the new
/// figures come in it swings back a little and settles. Still in a picture and under Reduce motion.
struct CartoonRefresh: View {
    var phase: QuotaRefreshPhase = .idle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.drawsStill) private var drawsStill
    @Environment(\.motionPaused) private var paused
    @State private var settles = 0

    var body: some View {
        let moving = !(reduceMotion || drawsStill)
        TimelineView(.animation(minimumInterval: nil, paused: !(moving && phase == .refreshing) || paused)) { timeline in
            icon
                .rotationEffect(.degrees(moving && phase == .refreshing ? Self.spin(at: timeline.date) : 0))
        }
        .keyframeAnimator(initialValue: Settle(), trigger: settles) { content, settle in
            content
                .rotationEffect(.degrees(settle.turn))
                .scaleEffect(settle.scale)
        } keyframes: { _ in
            // Jumps, not fast moves: a spring starting from a fast move overshoots wildly.
            KeyframeTrack(\.turn) {
                MoveKeyframe(-50)
                SpringKeyframe(0, duration: 0.5, spring: .bouncy)
            }
            KeyframeTrack(\.scale) {
                MoveKeyframe(1.1)
                SpringKeyframe(1, duration: 0.5, spring: .bouncy)
            }
        }
        .onChange(of: phase) { _, phase in
            if phase == .updated, moving { settles += 1 }
        }
        .accessibilityHidden(true)
    }

    private var icon: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 24, y: size.height / 24)
            let ink = Color(hex: PaletteHex.cartoonInk)
            let mint = Color(hex: PaletteHex.cartoonRefresh)
            context.stroke(CartoonPaths.refreshArc, with: .color(ink), style: StrokeStyle(lineWidth: 5.4, lineCap: .round))
            context.fill(CartoonPaths.refreshHead, with: .color(ink))
            context.stroke(CartoonPaths.refreshHead, with: .color(ink), style: StrokeStyle(lineWidth: 2.6, lineJoin: .round))
            context.stroke(CartoonPaths.refreshArc, with: .color(mint), style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
            context.fill(CartoonPaths.refreshHead, with: .color(mint))
            context.stroke(CartoonPaths.refreshShine, with: .color(.white.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        }
        .frame(width: Metrics.cartoonIcon, height: Metrics.cartoonIcon)
    }

    /// One turn every 0.7 s.
    static func spin(at date: Date) -> Double {
        let turn = 0.7
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: turn) / turn * 360
    }

    private struct Settle {
        var turn: Double = 0
        var scale: Double = 1
    }
}

/// A lavender arrow pointing back, outlined in brown.
struct CartoonBack: View {
    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 24, y: size.height / 24)
            let ink = Color(hex: PaletteHex.cartoonInk)
            context.stroke(CartoonPaths.backArrow, with: .color(ink),
                           style: StrokeStyle(lineWidth: 5.6, lineCap: .round, lineJoin: .round))
            context.stroke(CartoonPaths.backArrow, with: .color(Color(hex: PaletteHex.cartoonBack)),
                           style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
            context.stroke(CartoonPaths.backShine, with: .color(.white.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
        .frame(width: Metrics.cartoonBackIcon, height: Metrics.cartoonBackIcon)
        .accessibilityHidden(true)
    }
}

/// The cartoon icons' outlines in a 24-unit square.
enum CartoonPaths {
    /// Eight teeth around a round body, each filled and outlined on its own so no overlap cancels out.
    static let gear: [Path] = {
        let tooth = Path(roundedRect: CGRect(x: 9.7, y: 1.5, width: 4.6, height: 5.2), cornerRadius: 1.6)
        var parts = (0..<8).map { index in
            let turn = CGAffineTransform(translationX: 12, y: 12)
                .rotated(by: .pi / 4 * CGFloat(index))
                .translatedBy(x: -12, y: -12)
            return tooth.applying(turn)
        }
        parts.append(Path(ellipseIn: CGRect(x: 4.7, y: 4.7, width: 14.6, height: 14.6)))
        return parts
    }()

    static let gearShine: Path = arc(radius: 5, from: 201, to: 247)

    /// Most of a circle, open at the upper right where the arrowhead sits.
    static let refreshArc: Path = arc(radius: 6.5, from: 0, to: 311.3)

    static let refreshHead: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 18.25, y: 8.82))
        path.addLine(to: CGPoint(x: 13.97, y: 8.24))
        path.addLine(to: CGPoint(x: 17.13, y: 4.64))
        path.closeSubpath()
        return path
    }()

    static let refreshShine: Path = arc(radius: 5.4, from: 152, to: 186)

    /// A shaft and a head pointing left.
    static let backArrow: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 18.5, y: 12))
        path.addLine(to: CGPoint(x: 6.5, y: 12))
        path.move(to: CGPoint(x: 11.2, y: 6.6))
        path.addLine(to: CGPoint(x: 5.8, y: 12))
        path.addLine(to: CGPoint(x: 11.2, y: 17.4))
        return path
    }()

    static let backShine: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 12.6, y: 11.35))
        path.addLine(to: CGPoint(x: 17, y: 11.35))
        return path
    }()

    /// Clockwise on screen from `start` to `end` degrees around the square's centre, 0 pointing right.
    private static func arc(radius: CGFloat, from start: Double, to end: Double) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: 12, y: 12), radius: radius,
                    startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        return path
    }
}

/// A short line in the middle of the panel: a clay disc with a tick, or a turning arc while something is
/// under way, and the words, on a card the opposite shade of the panel. It pops in and blocks nothing,
/// apart from its undo button when it has one.
struct HUDView: View {
    let hud: HUDState
    var action: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        VStack(spacing: Metrics.stackSpacing) {
            Circle()
                .fill(palette.accentClay)
                .frame(width: Metrics.hudCheck, height: Metrics.hudCheck)
                .overlay {
                    if hud.busy {
                        ActivitySpinner(side: 16)
                            .foregroundStyle(.white)
                    } else {
                        TickMark()
                            .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .frame(width: 16, height: 16)
                    }
                }
            // As wide as its words, up to the slot the panel leaves it; a result naming an account can
            // take a second line.
            Text(hud.text)
                .font(TextRole.hud.font)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.hudText)
                .fixedSize(horizontal: false, vertical: true)
            if let title = hud.actionTitle {
                Button(action: action) {
                    Text(title)
                        .font(TextRole.hud.font)
                        .fontWeight(.semibold)
                        .lineLimit(TextChrome.lineLimit)
                        .foregroundStyle(palette.hudAction)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressButtonStyle())
                .padding(.top, -4)
                .padding(.bottom, -4)
            }
        }
        .padding(.horizontal, Metrics.hudHorizontalPadding)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(minWidth: 132)
        .background(palette.hudBackground, in: RoundedRectangle(cornerRadius: Metrics.hudCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 10)
        .allowsHitTesting(hud.actionTitle != nil)
        .accessibilityElement(children: .contain)
    }
}

/// A tick in a 16-unit square.
struct TickMark: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 16
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 3.6 * unit, y: rect.minY + 8.4 * unit))
        path.addLine(to: CGPoint(x: rect.minX + 6.6 * unit, y: rect.minY + 11.2 * unit))
        path.addLine(to: CGPoint(x: rect.minX + 12.4 * unit, y: rect.minY + 4.8 * unit))
        return path
    }
}
