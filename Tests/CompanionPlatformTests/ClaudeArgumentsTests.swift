import Foundation
import XCTest
import CompanionPlatform

final class ClaudeArgumentsTests: XCTestCase {
    func testNoFlagAndUnrelatedFlags() throws {
        for argv in [[], ["Claude"], ["Claude", "--unknown", "value", "--user-data-directory=/other"]] {
            XCTAssertNil(try ClaudeArguments.profileDirectory(in: argv))
        }
    }

    func testBothFormsPreserveSpacesAndEquals() throws {
        let path = "/profiles with space/Claude_name=one"
        for args in [["--user-data-dir=\(path)"], ["--user-data-dir", path]] {
            XCTAssertEqual(try ClaudeArguments.profileDirectory(in: ["Claude"] + args)?.path, path)
        }
    }

    func testStandardizesTrailingSlashAndDotComponents() throws {
        for path in ["/profiles/Claude/", "/profiles/./other/../Claude//"] {
            XCTAssertEqual(
                try ClaudeArguments.profileDirectory(in: ["--user-data-dir=\(path)"])?.path,
                "/profiles/Claude"
            )
        }
        XCTAssertEqual(try ClaudeArguments.profileDirectory(in: ["--user-data-dir=/"])?.path, "/")
    }

    func testDuplicateFlagsUseLastOccurrenceAcrossForms() throws {
        let examples = [
            ["--user-data-dir=/first", "--user-data-dir", "/last"],
            ["--user-data-dir", "/first", "--unknown", "--user-data-dir=/last"],
            ["--user-data-dir=relative", "--user-data-dir=/last"],
            ["--user-data-dir", "--user-data-dir=/last"],
            ["--user-data-dir=", "--user-data-dir=/last"],
        ]
        for argv in examples {
            XCTAssertEqual(try ClaudeArguments.profileDirectory(in: argv)?.path, "/last")
        }
    }

    func testMissingEmptyAndRelativePathsAreRejected() {
        let examples: [([String], ClaudeArguments.ParseError)] = [
            (["--user-data-dir"], .missingValue),
            (["--user-data-dir", "--unknown"], .missingValue),
            (["--user-data-dir="], .invalidPath),
            (["--user-data-dir", ""], .invalidPath),
            (["--user-data-dir=/contains\0nul"], .invalidPath),
            (["--user-data-dir=relative/path"], .relativePath),
            (["--user-data-dir", "./profile"], .relativePath),
            (["--user-data-dir=~/profile"], .relativePath),
            (["--user-data-dir=/valid", "--user-data-dir=relative"], .relativePath),
            (["--user-data-dir=/valid", "--user-data-dir"], .missingValue),
        ]
        for (argv, expected) in examples {
            XCTAssertThrowsError(try ClaudeArguments.profileDirectory(in: argv)) {
                XCTAssertEqual($0 as? ClaudeArguments.ParseError, expected)
            }
        }
    }

    func testEndOfOptionsStopsFlagParsing() throws {
        XCTAssertNil(try ClaudeArguments.profileDirectory(in: ["--", "--user-data-dir=/ignored"]))
        XCTAssertEqual(
            try ClaudeArguments.profileDirectory(in: ["--user-data-dir=/chosen", "--", "--user-data-dir=/ignored"])?.path,
            "/chosen"
        )
    }
}
