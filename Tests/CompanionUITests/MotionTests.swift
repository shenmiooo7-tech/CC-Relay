import XCTest
@testable import CompanionUI

@MainActor
final class MotionTests: XCTestCase {
    func testSwitchLightIsOnTheStepUnderWayFromTheFirst() {
        XCTAssertEqual(SwitchDialog.stepUnderWay(done: 0), 0...0.25)
        XCTAssertEqual(SwitchDialog.stepUnderWay(done: 3), 0.75...1)
        XCTAssertNil(SwitchDialog.stepUnderWay(done: Metrics.switchStepCount))
    }

    func testSheenCrossesItsWholePartOnEachPass() {
        // A whole number of 1.2 s passes since the reference date.
        let start = Date(timeIntervalSinceReferenceDate: 1200)
        XCTAssertEqual(Sheen.lead(at: start, width: 40, band: 24), -24, accuracy: 0.001)
        XCTAssertEqual(Sheen.lead(at: start.addingTimeInterval(0.6), width: 40, band: 24), 8, accuracy: 0.001)
        XCTAssertEqual(Sheen.lead(at: start.addingTimeInterval(1.199), width: 40, band: 24), 40, accuracy: 0.1)
        XCTAssertEqual(Sheen.lead(at: start.addingTimeInterval(1.2), width: 40, band: 24), -24, accuracy: 0.001)
    }
}
