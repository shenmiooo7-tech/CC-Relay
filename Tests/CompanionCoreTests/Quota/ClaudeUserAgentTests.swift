import XCTest
@testable import CompanionCore

final class QuotaUserAgentTests: XCTestCase {
    func testBuildsDesktopTokensAndOmitsMissingVersions() {
        XCTAssertEqual(
            ClaudeUserAgent.headerValue(claude: "1.2.3", electron: "39.0.0"),
            expected(claude: "1.2.3", electron: "39.0.0")
        )
        XCTAssertEqual(
            ClaudeUserAgent.headerValue(claude: "1.2.3", electron: nil),
            expected(claude: "1.2.3", electron: nil)
        )
        XCTAssertEqual(
            ClaudeUserAgent.headerValue(claude: nil, electron: "39.0.0"),
            expected(claude: nil, electron: "39.0.0")
        )
        XCTAssertEqual(
            ClaudeUserAgent.headerValue(claude: nil, electron: nil),
            expected(claude: nil, electron: nil)
        )
        XCTAssertEqual(
            ClaudeUserAgent.headerValue(claude: "  ", electron: "\n"),
            expected(claude: nil, electron: nil)
        )
        XCTAssertEqual(
            ClaudeUserAgent.headerValue(claude: " 4.5 ", electron: ""),
            expected(claude: "4.5", electron: nil)
        )
    }

    private func expected(claude: String?, electron: String?) -> String {
        var parts = [
            "Mozilla/5.0",
            "(Macintosh;",
            "Intel",
            "Mac",
            "OS",
            "X",
            "10_15_7)",
            "AppleWebKit/537.36",
            "(KHTML, like Gecko)",
        ]
        if let claude {
            parts.append("Claude/\(claude)")
        }
        if let electron {
            parts.append("Electron/\(electron)")
        }
        parts.append("Safari/537.36")
        return parts.joined(separator: " ")
    }
}
