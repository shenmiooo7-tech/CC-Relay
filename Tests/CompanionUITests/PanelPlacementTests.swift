import CoreGraphics
import XCTest
@testable import CompanionUI

final class PanelPlacementTests: XCTestCase {
    /// A 1512 × 982 screen with a 33 pt menu bar, so the visible area ends at y = 949.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 949)
    private let size = CGSize(width: 360, height: 578)

    func testHangsFromTheStatusItemWithItsLeftEdge() {
        let item = CGRect(x: 900, y: 949, width: 80, height: 33)
        let frame = PanelPlacement.frame(content: size, statusItem: item, visible: screen)
        XCTAssertEqual(frame.minX, 900)
        XCTAssertEqual(frame.maxY, 949 - PanelPlacement.gapBelowMenuBar)
        XCTAssertEqual(frame.size, size)
    }

    func testStaysInsideTheRightEdge() {
        let item = CGRect(x: 1400, y: 949, width: 80, height: 33)
        let frame = PanelPlacement.frame(content: size, statusItem: item, visible: screen)
        XCTAssertEqual(frame.maxX, 1512 - PanelPlacement.screenMargin)
    }

    func testStaysInsideTheLeftEdge() {
        let item = CGRect(x: 2, y: 949, width: 80, height: 33)
        let frame = PanelPlacement.frame(content: size, statusItem: item, visible: screen)
        XCTAssertEqual(frame.minX, PanelPlacement.screenMargin)
    }

    func testNeverTallerThanTheScreenBelowTheMenuBar() {
        let item = CGRect(x: 900, y: 949, width: 80, height: 33)
        let tall = CGSize(width: 360, height: 2000)
        let frame = PanelPlacement.frame(content: tall, statusItem: item, visible: screen)
        XCTAssertEqual(frame.minY, PanelPlacement.screenMargin)
        XCTAssertEqual(frame.maxY, 949 - PanelPlacement.gapBelowMenuBar)
    }

    func testTheHeightLimitIsWhatTheScreenLeavesBelowTheMenuBar() {
        let item = CGRect(x: 900, y: 949, width: 80, height: 33)
        let limit = PanelPlacement.heightLimit(statusItem: item, visible: screen)
        XCTAssertEqual(limit, 949 - PanelPlacement.gapBelowMenuBar - PanelPlacement.screenMargin)
        let frame = PanelPlacement.frame(content: CGSize(width: 360, height: 2000), statusItem: item, visible: screen)
        XCTAssertEqual(frame.height, limit)
    }

    func testSecondScreenUsesItsOwnCoordinates() {
        let second = CGRect(x: 1512, y: 0, width: 1920, height: 1055)
        let item = CGRect(x: 3000, y: 1055, width: 80, height: 25)
        let frame = PanelPlacement.frame(content: size, statusItem: item, visible: second)
        XCTAssertEqual(frame.minX, 3000)
        XCTAssertEqual(frame.maxY, 1055 - PanelPlacement.gapBelowMenuBar)
    }
}
