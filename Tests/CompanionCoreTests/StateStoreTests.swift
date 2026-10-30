import XCTest
@testable import CompanionCore

final class StateStoreTests: XCTestCase {
    private var scratch: ScratchDirectory!

    override func setUpWithError() throws {
        scratch = try ScratchDirectory()
    }

    override func tearDownWithError() throws {
        scratch.cleanup()
    }

    func testMissingFileIsTheDefaultAndUpdateRoundTrips() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_792_832_402))
        let log = CompanionLog(paths: scratch.paths, clock: clock)
        let store = StateStore(paths: scratch.paths, log: log, clock: clock)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, CompanionState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.paths.companionDataDirectory.appending(path: "state.json").path))

        let folder = try ProfileFolder("Claude_Kxm2")
        try await store.update { state in
            state.activeFolder = folder
            state.accounts = [ManagedAccount(folder: folder, displayName: "203", addedAt: clock.now())]
        }
        let again = try await store.load()
        XCTAssertEqual(again.activeFolder, folder)
        XCTAssertEqual(again.accounts.map(\.displayName), ["203"])
    }

    func testCorruptStateIsPreservedAndNotLogged() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_792_832_402.345))
        let log = CompanionLog(paths: scratch.paths, clock: clock)
        let directory = scratch.paths.companionDataDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let secret = "super-secret-token dan@example.com 12345678-1234-1234-1234-123456789abc"
        let original = Data("{\"oauth:tokenCache\":\"\(secret)\"".utf8)
        let stateURL = directory.appending(path: "state.json")
        try original.write(to: stateURL)

        let store = StateStore(paths: scratch.paths, log: log, clock: clock)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, CompanionState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))

        let preserved = directory.appending(path: "state.corrupt-20261024-090002-345.json")
        XCTAssertEqual(try Data(contentsOf: preserved), original)

        let logText = try String(
            contentsOf: directory.appending(path: "Logs/cc-relay.log"),
            encoding: .utf8
        )
        XCTAssertTrue(logText.contains("state.corrupt-20261024-090002-345.json"))
        XCTAssertFalse(logText.contains("super-secret-token"))
        XCTAssertFalse(logText.contains("dan@example.com"))
        XCTAssertFalse(logText.contains("12345678-1234-1234-1234-123456789abc"))

        let folder = try ProfileFolder("Claude")
        try await store.update { state in
            state.activeFolder = folder
        }
        let saved = try await store.load()
        XCTAssertEqual(saved.activeFolder, folder)
        XCTAssertEqual(try Data(contentsOf: preserved), original)
    }

    func testQuotaCacheRoundTripAndCorruption() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_792_832_402))
        let log = CompanionLog(paths: scratch.paths, clock: clock)
        let store = QuotaCacheStore(paths: scratch.paths, log: log, clock: clock)
        let loaded = try await store.load()
        XCTAssertTrue(loaded.isEmpty)

        let folder = try ProfileFolder("Claude_204")
        let other = try ProfileFolder("Claude")
        let fetched = Date(timeIntervalSince1970: 1_792_832_402.345)
        let snapshot = QuotaSnapshot(
            folder: folder,
            accountUUID: "44444444-4444-4444-8444-444444444444",
            organizationUUID: "44444444-4444-4444-8444-444444444401",
            plan: "Max",
            email: "ada@example.com",
            channel: .web,
            fiveHour: QuotaWindow(usedPercent: 12.5, resetsAt: fetched),
            sevenDay: QuotaWindow(usedPercent: 40),
            fetchedAt: fetched,
            channelCheckedAt: fetched,
            source: .network
        )
        try await store.update { cache in
            cache[folder] = snapshot
            cache[other] = QuotaSnapshot(
                folder: other,
                accountUUID: "11111111-1111-4111-8111-111111111111",
                organizationUUID: "22222222-2222-4222-8222-222222222221",
                fetchedAt: fetched,
                source: .localHistory
            )
        }
        let again = try await store.load()
        XCTAssertEqual(again[folder], snapshot)
        XCTAssertEqual(again[other]?.source, .localHistory)

        let text = try String(
            contentsOf: scratch.paths.companionDataDirectory.appending(path: "quota-cache.json"),
            encoding: .utf8
        )
        XCTAssertTrue(text.contains("\"Claude\""))
        XCTAssertTrue(text.contains("\"Claude_204\""))
        let claude = text.range(of: "\"Claude\"")
        let suffixed = text.range(of: "\"Claude_204\"")
        XCTAssertLessThan(claude!.lowerBound, suffixed!.lowerBound)

        let cacheURL = scratch.paths.companionDataDirectory.appending(path: "quota-cache.json")
        try Data("not-json".utf8).write(to: cacheURL)
        let empty = try await store.load()
        XCTAssertTrue(empty.isEmpty)
        let preserved = scratch.paths.companionDataDirectory
            .appending(path: "quota-cache.corrupt-20261024-090002-000.json")
        XCTAssertEqual(try String(contentsOf: preserved, encoding: .utf8), "not-json")
    }

    func testUnknownLanguageKeepsAccounts() async throws {
        let json = """
        {"schemaVersion":1,"accounts":[{"folder":"Claude_204","displayName":"204","addedAt":"2026-10-24T00:00:00Z"}],
         "activeFolder":"Claude_204","settings":{"language":"ja"}}
        """
        try AtomicFile.write(Data(json.utf8), to: scratch.paths.companionDataDirectory.appending(path: "state.json"))
        let store = StateStore(paths: scratch.paths, log: CompanionLog(paths: scratch.paths))
        let state = try await store.load()
        XCTAssertEqual(state.accounts.map(\.displayName), ["204"])
        XCTAssertEqual(state.settings.language, .system)
    }

    func testSkippedAccountIsDroppedAndTheOriginalIsCopiedOnce() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_792_832_402.345))
        let log = CompanionLog(paths: scratch.paths, clock: clock)
        let directory = scratch.paths.companionDataDirectory
        let original = Data(
            """
            {"schemaVersion":1,"accounts":[
              {"folder":"Claude","displayName":"201","addedAt":"2026-10-24T00:00:00Z"},
              {"folder":"a/b","displayName":"ada@example.com","addedAt":"2026-10-24T00:00:00Z"},
              {"folder":"Claude_204","displayName":"204","addedAt":"2026-10-24T00:00:00Z"}
            ],"activeFolder":"Claude"}
            """.utf8
        )
        let stateURL = directory.appending(path: "state.json")
        try AtomicFile.write(original, to: stateURL)
        let store = StateStore(paths: scratch.paths, log: log, clock: clock)

        let first = try await store.load()
        let second = try await store.load()
        XCTAssertEqual(first.accounts.map(\.displayName), ["201", "204"])
        XCTAssertEqual(second.accounts.map(\.displayName), ["201", "204"])
        XCTAssertEqual(first.activeFolder, try ProfileFolder("Claude"))

        let partials = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("state.partial-") }
        XCTAssertEqual(partials, ["state.partial-20261024-090002-345.json"])
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: partials[0])), original)
        XCTAssertEqual(try Data(contentsOf: stateURL), original)

        let logText = try String(contentsOf: directory.appending(path: "Logs/cc-relay.log"), encoding: .utf8)
        XCTAssertTrue(logText.contains("accounts[1]"))
        XCTAssertTrue(logText.contains("state.partial-20261024-090002-345.json"))
        XCTAssertFalse(logText.contains("ada@example.com"))

        try await store.update { _ in }
        let saved = try await store.load()
        XCTAssertEqual(saved.accounts.map(\.displayName), ["201", "204"])
        let partialsAfterSave = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("state.partial-") }
        XCTAssertEqual(partialsAfterSave, partials)
        let rewritten = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertFalse(rewritten.contains("ada@example.com"))
        XCTAssertTrue(rewritten.contains("\"201\""))
        XCTAssertTrue(rewritten.contains("\"204\""))
    }

    func testQuotaCacheSkipsOneBadEntry() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_792_832_402))
        let log = CompanionLog(paths: scratch.paths, clock: clock)
        let directory = scratch.paths.companionDataDirectory
        let json = """
        {"Claude":{"folder":"Claude","accountUUID":"a","organizationUUID":"o","fetchedAt":"2026-10-24T00:00:00Z"},
         "Claude_204":{"folder":1}}
        """
        try AtomicFile.write(Data(json.utf8), to: directory.appending(path: "quota-cache.json"))
        let store = QuotaCacheStore(paths: scratch.paths, log: log, clock: clock)
        let cache = try await store.load()
        XCTAssertEqual(Set(cache.keys.map(\.name)), ["Claude"])
        let logText = try String(contentsOf: directory.appending(path: "Logs/cc-relay.log"), encoding: .utf8)
        XCTAssertTrue(logText.contains("Claude_204"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appending(path: "quota-cache.corrupt-20261024-090002-000.json").path
            )
        )
    }
}
