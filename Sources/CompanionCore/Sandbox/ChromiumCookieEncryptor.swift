import CommonCrypto
import Foundation

/// Fixture-only encryption for sandbox cookies. Never use this fixed password for credentials.
public enum ChromiumCookieEncryptor {
    public static let fixturePassword = Data("sandbox-safe-storage".utf8)

    /// The exact inverse of `ChromiumCookieDecryptor`, built from the same primitives.
    public static func encrypt(_ value: String, host: String = ".claude.ai", version: Int = 24) throws -> Data {
        try CookiePlaintext.validate(value)
        var plain = version >= 24 ? ChromiumCookieDecryptor.digest(of: host.utf8) : []
        plain += Array(value.utf8)
        // PKCS#7 always adds between 1 and a whole block of bytes, each holding the pad length.
        let blockSize = ChromiumCookieDecryptor.blockSize
        let padLength = blockSize - plain.count % blockSize
        plain += [UInt8](repeating: UInt8(padLength), count: padLength)
        var password = [UInt8](fixturePassword)
        let key = try ChromiumCookieDecryptor.deriveKey(from: &password)
        let sealed = try ChromiumCookieDecryptor.transform(plain, key: [UInt8](key), operation: CCOperation(kCCEncrypt))
        return Data("v10".utf8) + sealed
    }
}
