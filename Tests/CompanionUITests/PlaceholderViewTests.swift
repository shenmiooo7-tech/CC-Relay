import SwiftUI
import XCTest
@testable import CompanionUI

@MainActor
final class PlaceholderViewTests: XCTestCase {
    func testPlaceholderAndMenuBarBuildWithoutUserData() {
        _ = PlaceholderView().body
        let placeholder = PanelViewState.placeholder(language: .en)
        XCTAssertNil(placeholder.current)
        XCTAssertTrue(placeholder.others.isEmpty)
        XCTAssertEqual(placeholder.header.title, "CC-Relay")
    }
}
