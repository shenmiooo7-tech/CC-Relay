import CompanionCore
import Foundation
import XCTest
@testable import CompanionPlatform

final class InstanceMappingTests: XCTestCase {
    private let main = URL(fileURLWithPath: "/fixture/Claude.app/Contents/MacOS/Claude")
    private let fallback = URL(fileURLWithPath: "/fixture/Application Support/Claude", isDirectory: true)

    func testBothExplicitFormsAndFlaglessDefaultPreserveIntent() throws {
        let path = "/fixture/Application Support/Claude Work"
        for argv in [[main.path], [main.path, "--user-data-dir=\(path)"], [main.path, "--user-data-dir", path]] {
            let record = ProcessRecord(pid: 42, ppid: 1, executableURL: main, argv: argv, startedAt: .distantPast)
            let instance = try XCTUnwrap(InstanceMapping.instance(record, mainExecutable: main, defaultProfile: fallback))
            XCTAssertEqual(instance.hasExplicitProfileFlag, argv.count > 1)
            XCTAssertEqual(instance.profileDirectory.path, argv.count > 1 ? path : fallback.path)
            XCTAssertEqual(instance.startedAt, .distantPast)
            XCTAssertEqual(InstanceMapping.event(instance).hasExplicitProfileFlag, argv.count > 1)
        }
        let record = ProcessRecord(pid: 42, ppid: 1, executableURL: main,
                                   argv: [main.path, "--user-data-dir=\(fallback.path)"], startedAt: .distantPast)
        XCTAssertTrue(try XCTUnwrap(InstanceMapping.instance(record, mainExecutable: main, defaultProfile: fallback)).hasExplicitProfileFlag)
    }

    func testHelpersAndOtherExecutablesNeverImplyDefault() throws {
        let helper = URL(fileURLWithPath: "/fixture/Claude.app/Contents/Frameworks")
            .appendingPathComponent("Claude Helper.app/Contents/MacOS").appendingPathComponent("Claude Helper").path
        for path in [helper,
                     main.path + " Helper", "/other/Claude.app/Contents/MacOS/Claude", "/bin/crashpad_handler"] {
            let record = ProcessRecord(pid: 1, ppid: 0, executableURL: URL(fileURLWithPath: path), argv: [path], startedAt: .distantPast)
            XCTAssertNil(try InstanceMapping.instance(record, mainExecutable: main, defaultProfile: fallback))
        }
    }

    func testMalformedProfileRemainsUnknown() {
        for arguments in [["--user-data-dir"], ["--user-data-dir="], ["--user-data-dir=relative"], ["--user-data-dir", "--other"]] {
            let record = ProcessRecord(pid: 2, ppid: 1, executableURL: main, argv: [main.path] + arguments, startedAt: .distantPast)
            XCTAssertThrowsError(try InstanceMapping.instance(record, mainExecutable: main, defaultProfile: fallback))
        }
    }

    func testDeepLinkValidation() throws {
        for id in ["local_A", "local_a-123", "local_" + String(repeating: "a", count: 64)] {
            try DeepLinkValidation.validate(URL(string: "claude://code/continue?session=\(id)")!)
        }
        for text in ["https://code/continue?session=local_a", "claude://code/continue?session=local_",
                     "claude://code/continue?session=local_a_", "claude://code/continue?session=local_a&other=b",
                     "claude://code/continue?session=local_" + String(repeating: "a", count: 65),
                     "claude://code/continue?session=local_a#fragment"] {
            XCTAssertThrowsError(try DeepLinkValidation.validate(URL(string: text)!)) {
                XCTAssertEqual($0 as? ClaudeProcessError, .invalidDeepLink)
            }
        }
    }
}
