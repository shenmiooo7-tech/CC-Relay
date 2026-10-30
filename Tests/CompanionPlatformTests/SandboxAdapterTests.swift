import CompanionCore
import Foundation
import SQLite3
import XCTest
@testable import CompanionPlatform

@MainActor
final class SandboxAdapterTests: XCTestCase {
    func testLoginItemIsAtomicEscapesXMLAndDisableIsIdempotent() async throws {
        let directory = try PlatformTestDirectory()
        defer { directory.remove() }
        let login = SandboxLoginItem(root: directory.root)
        let before = try await login.isEnabled
        XCTAssertFalse(before)
        let executable = directory.root.appendingPathComponent("A & B <app> \"quoted\" 'name'")
        try await login.enable(executable: executable)
        let file = AppPaths.sandbox(root: directory.root).launchAgentsDirectory.appendingPathComponent(AppIdentity.bundleIdentifier + ".plist")
        let data = try Data(contentsOf: file)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, AppIdentity.bundleIdentifier)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [executable.path])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["ProcessType"] as? String, "Interactive")
        let xml = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(xml.contains("&amp;"))
        XCTAssertTrue(xml.contains("&lt;app&gt;"))
        try await login.enable(executable: executable.appendingPathExtension("new"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), [file.lastPathComponent])
        try await login.disable()
        try await login.disable()
        let after = try await login.isEnabled
        XCTAssertFalse(after)
    }

    func testBundleIdentityMatchesPackagingConfiguration() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let configuration = try String(contentsOf: repository.appendingPathComponent("scripts/app-config.sh"), encoding: .utf8)
        let assignments = configuration.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("CC_RELAY_BUNDLE_IDENTIFIER=") }
        XCTAssertEqual(assignments.count, 1)
        let assignment = try XCTUnwrap(assignments.first)
        let value = assignment.dropFirst("CC_RELAY_BUNDLE_IDENTIFIER=".count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        XCTAssertEqual(value, AppIdentity.bundleIdentifier)
    }

    func testTaskScript() async throws {
        let directory = try PlatformTestDirectory()
        defer { directory.remove() }
        let inspector = SandboxTaskInspector(root: directory.root)
        let missing = await inspector.activity()
        XCTAssertEqual(missing, .unknown(TaskUnknownReason.registryUnreadable))
        try AtomicFile.write(Data("{\"status\":\"idle\"}".utf8), to: inspector.stateFile)
        let idle = await inspector.activity()
        XCTAssertEqual(idle, .idle)
        try AtomicFile.write(Data("{\"status\":\"busy\",\"tasks\":[{\"pid\":42,\"shellChild\":43}]}".utf8), to: inspector.stateFile)
        let busy = await inspector.activity()
        XCTAssertEqual(busy, .busy([CodeTaskInfo(pid: 42, reason: .shellChild(pid: 43))]))
        try AtomicFile.write(Data("{\"status\":\"future\"}".utf8), to: inspector.stateFile)
        let unknown = await inspector.activity()
        XCTAssertEqual(unknown, .unknown(TaskUnknownReason.registryMismatch))
    }

    func testCookieAdapterPreservesBlobAndDatabaseVersionAndNeverDecrypts() throws {
        let directory = try PlatformTestDirectory()
        defer { directory.remove() }
        let profile = directory.root.appendingPathComponent("profile with space")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(profile.appendingPathComponent("Cookies").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, """
            CREATE TABLE meta (key TEXT, value TEXT);
            INSERT INTO meta VALUES ('version','24');
            CREATE TABLE cookies (host_key TEXT, name TEXT, encrypted_value BLOB, value TEXT, last_access_utc INTEGER);
            INSERT INTO cookies VALUES ('.claude.ai','sessionKey',X'76313000FF','',1);
            """, nil, nil, nil), SQLITE_OK)
        let cookie = try XCTUnwrap(SandboxSessionCookieReader(root: directory.root).sessionCookie(profile: profile))
        XCTAssertEqual(cookie.encryptedValue, Data([0x76, 0x31, 0x30, 0, 0xff]))
        XCTAssertEqual(cookie.hostKey, ".claude.ai")
        XCTAssertEqual(cookie.databaseVersion, 24)
        XCTAssertNil(cookie.plaintextValue)
    }

    func testSandboxReadersRejectEscapingSymlinks() throws {
        let directory = try PlatformTestDirectory()
        defer { directory.remove() }
        let profile = directory.root.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: profile.appendingPathComponent("Cookies"),
                                                 withDestinationURL: URL(fileURLWithPath: "/outside-fixture/Cookies"))
        XCTAssertThrowsError(try SandboxSessionCookieReader(root: directory.root).sessionCookie(profile: profile))
    }

    func testFixedKeyAndVersionPlists() async throws {
        let password = try await FixedSafeStorageKeyProvider(password: Data("fixture".utf8)).password()
        XCTAssertEqual(password, Data("fixture".utf8))
        let directory = try PlatformTestDirectory()
        defer { directory.remove() }
        let claudePlist = directory.root.appendingPathComponent("Contents/Info.plist")
        let electronPlist = directory.root.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
            .appendingPathComponent("Resources/Info.plist")
        for (url, version) in [(claudePlist, "1.2.3"), (electronPlist, "40.0.1")] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
            try AtomicFile.write(data, to: url)
        }
        let versions = ClaudeVersionReader.readBundle(directory.root)
        XCTAssertEqual(versions.claude, "1.2.3")
        XCTAssertEqual(versions.electron, "40.0.1")
    }
}
