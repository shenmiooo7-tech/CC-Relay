import CoreGraphics
import Foundation

/// A buddy part's place at one moment, in the buddy's 36-unit square: moved, turned (degrees) and
/// stretched about an anchor, and how solid it is.
struct BuddyPose: Equatable {
    var dx: Double = 0
    var dy: Double = 0
    var sx: Double = 1
    var sy: Double = 1
    var turn: Double = 0
    var opacity: Double = 1

    static let rest = BuddyPose()

    static func scale(_ both: Double) -> BuddyPose { BuddyPose(sx: both, sy: both) }

    func mixed(with other: BuddyPose, by fraction: Double) -> BuddyPose {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
        return BuddyPose(dx: mix(dx, other.dx), dy: mix(dy, other.dy), sx: mix(sx, other.sx), sy: mix(sy, other.sy),
                         turn: mix(turn, other.turn), opacity: mix(opacity, other.opacity))
    }

    /// Stretched and turned about `anchor`, then moved.
    func transform(about anchor: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: anchor.x + dx, y: anchor.y + dy)
            .rotated(by: turn * .pi / 180)
            .scaledBy(x: sx, y: sy)
            .translatedBy(x: -anchor.x, y: -anchor.y)
    }
}

/// How a move speeds up and slows down between two of its key poses.
enum BuddyEase: Equatable {
    case linear
    case inOut
    case easeIn
    case easeOut
    /// Overshoots a little past the pose and comes back.
    case spring
    /// Like `spring`, a little softer.
    case softSpring

    func apply(_ t: Double) -> Double {
        switch self {
        case .linear: t
        case .inOut: Self.bezier(0.42, 0, 0.58, 1, t)
        case .easeIn: Self.bezier(0.42, 0, 1, 1, t)
        case .easeOut: Self.bezier(0, 0, 0.58, 1, t)
        case .spring: Self.bezier(0.34, 1.56, 0.64, 1, t)
        case .softSpring: Self.bezier(0.34, 1.3, 0.64, 1, t)
        }
    }

    /// The cubic Bézier timing curve from (0, 0) to (1, 1) through two control points, at time `x`.
    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        func coordinate(_ a: Double, _ b: Double, _ s: Double) -> Double {
            3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s
        }
        // Find the curve's parameter whose x is `x` by halving, then read its y.
        var low = 0.0
        var high = 1.0
        var s = x
        for _ in 0..<24 {
            let value = coordinate(x1, x2, s)
            if abs(value - x) < 0.0001 { break }
            if value < x { low = s } else { high = s }
            s = (low + high) / 2
        }
        return coordinate(y1, y2, s)
    }
}

/// Key poses through one run of a move, at fractions from 0 to 1, eased between each pair.
struct BuddyTrack: Equatable {
    var keys: [(at: Double, pose: BuddyPose)]
    var ease: BuddyEase

    init(_ ease: BuddyEase, _ keys: [(Double, BuddyPose)]) {
        self.ease = ease
        self.keys = keys.map { (at: $0.0, pose: $0.1) }
    }

    func pose(at progress: Double) -> BuddyPose {
        guard let first = keys.first, let last = keys.last else { return .rest }
        if progress <= first.at { return first.pose }
        if progress >= last.at { return last.pose }
        for index in 1..<keys.count where progress <= keys[index].at {
            let from = keys[index - 1]
            let to = keys[index]
            let span = to.at - from.at
            let fraction = span > 0 ? (progress - from.at) / span : 1
            return from.pose.mixed(with: to.pose, by: ease.apply(fraction))
        }
        return last.pose
    }

    static func == (lhs: BuddyTrack, rhs: BuddyTrack) -> Bool {
        lhs.ease == rhs.ease && lhs.keys.map(\.at) == rhs.keys.map(\.at) && lhs.keys.map(\.pose) == rhs.keys.map(\.pose)
    }
}

/// A move with its length in seconds and the point of the buddy it turns and stretches about.
struct BuddyMove: Equatable {
    var track: BuddyTrack
    var seconds: Double
    var anchor: CGPoint

    /// Where a move that loops is at `time`, each run `pace` times its length.
    func looping(at time: Double, pace: Double) -> BuddyPose {
        let length = seconds * pace
        guard length > 0 else { return .rest }
        let phase = time.truncatingRemainder(dividingBy: length) / length
        return track.pose(at: phase < 0 ? phase + 1 : phase)
    }

    /// Where a move played once is, `elapsed` seconds after it started; at rest before and after.
    func once(after elapsed: Double) -> BuddyPose {
        guard elapsed >= 0, elapsed < seconds else { return .rest }
        return track.pose(at: elapsed / seconds)
    }
}

/// Points of the buddy that its parts move about.
enum BuddyAnchor {
    /// The bottom of its square: it squashes and hops from there.
    static let bottom = CGPoint(x: 18, y: 36)
    /// The bottom of its head, for the moves it makes now and then.
    static let headBottom = CGPoint(x: 18, y: 34.5)
    static let middle = CGPoint(x: 18, y: 18)
    /// Low in the head, where a nodding head pivots.
    static let neck = CGPoint(x: 18, y: 32.4)
    static let eyes = CGPoint(x: 18, y: 19)
    static let eyeLids = CGPoint(x: 18, y: 16.4)
    static let grin = CGPoint(x: 18, y: 23.2)
    static let yawn = CGPoint(x: 18, y: 26)
    static let bubble = CGPoint(x: 20.2, y: 25.4)
    static let z = CGPoint(x: 28, y: 6)
}

/// Every move a buddy makes. The less quota its 5-hour window has, the sleepier its moves.
enum BuddyMoves {
    private static func pose(dx: Double = 0, dy: Double = 0, sx: Double = 1, sy: Double = 1, turn: Double = 0,
                             opacity: Double = 1) -> BuddyPose {
        BuddyPose(dx: dx, dy: dy, sx: sx, sy: sy, turn: turn, opacity: opacity)
    }

    private static let rest = BuddyPose.rest

    // Eyes.

    /// Wide awake: glances right and left, then blinks twice.
    static let look = BuddyMove(track: BuddyTrack(.inOut, [
        (0, rest), (0.16, rest), (0.21, pose(dx: 1.2)), (0.38, pose(dx: 1.2)), (0.43, pose(dx: -1.2)),
        (0.6, pose(dx: -1.2)), (0.65, rest), (0.86, rest), (0.885, pose(sy: 0.1)), (0.91, rest),
        (0.935, pose(sy: 0.1)), (0.96, rest), (1, rest),
    ]), seconds: 6.4, anchor: BuddyAnchor.eyes)

    static let blink = BuddyMove(track: BuddyTrack(.inOut, [
        (0, rest), (0.93, rest), (0.96, pose(sy: 0.1)), (1, rest),
    ]), seconds: 4.6, anchor: BuddyAnchor.eyes)

    /// Drowsy: the lids sink slowly and snap open.
    static let droop = BuddyMove(track: BuddyTrack(.easeIn, [
        (0, rest), (0.08, rest), (0.62, pose(sy: 0.3)), (0.65, pose(sy: 1.12)), (0.7, rest), (1, rest),
    ]), seconds: 5.6, anchor: BuddyAnchor.eyeLids)

    // The whole buddy.

    /// Crouches and bounces.
    static let bounce = BuddyMove(track: BuddyTrack(.inOut, [
        (0, rest), (0.5, rest), (0.57, pose(sx: 1.06, sy: 0.93)), (0.66, pose(dy: -2.4, sx: 0.95, sy: 1.06)),
        (0.75, pose(sx: 1.05, sy: 0.95)), (0.83, rest), (1, rest),
    ]), seconds: 2.8, anchor: BuddyAnchor.bottom)

    static let sway = BuddyMove(track: BuddyTrack(.inOut, [
        (0, pose(turn: -2)), (0.5, pose(turn: 2)), (1, pose(turn: -2)),
    ]), seconds: 5, anchor: BuddyAnchor.bottom)

    /// Fights sleep: sinks, then jerks back up.
    static let jerk = BuddyMove(track: BuddyTrack(.easeIn, [
        (0, rest), (0.08, rest), (0.62, pose(dy: 1.2, turn: 3)), (0.65, pose(dy: -1.2)), (0.72, rest), (1, rest),
    ]), seconds: 5.6, anchor: BuddyAnchor.bottom)

    /// Stretches as it yawns, then nods off.
    static let nod = BuddyMove(track: BuddyTrack(.inOut, [
        (0, rest), (0.38, rest), (0.5, pose(sx: 0.95, sy: 1.07)), (0.6, pose(sx: 0.95, sy: 1.07)),
        (0.74, pose(dy: 1, turn: -7)), (0.84, pose(dy: 1, turn: -7)), (0.95, rest), (1, rest),
    ]), seconds: 4.6, anchor: BuddyAnchor.neck)

    static let breathe = BuddyMove(track: BuddyTrack(.inOut, [
        (0, rest), (0.5, pose(sx: 1.03, sy: 0.95)), (1, rest),
    ]), seconds: 3.8, anchor: BuddyAnchor.bottom)

    // The mouth, the snore bubble and the "z"s.

    /// The grin widens at the top of each bounce.
    static let grin = BuddyMove(track: BuddyTrack(.inOut, [
        (0, rest), (0.55, rest), (0.66, pose(sx: 1.14, sy: 1.18)), (0.8, rest), (1, rest),
    ]), seconds: 2.8, anchor: BuddyAnchor.grin)

    static let yawn = BuddyMove(track: BuddyTrack(.inOut, [
        (0, pose(sy: 0.5)), (0.4, pose(sy: 0.5)), (0.5, pose(sy: 1.3)), (0.62, pose(sy: 1.3)), (0.72, pose(sy: 0.6)),
        (1, pose(sy: 0.5)),
    ]), seconds: 4.6, anchor: BuddyAnchor.yawn)

    /// Grows with each breath and pops.
    static let snore = BuddyMove(track: BuddyTrack(.inOut, [
        (0, pose(sx: 0.15, sy: 0.15, opacity: 0.9)), (0.48, pose(opacity: 0.9)),
        (0.56, pose(sx: 1.3, sy: 1.3, opacity: 0)), (1, pose(sx: 0.15, sy: 0.15, opacity: 0)),
    ]), seconds: 3.8, anchor: BuddyAnchor.bubble)

    /// Drifts up and away, fading in and out.
    static let zFloat = BuddyMove(track: BuddyTrack(.easeOut, [
        (0, pose(dy: 2, sx: 0.7, sy: 0.7, opacity: 0)), (0.2, pose(dx: 0.58, dy: 0.98, sx: 0.81, sy: 0.81)),
        (0.55, pose(dx: 1.6, dy: -1.6)), (0.75, pose(dx: 2.33, dy: -3.1, sx: 1.05, sy: 1.05)),
        (1, pose(dx: 3.2, dy: -5, sx: 1.1, sy: 1.1, opacity: 0)),
    ]), seconds: 3.2, anchor: BuddyAnchor.z)

    // Under the pointer, by how awake it is.

    static let hop = BuddyMove(track: BuddyTrack(.spring, [
        (0, rest), (0.3, pose(dy: -4, sx: 1.04, sy: 0.96)), (0.62, pose(sx: 0.96, sy: 1.04)), (1, rest),
    ]), seconds: 0.55, anchor: BuddyAnchor.bottom)

    static let lazyHop = BuddyMove(track: BuddyTrack(.inOut, [
        (0, rest), (0.45, pose(dy: -2)), (0.75, pose(sx: 1.02, sy: 0.98)), (1, rest),
    ]), seconds: 0.8, anchor: BuddyAnchor.bottom)

    static let jolt = BuddyMove(track: BuddyTrack(.easeOut, [
        (0, rest), (0.14, pose(dy: -2.5, sx: 1.04, sy: 1.04)), (0.36, rest), (0.6, pose(dy: 0.8)), (1, rest),
    ]), seconds: 0.9, anchor: BuddyAnchor.bottom)

    static let stir = BuddyMove(track: BuddyTrack(.inOut, [
        (0, rest), (0.25, pose(turn: -4)), (0.5, pose(turn: 3)), (0.75, pose(turn: -2)), (1, rest),
    ]), seconds: 0.7, anchor: BuddyAnchor.bottom)

    // Now and then, one buddy at a time.

    static let twirl = BuddyMove(track: BuddyTrack(.softSpring, [
        (0, rest), (0.18, pose(dy: -3, sx: 0.96, sy: 1.05)), (0.62, pose(dy: -3, turn: 360)),
        (0.8, pose(sx: 1.06, sy: 0.94, turn: 360)), (1, pose(turn: 360)),
    ]), seconds: 1.2, anchor: BuddyAnchor.middle)

    static let wiggle = BuddyMove(track: BuddyTrack(.inOut, [
        (0, rest), (0.2, pose(turn: -9)), (0.4, pose(turn: 9)), (0.6, pose(turn: -6)), (0.8, pose(turn: 4)), (1, rest),
    ]), seconds: 1, anchor: BuddyAnchor.headBottom)

    static let tilt = BuddyMove(track: BuddyTrack(.inOut, [
        (0, rest), (0.25, pose(turn: 11)), (0.7, pose(turn: 11)), (1, rest),
    ]), seconds: 1.3, anchor: BuddyAnchor.headBottom)

    static let stretch = BuddyMove(track: BuddyTrack(.inOut, [
        (0, rest), (0.35, pose(sx: 0.93, sy: 1.1)), (0.6, pose(sx: 0.93, sy: 1.1)), (0.8, pose(sx: 1.04, sy: 0.96)),
        (1, rest),
    ]), seconds: 1.2, anchor: BuddyAnchor.headBottom)

    static let shake = BuddyMove(track: BuddyTrack(.inOut, [
        (0, rest), (0.15, pose(turn: -7)), (0.3, pose(turn: 7)), (0.45, pose(turn: -5)), (0.6, pose(turn: 4)),
        (0.75, rest), (1, rest),
    ]), seconds: 1, anchor: BuddyAnchor.headBottom)

    static let slump = BuddyMove(track: BuddyTrack(.inOut, [
        (0, rest), (0.4, pose(dy: 1.5, sx: 1.07, sy: 0.9)), (0.55, pose(dy: 1.5, sx: 1.07, sy: 0.9)), (1, rest),
    ]), seconds: 1.3, anchor: BuddyAnchor.headBottom)

    static let doze = BuddyMove(track: BuddyTrack(.inOut, [
        (0, rest), (0.45, pose(dy: 1.5, turn: 12)), (0.6, pose(dy: -1.2, turn: -4)), (0.75, rest), (1, rest),
    ]), seconds: 1.3, anchor: BuddyAnchor.headBottom)

    static let roll = BuddyMove(track: BuddyTrack(.inOut, [
        (0, rest), (0.45, pose(dx: -1, turn: -10)), (0.6, pose(dx: -1, turn: -10)), (1, rest),
    ]), seconds: 1.4, anchor: BuddyAnchor.headBottom)

    /// The moves a buddy may make now and then, by how awake it is (`BuddyMood.energy`).
    static func acts(energy: Int) -> [BuddyMove] {
        switch energy {
        case ...0: [roll]
        case 1: [doze]
        case 2: [shake, slump]
        case 3: [tilt, stretch]
        default: [twirl, wiggle]
        }
    }

    // Asked for from outside.

    /// While a switch heads to it.
    static let excited = BuddyMove(track: BuddyTrack(.inOut, [
        (0, rest), (0.3, pose(dy: -3, sx: 0.96, sy: 1.05)), (0.55, pose(sx: 1.05, sy: 0.95)), (1, rest),
    ]), seconds: 0.6, anchor: BuddyAnchor.bottom)

    /// A new reading woke it up a level, or a switch to it is done.
    static let perk = BuddyMove(track: BuddyTrack(.spring, [
        (0, rest), (0.25, pose(dy: -5, sx: 0.95, sy: 1.07)), (0.55, pose(sx: 1.07, sy: 0.93)), (0.75, pose(dy: -1)),
        (1, rest),
    ]), seconds: 0.75, anchor: BuddyAnchor.bottom)

    /// A new reading tired it a level, or a switch to it failed.
    static let sigh = BuddyMove(track: BuddyTrack(.inOut, [
        (0, rest), (0.35, pose(dy: 2, sx: 1.06, sy: 0.9)), (1, rest),
    ]), seconds: 1, anchor: BuddyAnchor.bottom)

    /// The new figures came in from the header's refresh.
    static let pop = BuddyMove(track: BuddyTrack(.spring, [
        (0, .scale(1.15)), (1, rest),
    ]), seconds: 0.5, anchor: BuddyAnchor.bottom)

    // By mood.

    static func eyes(_ mood: BuddyMood) -> BuddyMove? {
        switch mood {
        case .happy: look
        case .content, .unknown: blink
        case .tired: droop
        case .sleepy, .asleep: nil
        }
    }

    static func body(_ mood: BuddyMood) -> BuddyMove {
        switch mood {
        case .happy: bounce
        case .content, .unknown: sway
        case .tired: jerk
        case .sleepy: nod
        case .asleep: breathe
        }
    }

    static func mouth(_ mood: BuddyMood) -> BuddyMove? {
        switch mood {
        case .happy: grin
        case .sleepy: yawn
        default: nil
        }
    }

    static func hover(_ mood: BuddyMood) -> BuddyMove {
        switch mood {
        case .happy, .content, .unknown: hop
        case .tired: lazyHop
        case .sleepy: jolt
        case .asleep: stir
        }
    }

    /// Awake enough to open its eyes wide under the pointer.
    static func notices(_ mood: BuddyMood) -> Bool {
        switch mood {
        case .happy, .content, .unknown: true
        case .tired, .sleepy, .asleep: false
        }
    }

    /// How far its eyes follow the pointer, by how awake it is.
    static func gazeReach(energy: Int) -> Double {
        [0, 0, 0.7, 1.4, 1.6][min(max(energy, 0), 4)]
    }

    /// Its height: tall when wide awake, lower as it tires, flattest asleep.
    static func posture(energy: Int) -> BuddyPose {
        BuddyPose(sy: [0.92, 0.95, 0.97, 1, 1.03][min(max(energy, 0), 4)])
    }

    /// Where its eyes look for a pointer `dx`, `dy` points away from its middle, y down.
    static func gaze(dx: Double, dy: Double, energy: Int) -> CGPoint {
        let distance = max(hypot(dx, dy), 1)
        let reach = gazeReach(energy: energy) * min(1, distance / 60)
        return CGPoint(x: dx / distance * reach, y: dy / distance * reach * 0.7)
    }
}

/// Each buddy starts its loops at its own point and runs a little faster or slower, from its account,
/// so no two move in step.
struct BuddyRhythm: Equatable {
    /// Seconds already run at the start.
    var lead: Double
    /// 0.88 to 1.12 times each loop's length.
    var pace: Double

    init(id: String) {
        var seed = 0
        for scalar in id.unicodeScalars {
            seed = (seed * 31 + Int(scalar.value)) % 997
        }
        lead = Double(seed % 40) / 10
        pace = 0.88 + Double(seed % 25) / 100
    }
}
