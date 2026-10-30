import XCTest
@testable import CompanionCore

final class RedactionTests: XCTestCase {
    func testMasksEmailAndUUID() {
        XCTAssertEqual(Redaction.maskEmail("dan@example.com"), "d\u{2022}\u{2022}\u{2022}@example.com")
        XCTAssertEqual(Redaction.maskEmail("Ada@Example.com"), "A\u{2022}\u{2022}\u{2022}@Example.com")
        XCTAssertEqual(
            Redaction.maskUUID("12345678-1234-1234-1234-123456789abc"),
            "12345678\u{2026}"
        )
        XCTAssertEqual(
            Redaction.maskUUID("ABCDEF12-1234-4234-8234-123456789ABC"),
            "ABCDEF12\u{2026}"
        )
    }

    func testScrubReplacesEveryEmailAndUUID() {
        let raw = "mail dan@example.com and Ada@Example.com plus 12345678-1234-1234-1234-123456789abc twice 12345678-1234-1234-1234-123456789abc"
        let scrubbed = Redaction.scrub(raw)
        XCTAssertEqual(
            scrubbed,
            "mail d\u{2022}\u{2022}\u{2022}@example.com and A\u{2022}\u{2022}\u{2022}@Example.com plus 12345678\u{2026} twice 12345678\u{2026}"
        )
        XCTAssertFalse(scrubbed.contains("dan@example.com"))
        XCTAssertFalse(scrubbed.contains("12345678-1234-1234-1234-123456789abc"))
        XCTAssertEqual(Redaction.scrub("ordinary words stay"), "ordinary words stay")
    }
}
