import Foundation

public struct EncryptedCookie: Equatable, Sendable, Hashable {
    public var hostKey: String
    /// Chromium `encrypted_value`. Empty when the value was stored in the plaintext column.
    public var encryptedValue: Data
    /// Chromium `value` column when it held the cookie. Never log this.
    public var plaintextValue: String?
    /// `meta.version`, or 0 when that row is missing.
    public var databaseVersion: Int

    public init(
        hostKey: String,
        encryptedValue: Data,
        plaintextValue: String? = nil,
        databaseVersion: Int
    ) {
        self.hostKey = hostKey
        self.encryptedValue = encryptedValue
        self.plaintextValue = plaintextValue
        self.databaseVersion = databaseVersion
    }
}

public enum CookieReadError: Error, Equatable, Sendable {
    case databaseUnreadable
    case invalidDatabase
}

/// Reads the Claude session cookie. Read-only: it must not write the database,
/// and it must not log cookie bytes.
///
/// Success is the newest `sessionKey` row for `claude.ai` or `.claude.ai`.
/// Nil means no such row, including when the database file is absent.
/// Throws `CookieReadError` when a database is present but cannot be read.
public protocol SessionCookieReading: Sendable {
    func sessionCookie(profile: URL) throws -> EncryptedCookie?
}

public enum SafeStorageError: Error, Equatable, Sendable {
    case notFound
    case userDenied
    case commandFailed(exitCode: Int32)
}

/// The "Claude Safe Storage" password, held in memory only.
///
/// Success is the password bytes with trailing CR/LF removed. Must not write
/// them to disk, logs, or the process arguments. Throws `notFound` when the
/// item is absent and `userDenied` when the user refuses access.
public protocol SafeStorageKeyProviding: Sendable {
    func password() async throws -> Data
}

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: Duration
    public var allowsRedirects: Bool
    public var maximumBodyBytes: Int

    public init(
        method: String,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: Duration = .seconds(20),
        allowsRedirects: Bool = false,
        maximumBodyBytes: Int = 2 * 1024 * 1024
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.allowsRedirects = allowsRedirects
        self.maximumBodyBytes = maximumBodyBytes
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
    public var finalURL: URL

    public init(statusCode: Int, headers: [String: String] = [:], body: Data, finalURL: URL) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }
}

public enum HTTPTransportError: Error, Equatable, Sendable {
    case transportFailed
    case timedOut
    case redirected
    case bodyTooLarge
}

/// Sends one HTTP request.
///
/// Success is a response whose body is at most `maximumBodyBytes`. When
/// `allowsRedirects` is false, a redirect throws `HTTPTransportError.redirected`
/// and is neither followed nor returned. The request must not be sent to a host
/// other than `url`'s host. Also throws `timedOut` and `transportFailed`.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public enum LoginItemError: Error, Equatable, Sendable {
    case writeFailed
    case notRemoved
}

/// Our login item, which is only the LaunchAgent plist.
///
/// `isEnabled` is true when that plist exists. It does not ask launchd.
/// `enable` writes the plist that will launch `executable` at the next login.
/// `disable` removes it. Neither method may load or unload the job: unloading
/// can kill the running app.
public protocol LoginItemManaging: Sendable {
    var isEnabled: Bool { get async throws }
    func enable(executable: URL) async throws
    func disable() async throws
}

public enum FileRevealError: Error, Equatable, Sendable {
    case revealFailed
}

/// Reveals a file in Finder. Success means Finder accepted the request.
/// Must not open or execute the item.
public protocol FileRevealing: Sendable {
    func reveal(_ url: URL) async throws
}
