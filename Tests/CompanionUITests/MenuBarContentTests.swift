import XCTest
@testable import CompanionUI

/// The menu bar shows only the logo; these are what VoiceOver hears for it.
final class MenuBarContentTests: XCTestCase {
    func testVoiceOverHearsTheAccountAndItsPercent() {
        let content = MenuBarContent(title: "204", quotaPercent: 61, isSwitching: false, language: .zhHans)
        XCTAssertEqual(content.accessibilityLabel, "CC-Relay, 204 · 61%")
    }

    func testMissingReadingNamesTheAccountAlone() {
        let content = MenuBarContent(title: "204", quotaPercent: nil, isSwitching: false, language: .en)
        XCTAssertEqual(content.accessibilityLabel, "CC-Relay, 204")
    }

    func testWithoutAnAccountTheProductIsNamedOnce() {
        let content = MenuBarContent(title: "CC-Relay", quotaPercent: nil, isSwitching: false, language: .en)
        XCTAssertEqual(content.accessibilityLabel, "CC-Relay")
    }

    func testSwitchingLeavesThePercentOut() {
        let content = MenuBarContent(title: "正在切换到 201…", quotaPercent: 12, isSwitching: true, language: .zhHans)
        XCTAssertEqual(content.accessibilityLabel, "CC-Relay, 正在切换到 201…")
    }
}
