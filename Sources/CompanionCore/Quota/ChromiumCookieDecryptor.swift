import CommonCrypto
import Darwin
import Foundation

public enum CookieDecryptError: Error, Equatable, Sendable {
    case badPrefix
    case badLength
    case badPadding
    case wrongHostHash
    case shortHostPrefix
    case empty
    case forbiddenCharacter
    case invalidText
    case keyUnavailable
    case undecryptable
}

/// Decrypts a Chromium `v10` cookie blob.
///
/// The derived AES key is kept in memory and reused for the same password.
/// The temporary password copy is wiped after derivation.
public actor ChromiumCookieDecryptor {
    private var keysByStamp: [Data: Data] = [:]
    private var rememberedKey: Data?

    public init() {}

    public var hasRememberedKey: Bool {
        rememberedKey != nil
    }

    /// `password` nil reuses the last derived key.
    public func open(_ cookie: EncryptedCookie, password: Data?) throws -> String {
        let key = try resolveKey(password)
        return try Self.reveal(
            cookie.encryptedValue,
            host: cookie.hostKey,
            version: cookie.databaseVersion,
            key: key
        )
    }

    private func resolveKey(_ password: Data?) throws -> Data {
        if let password {
            let stamp = Data(Self.digest(of: password))
            if let cached = keysByStamp[stamp] {
                rememberedKey = cached
                return cached
            }
            var secret = [UInt8](password)
            defer { Self.wipe(&secret) }
            let derived = try Self.deriveKey(from: &secret)
            keysByStamp[stamp] = derived
            rememberedKey = derived
            return derived
        }
        guard let rememberedKey else {
            throw CookieDecryptError.keyUnavailable
        }
        return rememberedKey
    }

    private static func reveal(_ blob: Data, host: String, version: Int, key: Data) throws -> String {
        let prefix = [UInt8(ascii: "v"), UInt8(ascii: "1"), UInt8(ascii: "0")]
        let bytes = [UInt8](blob)
        guard bytes.count >= prefix.count, Array(bytes.prefix(prefix.count)) == prefix else {
            throw CookieDecryptError.badPrefix
        }
        let ciphertext = Array(bytes.dropFirst(prefix.count))
        guard ciphertext.count >= blockSize, ciphertext.count.isMultiple(of: blockSize) else {
            throw CookieDecryptError.badLength
        }
        let padded = try decrypt(ciphertext, key: [UInt8](key))
        let plain = try removePadding(padded)
        let body = try stripHostDigest(plain, host: host, version: version)
        return try CookiePlaintext.decode(body)
    }

    /// Version 24 prefixes the value with SHA-256(host). That digest is binary.
    private static func stripHostDigest(_ plain: [UInt8], host: String, version: Int) throws -> [UInt8] {
        guard version >= 24 else { return plain }
        guard plain.count > digestSize else {
            throw CookieDecryptError.shortHostPrefix
        }
        let expected = digest(of: Array(host.utf8))
        guard sameDigest(plain.prefix(digestSize), expected) else {
            throw CookieDecryptError.wrongHostHash
        }
        return Array(plain.dropFirst(digestSize))
    }

    private static func removePadding(_ bytes: [UInt8]) throws -> [UInt8] {
        guard let marker = bytes.last else {
            throw CookieDecryptError.badPadding
        }
        let length = Int(marker)
        guard (1...blockSize).contains(length), length <= bytes.count else {
            throw CookieDecryptError.badPadding
        }
        var difference: UInt8 = 0
        for byte in bytes.suffix(length) {
            difference |= byte ^ marker
        }
        guard difference == 0 else {
            throw CookieDecryptError.badPadding
        }
        return Array(bytes.dropLast(length))
    }

    private static func decrypt(_ ciphertext: [UInt8], key: [UInt8]) throws -> [UInt8] {
        try transform(ciphertext, key: key, operation: CCOperation(kCCDecrypt))
    }

    /// AES-128-CBC without padding; also used by the sandbox fixture encryptor.
    static func transform(_ input: [UInt8], key: [UInt8], operation: CCOperation) throws -> [UInt8] {
        guard key.count == blockSize, !input.isEmpty else {
            throw CookieDecryptError.undecryptable
        }
        let inputCount = input.count
        let keyCount = key.count
        var output = [UInt8](repeating: 0, count: inputCount)
        let outputCount = output.count
        var produced = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    initializationVector.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBytes.baseAddress,
                            keyCount,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            inputCount,
                            outputBytes.baseAddress,
                            outputCount,
                            &produced
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, produced == input.count else {
            throw CookieDecryptError.undecryptable
        }
        return output
    }

    static func deriveKey(from password: inout [UInt8]) throws -> Data {
        let salt = Array("saltysalt".utf8)
        var derived = [UInt8](repeating: 0, count: blockSize)
        defer { wipe(&derived) }
        let saltCount = salt.count
        let passwordCount = password.count
        let status: CCCryptorStatus = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                let saltPointer = saltBytes.bindMemory(to: UInt8.self).baseAddress
                let derivedPointer = derivedBytes.bindMemory(to: UInt8.self).baseAddress
                if passwordCount == 0 {
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        nil,
                        0,
                        saltPointer,
                        saltCount,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        UInt32(derivationRounds),
                        derivedPointer,
                        blockSize
                    )
                }
                return password.withUnsafeMutableBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordCount,
                        saltPointer,
                        saltCount,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        UInt32(derivationRounds),
                        derivedPointer,
                        blockSize
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw CookieDecryptError.undecryptable
        }
        return Data(derived)
    }

    static func digest(of bytes: some Sequence<UInt8>) -> [UInt8] {
        let input = Array(bytes)
        let inputCount = CC_LONG(input.count)
        var output = [UInt8](repeating: 0, count: digestSize)
        output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                _ = CC_SHA256(
                    inputBytes.baseAddress,
                    inputCount,
                    outputBytes.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }
        return output
    }

    /// Compares every digest byte. A mismatch does not return early.
    private static func sameDigest(_ candidate: ArraySlice<UInt8>, _ expected: [UInt8]) -> Bool {
        guard candidate.count == expected.count else { return false }
        var difference: UInt8 = 0
        for (offset, expectedByte) in expected.enumerated() {
            let index = candidate.index(candidate.startIndex, offsetBy: offset)
            difference |= candidate[index] ^ expectedByte
        }
        return difference == 0
    }

    private static func wipe(_ bytes: inout [UInt8]) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = memset_s(base, raw.count, 0, raw.count)
        }
    }

    static let blockSize = 16
    private static let digestSize = 32
    private static let derivationRounds = 1_003
    private static let initializationVector = Data(repeating: 0x20, count: blockSize)
}

enum CookiePlaintext {
    static func validate(_ text: String) throws {
        _ = try decode(Data(text.utf8))
    }

    static func decode(_ bytes: [UInt8]) throws -> String {
        try decode(Data(bytes))
    }

    static func decode(_ bytes: Data) throws -> String {
        if bytes.isEmpty {
            throw CookieDecryptError.empty
        }
        if bytes.contains(0x0D) || bytes.contains(0x0A) || bytes.contains(0x3B) || bytes.contains(0x00) {
            throw CookieDecryptError.forbiddenCharacter
        }
        guard let text = String(bytes: bytes, encoding: .utf8), !text.isEmpty else {
            throw bytes.isEmpty ? CookieDecryptError.empty : CookieDecryptError.invalidText
        }
        return text
    }
}
