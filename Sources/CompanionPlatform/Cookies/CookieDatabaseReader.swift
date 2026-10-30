import Foundation
import SQLite3

public struct CookieDatabaseRecord: Equatable, Sendable {
    public let encryptedValue: Data
    public let value: String
    public let hostKey: String
    public let databaseVersion: Int
}

public enum CookieDatabaseError: Error, Equatable, Sendable {
    case openFailed(Int32)
    case queryFailed(Int32)
    case invalidText

    fileprivate var isLocked: Bool {
        switch self {
        case .openFailed(let code), .queryFailed(let code):
            return code & 0xff == SQLITE_BUSY || code & 0xff == SQLITE_LOCKED
        case .invalidText:
            return false
        }
    }
}

public struct CookieDatabaseReader: Sendable {
    private let temporaryDirectory: URL

    public init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.temporaryDirectory = temporaryDirectory
    }

    public func sessionCookie(profile: URL) throws -> CookieDatabaseRecord? {
        guard let database = try databaseURL(profile: profile) else { return nil }
        do {
            return try read(database)
        } catch let error as CookieDatabaseError where error.isLocked {
            return try readPrivateCopy(database)
        }
    }

    private func databaseURL(profile: URL) throws -> URL? {
        for relativePath in ["Cookies", "Network/Cookies"] {
            let candidate = profile.appendingPathComponent(relativePath)
            do {
                _ = try FileManager.default.attributesOfItem(atPath: candidate.path)
                return candidate
            } catch CocoaError.fileReadNoSuchFile {
                continue
            }
        }
        return nil
    }

    private func readPrivateCopy(_ database: URL) throws -> CookieDatabaseRecord? {
        let files = FileManager.default
        let root = temporaryDirectory.appendingPathComponent("cc-relay-cookies-\(UUID().uuidString)")
        try files.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? files.removeItem(at: root) }
        let copy = root.appendingPathComponent("Cookies")
        try files.copyItem(at: database, to: copy)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        for suffix in ["-journal", "-wal"] {
            let source = URL(fileURLWithPath: database.path + suffix)
            let destination = URL(fileURLWithPath: copy.path + suffix)
            do {
                try files.copyItem(at: source, to: destination)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            } catch CocoaError.fileReadNoSuchFile {
                // A journal can disappear between the lock failure and the copy.
                continue
            }
        }
        // SQLite must be able to roll back a hot journal captured during a commit.
        return try read(copy, readOnly: false)
    }

    private func read(_ database: URL, readOnly: Bool = true) throws -> CookieDatabaseRecord? {
        var components = URLComponents(url: database.standardizedFileURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "mode", value: readOnly ? "ro" : "rw")]
        guard let uri = components?.url?.absoluteString else {
            throw CookieDatabaseError.openFailed(SQLITE_CANTOPEN)
        }
        var handle: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_URI
        let status = sqlite3_open_v2(uri, &handle, flags, nil)
        defer { if let handle { sqlite3_close(handle) } }
        guard status == SQLITE_OK, let handle else { throw CookieDatabaseError.openFailed(status) }
        sqlite3_busy_timeout(handle, 3_000)

        let query = """
            SELECT encrypted_value, value, host_key FROM cookies
            WHERE name = 'sessionKey' AND host_key IN ('claude.ai', '.claude.ai')
            ORDER BY last_access_utc DESC LIMIT 1
            """
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, query, -1, &statement, nil)
        defer { if let statement { sqlite3_finalize(statement) } }
        guard prepared == SQLITE_OK, let statement else {
            throw CookieDatabaseError.queryFailed(prepared)
        }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw CookieDatabaseError.queryFailed(step) }
        let length = Int(sqlite3_column_bytes(statement, 0))
        let encrypted = sqlite3_column_blob(statement, 0).map { Data(bytes: $0, count: length) } ?? Data()
        return try CookieDatabaseRecord(
            encryptedValue: encrypted, value: text(statement, column: 1), hostKey: text(statement, column: 2),
            databaseVersion: databaseVersion(handle)
        )
    }

    private func databaseVersion(_ database: OpaquePointer) -> Int {
        var statement: OpaquePointer?
        defer { if let statement { sqlite3_finalize(statement) } }
        guard sqlite3_prepare_v2(database, "SELECT value FROM meta WHERE key = 'version'", -1, &statement, nil) == SQLITE_OK,
              let statement, sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func text(_ statement: OpaquePointer, column: Int32) throws -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        let length = Int(sqlite3_column_bytes(statement, column))
        guard let value = String(data: Data(bytes: bytes, count: length), encoding: .utf8) else {
            throw CookieDatabaseError.invalidText
        }
        return value
    }
}
