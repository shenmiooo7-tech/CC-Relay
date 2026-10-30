import Foundation

public struct QuotaProfile: Equatable, Sendable {
    public var folder: ProfileFolder
    public var directory: URL
    public var accountUUID: String
    public var organizationUUID: String?

    public init(
        folder: ProfileFolder,
        directory: URL,
        accountUUID: String,
        organizationUUID: String?
    ) {
        self.folder = folder
        self.directory = directory
        self.accountUUID = accountUUID
        self.organizationUUID = organizationUUID
    }
}

public struct QuotaReading: Equatable, Sendable {
    public var snapshot: QuotaSnapshot?
    public var freshness: QuotaFreshness
    public var lastError: QuotaFailure?

    public init(
        snapshot: QuotaSnapshot? = nil,
        freshness: QuotaFreshness,
        lastError: QuotaFailure? = nil
    ) {
        self.snapshot = snapshot
        self.freshness = freshness
        self.lastError = lastError
    }
}

/// Why the last refresh did not produce a new network reading.
///
/// Cases carry no cookie, key, or response body.
public enum QuotaFailure: Error, Equatable, Sendable, Codable {
    case signedOut
    /// The read was turned away while the sign-in still stands.
    case refused
    /// claude.ai asked for fewer requests; this account is not read again before `until`.
    case rateLimited(until: Date)
    case cookieMissing
    case cookieUnreadable
    case decryptFailed
    case keyUnavailable
    case accountMismatch
    case organizationUnavailable
    case invalidResponse
    case httpFailure(Int)
    case redirected
    case timedOut
    case transportFailed
    case bodyTooLarge

    /// The profile has no usable sign-in: the server refused its cookie, or the cookie is gone.
    /// Either way the card asks to sign in again and no longer shows the old figures.
    public var needsSignIn: Bool { self == .signedOut || self == .cookieMissing }
}

/// Whole-second offset added to the 10-minute quota cadence.
public protocol RefreshJitter: Sendable {
    func secondsOffset() -> Int
}

public struct UniformRefreshJitter: RefreshJitter {
    public init() {}

    public func secondsOffset() -> Int {
        Int.random(in: -90...90)
    }
}
