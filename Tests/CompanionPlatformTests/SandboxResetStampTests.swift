import Foundation
import XCTest
@testable import CompanionPlatform

final class SandboxResetStampTests: XCTestCase {
    func testResetsFollowTheSignInTimeOnWholeMinutes() {
        let signIn = ISO8601DateFormatter().date(from: "2026-10-25T01:55:53Z")!
        XCTAssertEqual(
            SandboxWorldGenerator.resetStamp(signIn, after: SandboxWorldGenerator.fiveHourResetDelay),
            "2026-10-25T05:55:00Z"
        )
        XCTAssertEqual(
            SandboxWorldGenerator.resetStamp(signIn, after: SandboxWorldGenerator.weeklyResetDelay),
            "2026-10-29T01:55:00Z"
        )
    }

    func testFiveHourResetStaysInsideItsWindow() {
        XCTAssertLessThan(SandboxWorldGenerator.fiveHourResetDelay, 5 * 3600)
        XCTAssertGreaterThan(SandboxWorldGenerator.weeklyResetDelay, SandboxWorldGenerator.fiveHourResetDelay)
    }
}
