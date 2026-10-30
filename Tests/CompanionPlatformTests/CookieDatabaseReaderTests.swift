import Foundation
import SQLite3
import XCTest
import CompanionPlatform

final class CookieDatabaseReaderTests: XCTestCase {
    func testNewestMatchingCookieWinsAndRawBlobIsPreserved() throws {
        let fixture = try CookieFixture()
        defer { fixture.remove() }
        try fixture.insert(host: "claude.ai", accessed: 1, value: "older", encrypted: [1])
        try fixture.insert(host: ".claude.ai", accessed: 10, value: "", encrypted: [0, 0xff, 0x76, 0])
        try fixture.insert(host: "claude.ai.evil.invalid", accessed: 100, value: "ignored")
        try fixture.insert(host: "other.invalid", accessed: 200, value: "ignored")
        try fixture.insert(host: "claude.ai", accessed: 300, value: "ignored", name: "otherCookie")
        let cookie = try XCTUnwrap(CookieDatabaseReader().sessionCookie(profile: fixture.profile))
        XCTAssertEqual(cookie.hostKey, ".claude.ai")
        XCTAssertEqual(cookie.encryptedValue, Data([0, 0xff, 0x76, 0]))
        XCTAssertEqual(cookie.value, "")
        XCTAssertEqual(cookie.databaseVersion, 0)
    }

    func testPlaintextValueAndEmptyBlob() throws {
        let fixture = try CookieFixture()
        defer { fixture.remove() }
        try fixture.insert(host: "claude.ai", accessed: 1, value: "fixture-session")
        let cookie = try XCTUnwrap(CookieDatabaseReader().sessionCookie(profile: fixture.profile))
        XCTAssertEqual(cookie.hostKey, "claude.ai")
        XCTAssertEqual(cookie.value, "fixture-session")
        XCTAssertTrue(cookie.encryptedValue.isEmpty)
    }

    func testOnlyOtherHostsOrEmptyTableReturnsNil() throws {
        let fixture = try CookieFixture()
        defer { fixture.remove() }
        let reader = CookieDatabaseReader()
        XCTAssertNil(try reader.sessionCookie(profile: fixture.profile))
        for host in ["notclaude.ai", "www.claude.ai", "CLAUDE.AI", "claude.ai.invalid"] {
            try fixture.insert(host: host, accessed: 1, value: "ignored")
        }
        XCTAssertNil(try reader.sessionCookie(profile: fixture.profile))
    }

    func testMissingFileReturnsNilWithoutCreatingDatabase() throws {
        let directory = try PlatformTestDirectory()
        defer { directory.remove() }
        XCTAssertNil(try CookieDatabaseReader().sessionCookie(profile: directory.root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.root.path), [])
    }

    func testMissingTableThrowsTypedError() throws {
        let fixture = try CookieFixture(createTable: false)
        defer { fixture.remove() }
        XCTAssertThrowsError(try CookieDatabaseReader().sessionCookie(profile: fixture.profile)) {
            XCTAssertEqual($0 as? CookieDatabaseError, .queryFailed(SQLITE_ERROR))
        }
    }

    func testNetworkDirectoryFallbackAndURICharacters() throws {
        let fixture = try CookieFixture(network: true)
        defer { fixture.remove() }
        try fixture.insert(host: ".claude.ai", accessed: 1, value: "network-cookie")
        let record = try CookieDatabaseReader().sessionCookie(profile: fixture.profile)
        XCTAssertEqual(record?.value, "network-cookie")
    }

    func testRootDatabaseTakesPrecedenceOverNetworkDatabase() throws {
        let fixture = try CookieFixture()
        defer { fixture.remove() }
        try fixture.insert(host: "claude.ai", accessed: 1, value: "root-cookie")
        let network = fixture.profile.appendingPathComponent("Network", isDirectory: true)
        try FileManager.default.createDirectory(at: network, withIntermediateDirectories: false)
        try Data("invalid database".utf8).write(to: network.appendingPathComponent("Cookies"), options: .atomic)
        XCTAssertEqual(try CookieDatabaseReader().sessionCookie(profile: fixture.profile)?.value, "root-cookie")
    }

    func testExistingInvalidRootDoesNotFallBack() throws {
        let fixture = try CookieFixture(network: true)
        defer { fixture.remove() }
        try fixture.insert(host: "claude.ai", accessed: 1, value: "network-cookie")
        try Data("invalid".utf8).write(to: fixture.profile.appendingPathComponent("Cookies"), options: .atomic)
        XCTAssertThrowsError(try CookieDatabaseReader().sessionCookie(profile: fixture.profile))
    }

    func testCommittedWALRowsAreVisible() throws {
        let fixture = try CookieFixture()
        defer { fixture.remove() }
        try fixture.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        try fixture.insert(host: "claude.ai", accessed: 1, value: "from-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.database.path + "-wal"))
        XCTAssertEqual(try CookieDatabaseReader().sessionCookie(profile: fixture.profile)?.value, "from-wal")
    }

    func testExclusiveLockUsesPrivateCopyAndRemovesIt() throws {
        let fixture = try CookieFixture()
        defer { fixture.remove() }
        try fixture.insert(host: "claude.ai", accessed: 1, value: "snapshot-cookie")
        try fixture.execute("BEGIN EXCLUSIVE")
        defer { try? fixture.execute("ROLLBACK") }
        let reader = CookieDatabaseReader(temporaryDirectory: fixture.scratch)
        let clock = ContinuousClock()
        let started = clock.now
        XCTAssertEqual(try reader.sessionCookie(profile: fixture.profile)?.value, "snapshot-cookie")
        XCTAssertGreaterThanOrEqual(started.duration(to: clock.now), .seconds(2.9))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.scratch.path), [])
        XCTAssertEqual(sqlite3_get_autocommit(fixture.handle), 0)
    }

    func testPrivateCopyRollsBackHotJournalWithoutChangingOriginal() throws {
        let fixture = try CookieFixture()
        defer { fixture.remove() }
        try fixture.insert(host: "claude.ai", accessed: 1, value: "committed-cookie")
        try fixture.execute("""
            PRAGMA cache_size=1;
            PRAGMA cache_spill=ON;
            BEGIN EXCLUSIVE;
            UPDATE cookies SET value = 'uncommitted-cookie';
            """)
        defer { try? fixture.execute("ROLLBACK") }
        // Force dirty pages to disk so the copied database needs journal recovery.
        try fixture.insert(host: "other.invalid", accessed: 2, value: String(repeating: "x", count: 65_536))
        XCTAssertEqual(sqlite3_db_cacheflush(fixture.handle), SQLITE_OK)
        let journal = URL(fileURLWithPath: fixture.database.path + "-journal")
        let databaseBefore = try Data(contentsOf: fixture.database)
        let journalBefore = try Data(contentsOf: journal)

        let reader = CookieDatabaseReader(temporaryDirectory: fixture.scratch)
        XCTAssertEqual(try reader.sessionCookie(profile: fixture.profile)?.value, "committed-cookie")
        XCTAssertEqual(try Data(contentsOf: fixture.database), databaseBefore)
        XCTAssertEqual(try Data(contentsOf: journal), journalBefore)
        XCTAssertEqual(sqlite3_get_autocommit(fixture.handle), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.scratch.path), [])
    }

    func testFailedSnapshotReadAlsoRemovesPrivateCopy() throws {
        let fixture = try CookieFixture(createTable: false)
        defer { fixture.remove() }
        try fixture.execute("CREATE TABLE unrelated (id INTEGER); BEGIN EXCLUSIVE;")
        defer { try? fixture.execute("ROLLBACK") }
        XCTAssertThrowsError(try CookieDatabaseReader(temporaryDirectory: fixture.scratch).sessionCookie(profile: fixture.profile))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.scratch.path), [])
    }
}

private final class CookieFixture {
    let directory: PlatformTestDirectory
    let profile: URL
    let database: URL
    let scratch: URL
    let handle: OpaquePointer

    init(network: Bool = false, createTable: Bool = true) throws {
        directory = try PlatformTestDirectory()
        profile = directory.root.appendingPathComponent("profile with space #?%", isDirectory: true)
        scratch = directory.root.appendingPathComponent("snapshots", isDirectory: true)
        let databaseParent = network ? profile.appendingPathComponent("Network", isDirectory: true) : profile
        database = databaseParent.appendingPathComponent("Cookies")
        try FileManager.default.createDirectory(at: databaseParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        var opened: OpaquePointer?
        guard sqlite3_open(database.path, &opened) == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            directory.remove()
            throw CocoaError(.fileWriteUnknown)
        }
        handle = opened
        if createTable {
            try execute("""
                CREATE TABLE cookies (
                    creation_utc INTEGER NOT NULL DEFAULT 0,
                    host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL DEFAULT '',
                    name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL,
                    path TEXT NOT NULL DEFAULT '/', expires_utc INTEGER NOT NULL DEFAULT 0,
                    is_secure INTEGER NOT NULL DEFAULT 1, is_httponly INTEGER NOT NULL DEFAULT 1,
                    last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL DEFAULT 1,
                    is_persistent INTEGER NOT NULL DEFAULT 1, priority INTEGER NOT NULL DEFAULT 1,
                    samesite INTEGER NOT NULL DEFAULT -1, source_scheme INTEGER NOT NULL DEFAULT 2,
                    source_port INTEGER NOT NULL DEFAULT 443, last_update_utc INTEGER NOT NULL DEFAULT 0
                );
                """)
        }
    }

    func remove() {
        sqlite3_close(handle)
        directory.remove()
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw CookieDatabaseError.queryFailed(sqlite3_errcode(handle))
        }
    }

    func insert(host: String, accessed: Int64, value: String, encrypted: [UInt8] = [], name: String = "sessionKey") throws {
        let sql = "INSERT INTO cookies (host_key, name, value, encrypted_value, last_access_utc) VALUES (?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CookieDatabaseError.queryFailed(sqlite3_errcode(handle))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, host, -1, transient)
        sqlite3_bind_text(statement, 2, name, -1, transient)
        sqlite3_bind_text(statement, 3, value, -1, transient)
        if encrypted.isEmpty {
            sqlite3_bind_zeroblob(statement, 4, 0)
        } else {
            _ = encrypted.withUnsafeBytes {
                sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), transient)
            }
        }
        sqlite3_bind_int64(statement, 5, accessed)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CookieDatabaseError.queryFailed(sqlite3_errcode(handle))
        }
    }
}
