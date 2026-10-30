import XCTest
@testable import CompanionCore

final class SandboxFixtureTests: XCTestCase {
    private var scratch: ScratchDirectory!

    override func setUpWithError() throws {
        scratch = try ScratchDirectory()
    }

    override func tearDownWithError() throws {
        scratch.cleanup()
    }

    func testProcStartMatchesUTCPSFormat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let october24 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 9, minute: 0, second: 2))!
        let october3 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 1, minute: 2, second: 3))!
        XCTAssertEqual(SandboxFixture.procStartString(from: october24), "Sat Oct 24 09:00:02 2026")
        XCTAssertEqual(SandboxFixture.procStartString(from: october3), "Sat Oct  3 01:02:03 2026")
    }

    func testRootMustBeTemporaryOrNamedSandbox() throws {
        XCTAssertTrue(
            SandboxFixture.rootIsAllowed(
                scratch.root.appending(path: "world", directoryHint: .isDirectory),
                environment: ProcessInfo.processInfo.environment
            )
        )
        XCTAssertFalse(SandboxFixture.rootIsAllowed(URL(fileURLWithPath: "/Users/example"), environment: [:]))
        XCTAssertTrue(SandboxFixture.rootIsAllowed(URL(fileURLWithPath: "/opt/sandbox/demo"), environment: [:]))
        XCTAssertFalse(SandboxFixture.rootIsAllowed(URL(fileURLWithPath: "/opt/sandbox-demo"), environment: [:]))

        let repo = repositoryRoot()
        let forbidden = repo.appending(path: "fixture-root-refused", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: forbidden) }
        XCTAssertThrowsError(try SandboxFixture.standard().materialize(at: forbidden)) { error in
            guard case SandboxFixtureError.rootNotAllowed = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: forbidden.path))

        let link = scratch.root.appending(path: "escape-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)
        defer { try? FileManager.default.removeItem(at: repo.appending(path: "home")) }
        XCTAssertThrowsError(try SandboxFixture.standard().materialize(at: link)) { error in
            guard case SandboxFixtureError.rootNotAllowed = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appending(path: "home").path))

        var escaped = SandboxFixture.standard()
        escaped.profiles[0].folder = "../escape"
        let worldRoot = scratch.root.appending(path: "rejected", directoryHint: .isDirectory)
        XCTAssertThrowsError(try escaped.materialize(at: worldRoot)) { error in
            guard case SandboxFixtureError.invalidProfileFolder = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: worldRoot.appending(path: "home").path))
    }

    func testStandardWorldMatchesTheRealFormats() throws {
        var fixture = SandboxFixture.standard()
        let configStamp = Date(timeIntervalSince1970: 1_700_000_000)
        fixture.modifiedAt["home/Library/Application Support/Claude/config.json"] = configStamp
        fixture.profiles.append(.awaitingSignIn(folder: "Claude_Wait", displayName: "wait"))
        let world = try fixture.materialize(at: scratch.root.appending(path: "world", directoryHint: .isDirectory))

        let claude = world.profileDirectory("Claude")
        let account = claude
            .appending(path: "claude-code-sessions", directoryHint: .isDirectory)
            .appending(path: SandboxFixture.ID.defaultAccount, directoryHint: .isDirectory)
        let orgNames = try FileManager.default.contentsOfDirectory(atPath: account.path)
        XCTAssertEqual(
            Set(orgNames),
            [SandboxFixture.ID.defaultOrganization, SandboxFixture.ID.defaultOtherOrganization]
        )

        let activeBucket = account.appending(path: SandboxFixture.ID.defaultOrganization, directoryHint: .isDirectory)
        let index = try Data(contentsOf: activeBucket.appending(path: "archived-sessions.idx"))
        XCTAssertFalse(index.contains(0x0A))
        XCTAssertEqual(
            String(decoding: index, as: UTF8.self),
            "{\"v\":1,\"archived\":[\"local_\(SandboxFixture.ID.archivedSession)\"]}"
        )
        let emptyIndex = try String(
            contentsOf: account
                .appending(path: SandboxFixture.ID.defaultOtherOrganization)
                .appending(path: "archived-sessions.idx"),
            encoding: .utf8
        )
        XCTAssertEqual(emptyIndex, "{\"v\":1,\"archived\":[]}")
        XCTAssertFalse(emptyIndex.contains("\n"))

        var waiting: ObjCBool = false
        let waitingURL = activeBucket.appending(path: "waiting-input", directoryHint: .isDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: waitingURL.path, isDirectory: &waiting))
        XCTAssertTrue(waiting.boolValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: waitingURL.path), [])

        let tasks = try jsonObject(activeBucket.appending(path: "scheduled-tasks.json"))
        XCTAssertEqual((tasks["scheduledTasks"] as? [Any])?.count, 0)
        XCTAssertNotNil(tasks["recordedSkips"])
        XCTAssertEqual(tasks["sundayAliasBoundaryStamped"] as? Bool, false)
        XCTAssertEqual(tasks["dayFieldsOrBoundaryStamped"] as? Bool, false)

        let sessionURL = activeBucket.appending(path: "local_\(SandboxFixture.ID.liveSession).json")
        let session = try jsonObject(sessionURL)
        XCTAssertEqual(session["sessionId"] as? String, "local_\(SandboxFixture.ID.liveSession)")
        XCTAssertEqual(session["cliSessionId"] as? String, SandboxFixture.ID.liveSession)
        XCTAssertEqual(session["title"] as? String, "Current chat")
        XCTAssertEqual(session["isArchived"] as? Bool, false)
        XCTAssertEqual(session["lastFocusedAt"] as? Int, 1_792_832_402_000)
        XCTAssertNotNil(session["createdAt"])
        XCTAssertNotNil(session["lastActivityAt"])
        let marker = try XCTUnwrap(session["companionFixtureMarker"] as? [String: Any])
        XCTAssertEqual(marker["keep"] as? Bool, true)
        let cwd = try XCTUnwrap(session["cwd"] as? String)
        XCTAssertTrue(cwd.contains("My Project"))
        var cwdIsDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: cwd, isDirectory: &cwdIsDirectory))
        XCTAssertTrue(cwdIsDirectory.boolValue)
        let sessionModified = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: sessionURL.path)[.modificationDate] as? Date
        )
        XCTAssertEqual(sessionModified.timeIntervalSince1970, SandboxFixture.ID.referenceTimestamp, accuracy: 1)

        let configURL = claude.appending(path: "config.json")
        let config = try jsonObject(configURL)
        XCTAssertEqual(config["lastKnownAccountUuid"] as? String, SandboxFixture.ID.defaultAccount)
        XCTAssertEqual(config["locale"] as? String, "zh-CN")
        XCTAssertEqual(config["updaterLastSeenVersion"] as? String, "1.2.3")
        let updater = try XCTUnwrap(config["updaterRunningInstance"] as? [String: Any])
        XCTAssertEqual(updater["pid"] as? Int, 999001)
        XCTAssertEqual(
            config["dxt:allowlistLastUpdated:\(SandboxFixture.ID.defaultOrganization)"] as? String,
            SandboxFixture.ID.activeStamp
        )
        XCTAssertEqual(
            config["dxt:allowlistLastUpdated:\(SandboxFixture.ID.defaultOtherOrganization)"] as? String,
            SandboxFixture.ID.olderStamp
        )
        XCTAssertFalse(config.keys.contains { $0.lowercased().hasPrefix("oauth") })
        let configModified = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate] as? Date
        )
        XCTAssertEqual(configModified.timeIntervalSince1970, configStamp.timeIntervalSince1970, accuracy: 1)

        let usage = try jsonObject(claude.appending(path: "plan-usage-history.json"))
        XCTAssertEqual(usage["version"] as? Int, 2)
        let samples = try XCTUnwrap(usage["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.first?["org"] as? String, SandboxFixture.ID.defaultOrganization)
        let used = try XCTUnwrap(samples.first?["u"] as? [String: Any])
        XCTAssertEqual(used["fh"] as? Int, 12)
        XCTAssertEqual(used["sd"] as? Int, 34)

        let waitingProfile = world.profileDirectory("Claude_Wait")
        let waitingConfig = try jsonObject(waitingProfile.appending(path: "config.json"))
        XCTAssertNil(waitingConfig["lastKnownAccountUuid"])
        XCTAssertFalse(waitingConfig.keys.contains { $0.hasPrefix("dxt:") || $0.lowercased().hasPrefix("oauth") })
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: waitingProfile.appending(path: "claude-code-sessions").path
            )
        )

        let busy = try XCTUnwrap(world.cliSessions.first { $0.status == "busy" })
        XCTAssertEqual(busy.cliSessionID, SandboxFixture.ID.session203)
        XCTAssertEqual(busy.procStart, "Sat Oct 24 09:00:02 2026")
        XCTAssertNotEqual(busy.hostSessionID, busy.cliSessionID)
        XCTAssertTrue(busy.hostSessionID.hasPrefix("local_"))
        var projectIsDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: busy.cwd.path, isDirectory: &projectIsDirectory))
        XCTAssertTrue(projectIsDirectory.boolValue)

        let registry = try jsonObject(busy.registryFile)
        XCTAssertEqual(
            Set(registry.keys),
            [
                "pid", "sessionId", "cwd", "startedAt", "procStart", "version", "peerProtocol",
                "peerFeatures", "kind", "entrypoint", "hostSessionId", "pidDomain",
                "messagingSocketPath", "name", "nameSince", "updatedAt", "status", "statusUpdatedAt",
            ]
        )
        XCTAssertEqual(registry["entrypoint"] as? String, "claude-desktop")
        XCTAssertEqual(registry["status"] as? String, "busy")
        XCTAssertEqual(registry["sessionId"] as? String, busy.cliSessionID)
        XCTAssertEqual(registry["procStart"] as? String, "Sat Oct 24 09:00:02 2026")
        XCTAssertEqual(registry["pid"] as? Int, busy.pid)

        let transcript = try String(contentsOf: busy.transcriptFile, encoding: .utf8)
        let lines = transcript.split(separator: "\n").map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 2)
        for line in lines {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let type = try XCTUnwrap(row["type"] as? String)
            XCTAssertTrue(type == "user" || type == "assistant")
            XCTAssertEqual(row["sessionId"] as? String, busy.cliSessionID)
            XCTAssertFalse((row["sessionId"] as? String ?? "").hasPrefix("local_"))
        }
    }

    private func jsonObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        let fileManager = FileManager.default
        while url.path != "/" {
            url.deleteLastPathComponent()
            if fileManager.fileExists(atPath: url.appending(path: "Package.swift").path) {
                return url
            }
        }
        return URL(fileURLWithPath: fileManager.currentDirectoryPath)
    }
}
