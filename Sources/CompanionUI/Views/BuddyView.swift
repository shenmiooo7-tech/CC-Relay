import AppKit
import SwiftUI

/// The account's buddy: one rounded square for every account, its face set by the 5-hour window and its
/// colour by the weekly one. It is alive: it blinks, breathes and moves in a way that shows how awake it
/// is, looks towards the pointer when awake enough, reacts when the pointer comes over its card, makes a
/// move of its own now and then, perks up or sighs when a new reading moves it a level, and hops while a
/// switch heads to it. Drawn on a 36-point design and scaled, so the tile's smaller one draws its lines a
/// little heavier to read the same. It stands still in a picture, which ImageRenderer draws, and when
/// macOS is asked to reduce motion.
struct BuddyView: View {
    let face: BuddyFace
    let side: CGFloat
    /// The account it stands for: it sets the buddy's own rhythm, and the panel picks buddies by it.
    var id = ""
    /// Hops while a switch heads to it.
    var excited = false
    /// A move asked for from outside, played each time a new one comes.
    var cue: BuddyCue?
    /// Square at rest, whatever its mood: the menu bar keeps its icons one size, so there its height does
    /// not show how awake it is.
    var keepsShape = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.drawsStill) private var drawsStill
    @Environment(\.motionPaused) private var paused
    @Environment(\.buddyHovered) private var hovered
    @Environment(\.buddyAct) private var act
    @Environment(\.quotaRefresh) private var refresh
    @State private var life = BuddyLife()

    var body: some View {
        // A canvas clips what it draws, and a buddy hops, springs and turns past its square: it draws with
        // room around it, and takes only its square in the layout.
        let room = side * BuddyArt.room
        let square = CGSize(width: side, height: side)
        Group {
            if reduceMotion || drawsStill {
                Canvas { context, _ in
                    context.translateBy(x: room, y: room)
                    BuddyArt.draw(face: face, skin: Theme.buddy(face.color), line: line, in: &context, size: square,
                                  pose: shaped(.still(face.mood)))
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { timeline in
                    Canvas { context, _ in
                        let now = timeline.date
                        context.translateBy(x: room, y: room)
                        BuddyArt.draw(face: face, skin: life.colours(for: face, at: now), line: line, in: &context, size: square,
                                      pose: shaped(life.pose(face: face, id: id, excited: excited, act: act, at: now)))
                    }
                }
            }
        }
        .frame(width: side + 2 * room, height: side + 2 * room)
        .padding(-room)
        .allowsHitTesting(false)
        .frame(width: side, height: side)
        .background(BuddyProbe(life: life))
        .onChange(of: face, initial: true) { old, new in life.faceChanged(from: old, to: new, at: Date()) }
        .onChange(of: hovered) { _, isOver in
            life.hovered = isOver
            if isOver { life.hoverStarted = Date() }
        }
        .onChange(of: refresh) { _, phase in
            if phase == .updated { life.popStarted = Date() }
        }
        .onChange(of: cue) { _, cue in
            guard let cue else { return }
            life.cue = (cue.move, Date())
        }
        .accessibilityHidden(true)
    }

    private var line: CGFloat { side >= Metrics.heroAvatar ? 1.8 : 2.2 }

    private func shaped(_ pose: BuddyFramePose) -> BuddyFramePose {
        guard keepsShape else { return pose }
        var square = pose
        square.posture = .identity
        return square
    }
}

/// A move asked of a buddy from outside: `serial` tells one asking from the next.
struct BuddyCue: Equatable {
    enum Kind: Equatable {
        case perk
        case sigh
    }

    var kind: Kind
    var serial: Int

    var move: BuddyMove { kind == .perk ? BuddyMoves.perk : BuddyMoves.sigh }
}

/// The panel picks one buddy now and then for a move of its own.
struct BuddyAct: Equatable {
    var id: String
    /// Which of the moves its energy allows.
    var pick: Int
    var started: Date
}

/// What a buddy remembers between frames: its last colours as they blend into new ones, when the pointer
/// came, where its eyes are, and the moves under way.
@MainActor
private final class BuddyLife {
    weak var probe: NSView?
    var hovered = false
    var hoverStarted: Date?
    var popStarted: Date?
    var shift: (move: BuddyMove, started: Date)?
    var cue: (move: BuddyMove, started: Date)?

    private var from: (skin: UInt32, ink: UInt32)?
    private var to: (skin: UInt32, ink: UInt32) = Theme.buddyHex(.empty)
    /// False until the first face is known: until then the face's own colours show.
    private var settled = false
    private var changed = Date.distantPast
    private var gaze = CGPoint.zero
    private var notice = 0.0
    private var lastFrame: Date?

    /// A new face blends its colours in; one that is awake a level more perks up, a level less sighs.
    func faceChanged(from old: BuddyFace, to new: BuddyFace, at now: Date) {
        let target = Theme.buddyHex(new.color)
        if old == new || !settled {
            to = target
            from = nil
            settled = true
            return
        }
        from = blendedHex(at: now)
        to = target
        changed = now
        if new.mood.energy > old.mood.energy {
            shift = (BuddyMoves.perk, now)
        } else if new.mood.energy < old.mood.energy {
            shift = (BuddyMoves.sigh, now)
        }
    }

    func colours(for face: BuddyFace, at now: Date) -> (skin: Color, ink: Color) {
        guard settled else { return Theme.buddy(face.color) }
        let hex = blendedHex(at: now)
        return (Color(hex: hex.skin), Color(hex: hex.ink))
    }

    private func blendedHex(at now: Date) -> (skin: UInt32, ink: UInt32) {
        guard let from else { return to }
        let fraction = BuddyEase.easeOut.apply(min(1, max(0, now.timeIntervalSince(changed) / 0.45)))
        return (Self.mix(from.skin, to.skin, fraction), Self.mix(from.ink, to.ink, fraction))
    }

    private static func mix(_ a: UInt32, _ b: UInt32, _ fraction: Double) -> UInt32 {
        var result: UInt32 = 0
        for shift in [16, 8, 0] as [UInt32] {
            let x = Double((a >> shift) & 0xFF)
            let y = Double((b >> shift) & 0xFF)
            result |= UInt32((x + (y - x) * fraction).rounded()) << shift
        }
        return result
    }

    func pose(face: BuddyFace, id: String, excited: Bool, act: BuddyAct?, at now: Date) -> BuddyFramePose {
        let rhythm = BuddyRhythm(id: id)
        let time = now.timeIntervalSinceReferenceDate + rhythm.lead
        let mood = face.mood
        let energy = mood.energy
        let elapsed = lastFrame.map { min(0.2, max(0, now.timeIntervalSince($0))) } ?? 0
        lastFrame = now

        var outer: [CGAffineTransform] = []
        func play(_ move: BuddyMove, since start: Date?) {
            guard let start else { return }
            outer.append(move.once(after: now.timeIntervalSince(start)).transform(about: move.anchor))
        }
        play(BuddyMoves.pop, since: popStarted)
        play(BuddyMoves.hover(mood), since: hoverStarted)
        if let shift { play(shift.move, since: shift.started) }
        if let cue { play(cue.move, since: cue.started) }
        if excited {
            outer.append(BuddyMoves.excited.looping(at: time, pace: 1).transform(about: BuddyMoves.excited.anchor))
        }

        let bodyMove = BuddyMoves.body(mood)
        var actTransform = CGAffineTransform.identity
        if let act, !id.isEmpty, act.id == id {
            let moves = BuddyMoves.acts(energy: energy)
            let move = moves[act.pick % moves.count]
            actTransform = move.once(after: now.timeIntervalSince(act.started)).transform(about: move.anchor)
        }

        // The eyes ease towards the pointer, and open wide while it is over the card.
        let target = gazeTarget(energy: energy)
        let follow = 1 - exp(-elapsed / 0.07)
        gaze = CGPoint(x: gaze.x + (target.x - gaze.x) * follow, y: gaze.y + (target.y - gaze.y) * follow)
        let wide = hovered && BuddyMoves.notices(mood) ? 1.0 : 0.0
        notice += (wide - notice) * (1 - exp(-elapsed / 0.09))
        var eyes = CGAffineTransform(translationX: gaze.x, y: gaze.y)
        eyes = BuddyPose(dy: -0.4 * notice, sx: 1 + 0.2 * notice, sy: 1 + 0.2 * notice)
            .transform(about: BuddyAnchor.eyes).concatenating(eyes)
        if let move = BuddyMoves.eyes(mood) {
            eyes = move.looping(at: time, pace: rhythm.pace).transform(about: move.anchor).concatenating(eyes)
        }

        let mouth = BuddyMoves.mouth(mood).map { $0.looping(at: time, pace: rhythm.pace).transform(about: $0.anchor) }
        return BuddyFramePose(
            outer: outer,
            body: bodyMove.looping(at: time, pace: rhythm.pace).transform(about: bodyMove.anchor),
            posture: BuddyMoves.posture(energy: energy).transform(about: BuddyAnchor.headBottom),
            act: actTransform,
            eyes: eyes,
            mouth: mouth ?? .identity,
            bubble: BuddyMoves.snore.looping(at: time, pace: rhythm.pace),
            z: BuddyMoves.zFloat.looping(at: time, pace: rhythm.pace)
        )
    }

    /// Where the eyes would look: towards the pointer while it is over the panel, ahead otherwise.
    private func gazeTarget(energy: Int) -> CGPoint {
        guard BuddyMoves.gazeReach(energy: energy) > 0, let probe, let window = probe.window, window.isVisible else {
            return .zero
        }
        let pointer = NSEvent.mouseLocation
        guard window.frame.contains(pointer) else { return .zero }
        let rect = window.convertToScreen(probe.convert(probe.bounds, to: nil))
        guard rect.width > 0 else { return .zero }
        // Screen points to the buddy's 36 units; y grows downwards on the buddy.
        let unit = BuddyArt.design / rect.width
        return BuddyMoves.gaze(dx: (pointer.x - rect.midX) * unit, dy: (rect.midY - pointer.y) * unit, energy: energy)
    }
}

/// Every transform a buddy's parts take in one frame, outermost first.
struct BuddyFramePose {
    var outer: [CGAffineTransform] = []
    var body: CGAffineTransform = .identity
    var posture: CGAffineTransform = .identity
    var act: CGAffineTransform = .identity
    var eyes: CGAffineTransform = .identity
    var mouth: CGAffineTransform = .identity
    var bubble = BuddyPose.rest
    var z = BuddyPose.rest

    /// Standing still: only its height shows how awake it is.
    static func still(_ mood: BuddyMood) -> BuddyFramePose {
        var pose = BuddyFramePose(posture: BuddyMoves.posture(energy: mood.energy).transform(about: BuddyAnchor.headBottom))
        // A sleeping buddy's bubble and "z"s, at their fullest.
        pose.bubble = BuddyPose(opacity: 0.9)
        pose.z = BuddyPose(dx: 1.6, dy: -1.6)
        return pose
    }
}

/// Finds where the buddy is on screen, for its eyes. It takes no clicks.
private struct BuddyProbe: NSViewRepresentable {
    let life: BuddyLife

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        life.probe = view
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        life.probe = view
    }

    final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The buddy's parts in a 36 × 36 space, y down, and how they are drawn.
/// The app icon raises the same face into 3D; scripts/make-icon.sh redraws it after a change here.
enum BuddyArt {
    static let design: CGFloat = 36
    /// The room drawn round the square on each side, as a part of its side.
    static let room: CGFloat = 0.3
    static let outlineOpacity = 0.14
    static let blushOpacity = 0.32

    @MainActor
    static func draw(face: BuddyFace, skin colours: (skin: Color, ink: Color), line: CGFloat,
                     in context: inout GraphicsContext, size: CGSize, pose: BuddyFramePose) {
        let ink = colours.ink
        context.scaleBy(x: size.width / design, y: size.height / design)
        for transform in pose.outer { context.concatenate(transform) }
        context.concatenate(pose.body)
        context.concatenate(pose.posture)
        context.concatenate(pose.act)

        context.fill(head, with: .color(colours.skin))
        context.stroke(head, with: .color(ink.opacity(outlineOpacity)), lineWidth: 1)
        context.fill(blush, with: .color(Color(hex: PaletteHex.accentClay).opacity(blushOpacity)))
        let stroke = StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)

        var eyes = context
        eyes.concatenate(pose.eyes)
        eyes.fill(eyesFilled(face.mood), with: .color(ink))
        eyes.stroke(eyeLines(face.mood), with: .color(ink), style: stroke)
        eyes.fill(glint(face.mood), with: .color(.white))

        var mouth = context
        mouth.concatenate(pose.mouth)
        mouth.fill(mouthFilled(face.mood), with: .color(ink))
        mouth.stroke(mouthLine(face.mood), with: .color(ink), style: stroke)

        if face.mood == .asleep {
            var bubble = context
            bubble.concatenate(pose.bubble.transform(about: BuddyMoves.snore.anchor))
            bubble.opacity = pose.bubble.opacity
            bubble.fill(Self.bubble, with: .color(.white.opacity(0.65)))
            bubble.stroke(Self.bubble, with: .color(ink.opacity(0.35)), lineWidth: 0.8)
        }
        let zs = z(face.mood)
        if !zs.isEmpty {
            var float = context
            float.concatenate(pose.z.transform(about: BuddyAnchor.z))
            float.opacity = pose.z.opacity
            float.stroke(zs, with: .color(ink), style: stroke)
        }
    }

    static var head: Path {
        Path(roundedRect: CGRect(x: 1.5, y: 1.5, width: 33, height: 33), cornerRadius: 11, style: .continuous)
    }

    static var blush: Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: 5.9, y: 21.8, width: 5, height: 3.2))
        path.addEllipse(in: CGRect(x: 25.1, y: 21.8, width: 5, height: 3.2))
        return path
    }

    private static let leftEye = CGPoint(x: 12, y: 19)
    private static let rightEye = CGPoint(x: 24, y: 19)

    private static func circles(_ centres: [CGPoint], radius: CGFloat) -> Path {
        var path = Path()
        for centre in centres {
            path.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        }
        return path
    }

    /// Big round eyes when wide awake, round ones when calm, the lower half under heavy lids when drowsy.
    static func eyesFilled(_ mood: BuddyMood) -> Path {
        switch mood {
        case .happy:
            return circles([leftEye, rightEye], radius: 3)
        case .content, .unknown:
            return circles([leftEye, rightEye], radius: 2.6)
        case .tired:
            var path = Path()
            for eye in [leftEye, rightEye] {
                path.move(to: CGPoint(x: eye.x + 2.6, y: eye.y))
                path.addArc(center: eye, radius: 2.6, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                path.closeSubpath()
            }
            return path
        case .sleepy, .asleep:
            return Path()
        }
    }

    /// The drowsy buddy's lids, and the closed eyes of a sleepy or sleeping one.
    static func eyeLines(_ mood: BuddyMood) -> Path {
        var path = Path()
        switch mood {
        case .tired:
            for eye in [leftEye, rightEye] {
                path.move(to: CGPoint(x: eye.x - 3.2, y: eye.y))
                path.addLine(to: CGPoint(x: eye.x + 3.2, y: eye.y))
            }
        case .sleepy:
            for eye in [leftEye, rightEye] {
                path.move(to: CGPoint(x: eye.x - 2.8, y: 19.6))
                path.addQuadCurve(to: CGPoint(x: eye.x + 2.8, y: 19.6), control: CGPoint(x: eye.x, y: 21))
            }
        case .asleep:
            for eye in [leftEye, rightEye] {
                path.move(to: CGPoint(x: eye.x - 2.4, y: 19))
                path.addQuadCurve(to: CGPoint(x: eye.x + 2.4, y: 19), control: CGPoint(x: eye.x, y: 21.4))
            }
        case .happy, .content, .unknown:
            break
        }
        return path
    }

    /// A white glint in a wide-awake buddy's eyes.
    static func glint(_ mood: BuddyMood) -> Path {
        guard mood == .happy else { return Path() }
        return circles([CGPoint(x: 13.3, y: 17.4), CGPoint(x: 25.3, y: 17.4)], radius: 1.1)
    }

    /// An open smile when wide awake, a yawn when nearly asleep.
    static func mouthFilled(_ mood: BuddyMood) -> Path {
        var path = Path()
        switch mood {
        case .happy:
            path.move(to: CGPoint(x: 13.2, y: 23.2))
            path.addLine(to: CGPoint(x: 22.8, y: 23.2))
            path.addQuadCurve(to: CGPoint(x: 18, y: 28.6), control: CGPoint(x: 22.8, y: 28.6))
            path.addQuadCurve(to: CGPoint(x: 13.2, y: 23.2), control: CGPoint(x: 13.2, y: 28.6))
            path.closeSubpath()
        case .sleepy:
            path.addEllipse(in: CGRect(x: 16, y: 23.5, width: 4, height: 5))
        case .content, .tired, .asleep, .unknown:
            break
        }
        return path
    }

    /// A small smile when calm, a flat line when drowsy or asleep, or when there is no reading to go by.
    static func mouthLine(_ mood: BuddyMood) -> Path {
        var path = Path()
        switch mood {
        case .content:
            path.move(to: CGPoint(x: 14.4, y: 24))
            path.addQuadCurve(to: CGPoint(x: 21.6, y: 24), control: CGPoint(x: 18, y: 27.4))
        case .unknown:
            path.move(to: CGPoint(x: 15.5, y: 24.6))
            path.addLine(to: CGPoint(x: 20.5, y: 24.6))
        case .tired:
            path.move(to: CGPoint(x: 15.4, y: 25.4))
            path.addLine(to: CGPoint(x: 20.6, y: 25.4))
        case .asleep:
            path.move(to: CGPoint(x: 16.6, y: 25.2))
            path.addLine(to: CGPoint(x: 19.4, y: 25.2))
        case .happy, .sleepy:
            break
        }
        return path
    }

    /// A sleeping buddy's snore bubble.
    static var bubble: Path {
        Path(ellipseIn: CGRect(x: 20.2, y: 22.8, width: 5.2, height: 5.2))
    }

    /// One "z" drifting up from a buddy nearly asleep, two from one asleep.
    static func z(_ mood: BuddyMood) -> Path {
        var path = Path()
        func letter(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + size, y: y))
            path.addLine(to: CGPoint(x: x, y: y + size))
            path.addLine(to: CGPoint(x: x + size, y: y + size))
        }
        switch mood {
        case .sleepy:
            letter(27.2, 5.6, 3.2)
        case .asleep:
            letter(25.6, 2.6, 5.4)
            letter(21.6, 7.6, 2.8)
        default:
            break
        }
        return path
    }
}

private struct BuddyHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

private struct BuddyActKey: EnvironmentKey {
    static let defaultValue: BuddyAct? = nil
}

extension EnvironmentValues {
    /// Set on a card's contents while the pointer is over the card: its buddy reacts.
    var buddyHovered: Bool {
        get { self[BuddyHoveredKey.self] }
        set { self[BuddyHoveredKey.self] = newValue }
    }

    /// The buddy the panel picked for a move of its own, if any.
    var buddyAct: BuddyAct? {
        get { self[BuddyActKey.self] }
        set { self[BuddyActKey.self] = newValue }
    }
}
