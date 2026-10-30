import Foundation
import XCTest
@testable import CompanionCore

@MainActor
final class CodePreferenceInheritanceTests: XCTestCase {
    func testConsentMatrixPreservesGateOtherFieldsAndMode() async throws {
        let h = try await EngineHarness()
        let target = try h.profile("Claude_204")
        let account = try XCTUnwrap(target.identity?.accountUUID)
        let file = target.url.appending(path: CodePreferenceInheritance.fileName)
        let service = CodePreferenceInheritance()
        for source in [false, true] {
            for choice in [nil, false, true] as [Bool?] {
                for gate in [nil, false, true] as [Bool?] {
                    var preferences: [String: Any] = ["unrelated": "keep"]
                    if let choice { preferences["bypassPermissionsOptInByAccount"] = [account: choice] }
                    if let gate { preferences["bypassPermissionsGateByAccount"] = [account: gate] }
                    let original = try JSONSerialization.data(withJSONObject: ["preferences": preferences, "outer": 42])
                    try AtomicFile.write(original, to: file, permissions: 0o640)
                    let prepared = try service.prepare(intent: CodePreferenceIntent(sourceAccountUUID: "source", bypassOptIn: source), target: target)
                    try service.apply(prepared)
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(file)) as? [String: Any])
                    let result = try XCTUnwrap(object["preferences"] as? [String: Any])
                    let choices = result["bypassPermissionsOptInByAccount"] as? [String: Bool]
                    let expected = choice ?? ((!source || gate == true) ? source : nil)
                    XCTAssertEqual(choices?[account], expected)
                    XCTAssertEqual((result["bypassPermissionsGateByAccount"] as? [String: Bool])?[account], gate)
                    XCTAssertEqual(result["unrelated"] as? String, "keep")
                    XCTAssertEqual(object["outer"] as? Int, 42)
                    XCTAssertEqual(try posixMode(of: file), 0o640)
                    if choice != nil || (source && gate != true) { XCTAssertEqual(try AtomicFile.read(file), original) }
                }
            }
        }
        await h.cleanup()
    }

    func testCaptureExplicitFalseAndRefuseConcurrentChangeAndNonRegularPaths() async throws {
        let h = try await EngineHarness()
        let source = try h.profile("Claude")
        let target = try h.profile("Claude_204")
        let service = CodePreferenceInheritance()
        let sourceFile = source.url.appending(path: CodePreferenceInheritance.fileName)
        try AtomicFile.write(try JSONSerialization.data(withJSONObject: ["preferences": [
            "bypassPermissionsOptInByAccount": [try XCTUnwrap(source.identity?.accountUUID): false]]]), to: sourceFile)
        let intent = try service.capture(profile: source)
        XCTAssertEqual(intent?.bypassOptIn, false)
        let file = target.url.appending(path: CodePreferenceInheritance.fileName)
        let prepared = try service.prepare(intent: intent, target: target)
        let concurrent = Data("{\"another\":true}".utf8)
        XCTAssertThrowsError(try service.apply(prepared, beforeCommit: {
            try AtomicFile.write(concurrent, to: file)
        })) { XCTAssertEqual($0 as? PreferenceInheritanceFailure, .concurrentChange) }
        XCTAssertEqual(try AtomicFile.read(file), concurrent)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: sourceFile)
        XCTAssertThrowsError(try service.prepare(intent: intent, target: target))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try service.prepare(intent: intent, target: target))
        await h.cleanup()
    }
}
