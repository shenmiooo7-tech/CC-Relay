import CommonCrypto
import Foundation
import XCTest

enum CookieFixtureError: Error {
    case crypto
}

/// Encrypts cookie plaintexts the way the decryptor expects to read them.
enum CookieFixture {
    static func blob(version: Int, cookie: String, host: String, password: Data) throws -> Data {
        var body = Data(cookie.utf8)
        if version >= 24 {
            body = Data(sha256(Data(host.utf8))) + body
        }
        return try blob(plaintext: body, password: password)
    }

    static func blob(plaintext: Data, password: Data) throws -> Data {
        let padded = pkcs7(plaintext)
        return try ciphertext(block: padded, password: password)
    }

    static func ciphertext(block: Data, password: Data) throws -> Data {
        let key = try derive(password)
        let encrypted = try crypt(block, key: key, operation: CCOperation(kCCEncrypt))
        return Data([UInt8(ascii: "v"), UInt8(ascii: "1"), UInt8(ascii: "0")]) + encrypted
    }

    static func sha256(_ data: Data) -> [UInt8] {
        let count = CC_LONG(data.count)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = digest.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                CC_SHA256(input.baseAddress, count, output.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return digest
    }

    private static func pkcs7(_ data: Data) -> Data {
        let extra = 16 - (data.count % 16)
        var padded = data
        padded.append(contentsOf: repeatElement(UInt8(extra), count: extra))
        return padded
    }

    private static func derive(_ password: Data) throws -> Data {
        let salt = Array("saltysalt".utf8)
        let saltCount = salt.count
        let passwordCount = password.count
        var key = Data(count: 16)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordCount,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        saltCount,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1_003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        16
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CookieFixtureError.crypto }
        return key
    }

    private static func crypt(_ input: Data, key: Data, operation: CCOperation) throws -> Data {
        let inputCount = input.count
        let keyCount = key.count
        var output = Data(count: inputCount)
        let outputCount = output.count
        var moved = 0
        let iv = Data(repeating: 0x20, count: 16)
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
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
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, moved == inputCount else { throw CookieFixtureError.crypto }
        return output
    }
}
