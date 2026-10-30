import CompanionCore
import Foundation

public struct LiveSafeStorageKeyProvider: SafeStorageKeyProviding {
    private let keychain: SafeStorageKeychain

    public init(keychain: SafeStorageKeychain = SafeStorageKeychain()) { self.keychain = keychain }

    public func password() async throws -> Data {
        try SafetyTripwire.assertLiveActionsAllowed()
        do { return try await keychain.password() }
        catch SafeStorageKeychainError.notFound { throw SafeStorageError.notFound }
        catch SafeStorageKeychainError.userDenied { throw SafeStorageError.userDenied }
        catch SafeStorageKeychainError.commandFailed(let status) { throw SafeStorageError.commandFailed(exitCode: status) }
    }
}

public struct FixedSafeStorageKeyProvider: SafeStorageKeyProviding {
    private let value: Data
    public init(password: Data = Data("sandbox-safe-storage".utf8)) { value = password }
    public func password() async throws -> Data { value }
}

public struct LiveSessionCookieReader: SessionCookieReading {
    private let reader: CookieDatabaseReader
    public init(reader: CookieDatabaseReader = CookieDatabaseReader()) { self.reader = reader }

    public func sessionCookie(profile: URL) throws -> EncryptedCookie? {
        try SafetyTripwire.assertLiveActionsAllowed()
        return try readCookie(reader, profile: profile)
    }
}

public struct SandboxSessionCookieReader: SessionCookieReading {
    private let boundary: SandboxBoundary
    private let reader: CookieDatabaseReader

    public init(root: URL) {
        boundary = SandboxBoundary(root: root)
        reader = CookieDatabaseReader(temporaryDirectory: root)
    }

    public func sessionCookie(profile: URL) throws -> EncryptedCookie? {
        try boundary.check(profile)
        for suffix in ["Cookies", "Cookies-wal", "Cookies-shm", "Cookies-journal", "Network", "Network/Cookies",
                       "Network/Cookies-wal", "Network/Cookies-shm", "Network/Cookies-journal"] {
            try boundary.check(profile.appendingPathComponent(suffix))
        }
        return try readCookie(reader, profile: profile)
    }
}

private func readCookie(_ reader: CookieDatabaseReader, profile: URL) throws -> EncryptedCookie? {
    do {
        guard let record = try reader.sessionCookie(profile: profile) else { return nil }
        guard record.encryptedValue.count <= 65_536,
              !record.encryptedValue.isEmpty || !record.value.isEmpty else { throw CookieReadError.invalidDatabase }
        return EncryptedCookie(hostKey: record.hostKey, encryptedValue: record.encryptedValue,
                               plaintextValue: record.value.isEmpty ? nil : record.value,
                               databaseVersion: record.databaseVersion)
    } catch let error as CookieReadError { throw error }
    catch { throw CookieReadError.databaseUnreadable }
}
