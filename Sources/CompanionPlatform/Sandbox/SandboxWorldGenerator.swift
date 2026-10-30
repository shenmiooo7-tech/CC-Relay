import CompanionCore
import Foundation
import SQLite3

public enum SandboxGenerationError: Error, Sendable {
    case destinationNotEmpty
    case cookieDatabase
}

public enum SandboxWorldGenerator {
    public static func fakeClaudeExecutable(root: URL) -> URL {
        root.appendingPathComponent("Applications/FakeClaude")
    }

    /// A fresh destination avoids overwriting a sandbox that contains someone's work.
    public static func generate(at root: URL, fakeClaude source: URL,
                                fixture: SandboxFixture = .standard()) throws -> SandboxWorld {
        let files = FileManager.default
        guard (try? files.destinationOfSymbolicLink(atPath: root.path)) == nil else {
            throw SandboxGenerationError.destinationNotEmpty
        }
        if files.fileExists(atPath: root.path), try !files.contentsOfDirectory(atPath: root.path).isEmpty {
            throw SandboxGenerationError.destinationNotEmpty
        }
        // The caller explicitly chose this empty root. FixtureWriter still checks every child path.
        let world = try fixture.materialize(at: root, environment: ["TMPDIR": root.path])
        let executable = fakeClaudeExecutable(root: world.root)
        try files.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(Data(contentsOf: source), to: executable, permissions: 0o700)
        try writeJSON(["status": "idle"], to: world.root.appendingPathComponent("task-state.json"))
        try writePlist(["CFBundleShortVersionString": "1.2.3"],
            to: world.paths.claudeAppURL.appendingPathComponent("Contents/Info.plist"))
        try writePlist(["CFBundleShortVersionString": "40.0.0"], to: world.paths.claudeAppURL
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework/Resources/Info.plist"))
        for (index, profile) in fixture.profiles.enumerated() {
            guard let account = profile.accountUUID, let org = profile.organizations.first?.uuid else { continue }
            let email = profile.email ?? "account\(index + 1)@example.com"
            try installSignIn(root: world.root, folder: ProfileFolder(profile.folder), account: account,
                organization: org, email: email, fiveHourUsed: Double((index + 1) * 10))
        }
        try writeJSON(["schemaVersion": 1, "fakeClaude": executable.path],
            to: world.root.appendingPathComponent("sandbox.json"))
        return world
    }

    /// Simulates a completed sign-in, including a Chromium v24 encrypted cookie database.
    public static func installSignIn(root: URL, folder: ProfileFolder, account: String,
                                     organization: String, email: String, fiveHourUsed: Double = 27,
                                     now: Date = Date()) throws {
        let boundary = SandboxBoundary(root: root)
        let profile = AppPaths.sandbox(root: root).claudeProfilesRoot.appendingPathComponent(folder.name)
        try boundary.check(profile)
        guard UUID(uuidString: organization) != nil else { throw SandboxAdapterError.invalidState }
        let config = profile.appendingPathComponent("config.json")
        try boundary.check(config)
        var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: config))) as? [String: Any] ?? [:]
        object["lastKnownAccountUuid"] = account
        object["dxt:allowlistLastUpdated:" + organization] = SandboxFixture.ID.activeStamp
        try writeJSON(object, to: config)
        let base = root.appendingPathComponent("fixtures/http/\(folder.name)/api")
        let responses: [(URL, [String: Any])] = [
            (base.appendingPathComponent("account.json"), ["uuid": account, "email_address": email,
                "memberships": [["organization": ["uuid": organization, "analytics_subscription_plan": "claude_pro"]]]]),
            (base.appendingPathComponent("organizations/\(organization)/usage.json"), [
                "five_hour": ["utilization": fiveHourUsed, "resets_at": resetStamp(now, after: fiveHourResetDelay)],
                "seven_day": ["utilization": 42, "resets_at": resetStamp(now, after: weeklyResetDelay)]]),
            (base.appendingPathComponent("organizations/\(organization)/subscription_details.json"),
                ["subscription_details_url": "https://apps.apple.com/account/subscriptions"]),
        ]
        for (url, response) in responses { try boundary.check(url); try writeJSON(response, to: url) }
        let cookie = profile.appendingPathComponent("Cookies")
        try boundary.check(cookie)
        try writeCookie(folder: folder, to: cookie)
    }

    /// Resets a few hours and days after the sign-in, so the panel shows ordinary countdowns
    /// for a whole testing session instead of one that runs for decades.
    static let fiveHourResetDelay: TimeInterval = 4 * 3600
    static let weeklyResetDelay: TimeInterval = 4 * 86_400

    static func resetStamp(_ now: Date, after delay: TimeInterval) -> String {
        let minute = (now.addingTimeInterval(delay).timeIntervalSince1970 / 60).rounded(.down) * 60
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: minute))
    }

    private static func writeCookie(folder: ProfileFolder, to url: URL) throws {
        let stage = url.deletingLastPathComponent().appendingPathComponent(".fixture-cookie-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        var database: OpaquePointer?
        guard sqlite3_open(stage.path, &database) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SandboxGenerationError.cookieDatabase
        }
        let blob: Data
        do {
            blob = try ChromiumCookieEncryptor.encrypt("sandbox-" + folder.name)
            let sql = """
                CREATE TABLE meta (key TEXT PRIMARY KEY, value INTEGER);
                INSERT INTO meta VALUES ('version', 24);
                CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, last_access_utc INTEGER);
                """
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw SandboxGenerationError.cookieDatabase }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT INTO cookies VALUES ('.claude.ai','sessionKey','',?,1)", -1,
                                    &statement, nil) == SQLITE_OK, let statement else {
                throw SandboxGenerationError.cookieDatabase
            }
            defer { sqlite3_finalize(statement) }
            let status = blob.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard status == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw SandboxGenerationError.cookieDatabase }
        } catch { sqlite3_close(database); throw error }
        guard sqlite3_close(database) == SQLITE_OK else { throw SandboxGenerationError.cookieDatabase }
        try AtomicFile.write(Data(contentsOf: stage), to: url)
    }

    private static func writeJSON(_ object: Any, to url: URL) throws {
        try AtomicFile.write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: url)
    }

    private static func writePlist(_ object: [String: String], to url: URL) throws {
        try AtomicFile.write(PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0), to: url)
    }
}
