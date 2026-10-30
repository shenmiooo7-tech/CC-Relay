import Foundation
import XCTest
@testable import CompanionCore

final class AutoCompactLinkTests: XCTestCase {
    func testSettingsCarryTheSwitchAndThePluginLanguage() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let link = AutoCompactLink(paths: world.paths)
        try link.writeSettings(enabled: false, language: .system, preferredLanguages: ["zh-Hans-CN"])
        let url = link.directory.appending(path: "settings.json")
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(url)) as? [String: Any])
        XCTAssertEqual(written["enabled"] as? Bool, false)
        XCTAssertEqual(written["language"] as? String, "zh-Hans")
        XCTAssertEqual(AutoCompactLink.pluginLanguage(.system, preferredLanguages: ["fr-FR", "zh-Hans"]), "en")
        XCTAssertEqual(AutoCompactLink.pluginLanguage(.en, preferredLanguages: ["zh-Hans"]), "en")
        XCTAssertEqual(AutoCompactLink.pluginLanguage(.zhHans, preferredLanguages: []), "zh-Hans")
    }

    func testStatusCountsRecentReportsAndIgnoresBrokenFiles() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let link = AutoCompactLink(paths: world.paths)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(link.status(now: now), AutoCompactStatus())
        let sessions = link.directory.appending(path: "sessions")
        try report(["updatedAt": milliseconds(now.addingTimeInterval(-30))], to: sessions.appending(path: "live.json"))
        try report(["updatedAt": milliseconds(now.addingTimeInterval(-600))], to: sessions.appending(path: "old.json"))
        try AtomicFile.write(Data("not json".utf8), to: sessions.appending(path: "broken.json"))
        let status = link.status(now: now)
        XCTAssertEqual(status.liveConversations, 1)
        XCTAssertEqual(status.lastReport, now.addingTimeInterval(-30))
    }

    func testResultsAreReportedOnceOldestFirstAndBrokenOnesAreSetAside() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let link = AutoCompactLink(paths: world.paths)
        let results = link.directory.appending(path: "results")
        let first = Date(timeIntervalSince1970: 1_800_000_000), second = first.addingTimeInterval(60)
        try report(["reason": "early", "status": "compacted", "tokensBefore": 300_000, "tokensAfter": NSNull(),
                    "finishedAt": milliseconds(second), "resumed": false], to: results.appending(path: "b.json"))
        try report(["reason": "hard", "status": "failed", "tokensBefore": 500_000, "finishedAt": milliseconds(first),
                    "resumed": true], to: results.appending(path: "a.json"))
        try report(["reason": "sideways", "status": "compacted", "tokensBefore": 1, "finishedAt": milliseconds(first)],
                   to: results.appending(path: "c.json"))
        let taken = link.takeResults()
        XCTAssertEqual(taken, [
            AutoCompactResult(trigger: .hard, outcome: .failed, tokensBefore: 500_000, tokensAfter: nil, finishedAt: first, resumed: true),
            AutoCompactResult(trigger: .early, outcome: .compacted, tokensBefore: 300_000, tokensAfter: nil, finishedAt: second, resumed: false),
        ])
        XCTAssertEqual(link.takeResults(), [])
        let seen = try FileManager.default.contentsOfDirectory(atPath: results.appending(path: "seen").path)
        XCTAssertEqual(Set(seen), ["a.json", "b.json", "c.json"])
    }

    func testAResultKeepsTheHostReasonOnOneShortLine() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let link = AutoCompactLink(paths: world.paths)
        let results = link.directory.appending(path: "results")
        let finished = milliseconds(Date(timeIntervalSince1970: 1_800_000_000))
        try report(["reason": "early", "status": "failed", "tokensBefore": 468_539, "finishedAt": finished,
                    "error": "Unknown command\n  /compact"], to: results.appending(path: "a.json"))
        try report(["reason": "early", "status": "failed", "tokensBefore": 1, "finishedAt": finished + 1,
                    "error": String(repeating: "a", count: 300)], to: results.appending(path: "b.json"))
        try report(["reason": "early", "status": "compacted", "tokensBefore": 1, "finishedAt": finished + 2,
                    "error": NSNull()], to: results.appending(path: "c.json"))
        try report(["reason": "early", "status": "skipped", "tokensBefore": 1, "finishedAt": finished + 3,
                    "error": " \n "], to: results.appending(path: "d.json"))
        XCTAssertEqual(link.takeResults().map(\.error), ["Unknown command /compact", String(repeating: "a", count: 200), nil, nil])
    }

    func testARequestBeforeASwitchNamesOneLiveConversationAndTakesOnlyItsOwnAnswer() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let link = AutoCompactLink(paths: world.paths)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessions = link.directory.appending(path: "sessions")
        XCTAssertEqual(link.switchReadiness(sessionID: "s-1", now: now), .notReporting)
        try report(["updatedAt": milliseconds(now.addingTimeInterval(-30)), "switchRequests": true], to: sessions.appending(path: "s-1.json"))
        try report(["updatedAt": milliseconds(now.addingTimeInterval(-121)), "switchRequests": true], to: sessions.appending(path: "s-2.json"))
        try report(["updatedAt": milliseconds(now.addingTimeInterval(-30))], to: sessions.appending(path: "s-3.json"))
        XCTAssertEqual(link.switchReadiness(sessionID: "s-1", now: now), .ready)
        XCTAssertEqual(link.switchReadiness(sessionID: "s-2", now: now), .notReporting)
        XCTAssertEqual(link.switchReadiness(sessionID: "s-3", now: now), .outdated)
        XCTAssertEqual(link.switchReadiness(sessionID: "../sessions/s-1", now: now), .notReporting)

        let request = link.directory.appending(path: "switch-request.json")
        XCTAssertThrowsError(try link.requestCompaction(id: 7, sessionID: "a/b", until: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.path))
        try link.requestCompaction(id: 7, sessionID: "s-1", until: now.addingTimeInterval(190))
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: AtomicFile.read(request)) as? [String: Any])
        XCTAssertEqual(written["id"] as? Int, 7)
        XCTAssertEqual(written["sessionID"] as? String, "s-1")
        XCTAssertEqual((written["until"] as? NSNumber)?.int64Value, milliseconds(now.addingTimeInterval(190)))

        let result = link.directory.appending(path: "switch-result.json")
        XCTAssertNil(link.compactionAnswer(id: 7))
        try report(["id": 6, "status": "compacted", "tokensBefore": 400_000, "tokensAfter": 30_000], to: result)
        XCTAssertNil(link.compactionAnswer(id: 7))
        try report(["id": 7, "status": "sideways"], to: result)
        XCTAssertNil(link.compactionAnswer(id: 7))
        try report(["id": 7, "status": "compacted", "tokensBefore": 400_000, "tokensAfter": 30_000, "error": NSNull()], to: result)
        XCTAssertEqual(link.compactionAnswer(id: 7), SwitchCompactionAnswer(outcome: .compacted, tokensBefore: 400_000, tokensAfter: 30_000))
        try report(["id": 7, "status": "failed", "tokensBefore": -1, "error": "Unknown command\n  /compact"], to: result)
        XCTAssertEqual(link.compactionAnswer(id: 7), SwitchCompactionAnswer(outcome: .failed, error: "Unknown command /compact"))

        link.withdrawRequest()
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.path))
        link.withdrawRequest()
    }

    func testTheSessionIDRuleKeepsARequestToOneFileName() {
        XCTAssertTrue(AutoCompactLink.validSessionID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"))
        XCTAssertTrue(AutoCompactLink.validSessionID(String(repeating: "a", count: 64)))
        for id in ["", String(repeating: "a", count: 65), "a/b", "..", "a b", "a_b", "é"] {
            XCTAssertFalse(AutoCompactLink.validSessionID(id), id)
        }
    }

    func testACompactionBeforeASwitchIsReadWithItsOwnTrigger() throws {
        let world = try SessionTestWorld()
        defer { world.cleanup() }
        let link = AutoCompactLink(paths: world.paths)
        let finished = Date(timeIntervalSince1970: 1_800_000_000)
        try report(["reason": "switch", "status": "compacted", "tokensBefore": 400_000, "tokensAfter": 30_000,
                    "finishedAt": milliseconds(finished), "resumed": false], to: link.directory.appending(path: "results/a.json"))
        XCTAssertEqual(link.takeResults(), [AutoCompactResult(trigger: .beforeSwitch, outcome: .compacted, tokensBefore: 400_000,
                                                              tokensAfter: 30_000, finishedAt: finished, resumed: false)])
    }

    private func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    private func report(_ object: [String: Any], to url: URL) throws {
        try AtomicFile.write(JSONSerialization.data(withJSONObject: object), to: url)
    }
}
