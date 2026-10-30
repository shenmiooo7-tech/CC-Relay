import XCTest
@testable import CompanionUI

final class BuddyMotionTests: XCTestCase {
    func testTracksStartAndEndOnTheirKeysAndEaseBetween() {
        let track = BuddyTrack(.inOut, [(0, .rest), (1, BuddyPose(dy: -4))])
        XCTAssertEqual(track.pose(at: -1), .rest)
        XCTAssertEqual(track.pose(at: 0), .rest)
        XCTAssertEqual(track.pose(at: 1).dy, -4, accuracy: 0.0001)
        XCTAssertEqual(track.pose(at: 2).dy, -4, accuracy: 0.0001)
        // Ease in and out: halfway in time is halfway there, a quarter in is less than a quarter there.
        XCTAssertEqual(track.pose(at: 0.5).dy, -2, accuracy: 0.01)
        XCTAssertGreaterThan(track.pose(at: 0.25).dy, -1)
        // A spring passes its pose before it settles.
        XCTAssertGreaterThan(BuddyEase.spring.apply(0.6), 1)
        XCTAssertEqual(BuddyEase.spring.apply(1), 1, accuracy: 0.001)
    }

    func testAMovePlayedOnceRestsBeforeAndAfterAndALoopWraps() {
        let move = BuddyMove(track: BuddyTrack(.linear, [(0, .rest), (0.5, BuddyPose(dx: 2)), (1, .rest)]),
                             seconds: 2, anchor: BuddyAnchor.bottom)
        XCTAssertEqual(move.once(after: -0.1), .rest)
        XCTAssertEqual(move.once(after: 1).dx, 2, accuracy: 0.0001)
        XCTAssertEqual(move.once(after: 2), .rest)
        XCTAssertEqual(move.looping(at: 1, pace: 1).dx, 2, accuracy: 0.0001)
        XCTAssertEqual(move.looping(at: 5, pace: 1).dx, 2, accuracy: 0.0001)
        // At half pace one run takes a second.
        XCTAssertEqual(move.looping(at: 0.5, pace: 0.5).dx, 2, accuracy: 0.0001)
    }

    func testEachAccountHasItsOwnSteadyRhythm() {
        let one = BuddyRhythm(id: "Claude_204")
        XCTAssertEqual(one, BuddyRhythm(id: "Claude_204"))
        XCTAssertNotEqual(one, BuddyRhythm(id: "Claude_203"))
        for id in ["Claude", "Claude_203", "Claude_204", "Claude_208", "甲乙丙"] {
            let rhythm = BuddyRhythm(id: id)
            XCTAssertTrue((0..<4).contains(rhythm.lead), id)
            XCTAssertTrue((0.88...1.12).contains(rhythm.pace), id)
        }
    }

    func testTheMoreAwakeTheTallerItStandsAndTheFurtherItLooks() {
        let heights = (0...4).map { BuddyMoves.posture(energy: $0).sy }
        XCTAssertEqual(heights, heights.sorted())
        XCTAssertEqual(BuddyMoves.posture(energy: 3), .rest)
        XCTAssertEqual(BuddyMoves.gaze(dx: 200, dy: 0, energy: 0), .zero)
        // Far away it looks as far as it reaches; near, less; up and down less than sideways.
        XCTAssertEqual(BuddyMoves.gaze(dx: 200, dy: 0, energy: 4).x, 1.6, accuracy: 0.0001)
        XCTAssertEqual(BuddyMoves.gaze(dx: 30, dy: 0, energy: 4).x, 0.8, accuracy: 0.0001)
        XCTAssertEqual(BuddyMoves.gaze(dx: 0, dy: 200, energy: 4).y, 1.12, accuracy: 0.0001)
        // Out of range energies keep to the ends.
        XCTAssertEqual(BuddyMoves.gazeReach(energy: 9), 1.6)
        XCTAssertEqual(BuddyMoves.gazeReach(energy: -2), 0)
    }

    func testEveryMoodHasMovesOfItsOwn() {
        for energy in -1...5 {
            XCTAssertFalse(BuddyMoves.acts(energy: energy).isEmpty, "\(energy)")
        }
        XCTAssertNotEqual(BuddyMoves.acts(energy: 4), BuddyMoves.acts(energy: 1))
        let moods: [BuddyMood] = [.happy, .content, .tired, .sleepy, .asleep]
        XCTAssertEqual(moods.map(\.energy), [4, 3, 2, 1, 0])
        XCTAssertEqual(Set(moods.map { BuddyMoves.body($0).seconds }).count, moods.count)
        XCTAssertTrue(BuddyMoves.notices(.happy))
        XCTAssertFalse(BuddyMoves.notices(.asleep))
    }
}
