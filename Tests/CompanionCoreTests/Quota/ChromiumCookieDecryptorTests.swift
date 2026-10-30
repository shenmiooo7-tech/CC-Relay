import XCTest
@testable import CompanionCore

final class QuotaDecryptorTests: XCTestCase {
    private let password = Data("test-password".utf8)
    private let otherPassword = Data("other-password".utf8)

    func testVersion23And24RoundTrip() async throws {
        let decryptor = ChromiumCookieDecryptor()
        let older = try await open(
            decryptor,
            version: 23,
            cookie: "session-alpha",
            host: "claude.ai",
            password: password
        )
        XCTAssertEqual(older, "session-alpha")

        let longer = String(repeating: "a", count: 40)
        let kept = try await open(
            decryptor,
            version: 23,
            cookie: longer,
            host: "claude.ai",
            password: password
        )
        XCTAssertEqual(kept, longer)

        let current = try await open(
            decryptor,
            version: 24,
            cookie: "session-beta",
            host: ".claude.ai",
            password: password
        )
        XCTAssertEqual(current, "session-beta")

        let later = try await open(
            decryptor,
            version: 30,
            cookie: "session-gamma",
            host: "claude.ai",
            password: password
        )
        XCTAssertEqual(later, "session-gamma")
    }

    func testVersion24AcceptsADigestThatContainsForbiddenBytes() async throws {
        let host = try XCTUnwrap(hostWhoseDigestContainsTextBytes())
        let decryptor = ChromiumCookieDecryptor()
        let value = try await open(
            decryptor,
            version: 24,
            cookie: "session-after-digest",
            host: host,
            password: password
        )
        XCTAssertEqual(value, "session-after-digest")
    }

    func testSeparatePasswordsStayDistinctAndTheLastKeyIsRemembered() async throws {
        let decryptor = ChromiumCookieDecryptor()
        let alpha = try sealed(version: 23, cookie: "alpha-cookie", host: "claude.ai", password: password)
        let beta = try sealed(version: 23, cookie: "beta-cookie", host: "claude.ai", password: otherPassword)

        let first = try await decryptor.open(alpha, password: password)
        let second = try await decryptor.open(beta, password: otherPassword)
        let rememberedBeta = try await decryptor.open(beta, password: nil)
        let again = try await decryptor.open(alpha, password: password)
        let rememberedAlpha = try await decryptor.open(alpha, password: nil)

        XCTAssertEqual(first, "alpha-cookie")
        XCTAssertEqual(second, "beta-cookie")
        XCTAssertEqual(rememberedBeta, "beta-cookie")
        XCTAssertEqual(again, "alpha-cookie")
        XCTAssertEqual(rememberedAlpha, "alpha-cookie")
        let remembered = await decryptor.hasRememberedKey
        XCTAssertTrue(remembered)
    }

    func testWrongPasswordDoesNotReturnTheCookie() async throws {
        let decryptor = ChromiumCookieDecryptor()
        let sealedCookie = try sealed(version: 23, cookie: "expected-cookie", host: "claude.ai", password: password)
        do {
            _ = try await decryptor.open(sealedCookie, password: otherPassword)
            XCTFail("wrong password returned a cookie")
        } catch is CookieDecryptError {
        }
    }

    func testRejectsBadPrefixBadLengthAndBadPadding() async throws {
        let decryptor = ChromiumCookieDecryptor()
        try await expect(.badPrefix, blob: Data("v11".utf8) + Data(count: 16), decryptor: decryptor)
        try await expect(.badPrefix, blob: Data("v1".utf8), decryptor: decryptor)
        try await expect(.badLength, blob: Data("v10".utf8), decryptor: decryptor)
        try await expect(.badLength, blob: Data("v10".utf8) + Data(count: 15), decryptor: decryptor)

        var block = Data(count: 16)
        block[12] = 1
        block[13] = 2
        block[14] = 3
        block[15] = 4
        let padded = try CookieFixture.ciphertext(block: block, password: password)
        try await expect(.badPadding, blob: padded, decryptor: decryptor)
    }

    func testRejectsWrongHostHashShortPrefixAndEmptyValue() async throws {
        let decryptor = ChromiumCookieDecryptor()
        let wrongHost = try sealed(version: 24, cookie: "session-beta", host: "claude.ai", password: password)
        let mismatched = EncryptedCookie(
            hostKey: ".claude.ai",
            encryptedValue: wrongHost.encryptedValue,
            databaseVersion: 24
        )
        try await expect(.wrongHostHash, cookie: mismatched, decryptor: decryptor)

        let short = try CookieFixture.blob(plaintext: Data(repeating: 0x41, count: 32), password: password)
        try await expect(
            .shortHostPrefix,
            cookie: EncryptedCookie(hostKey: "claude.ai", encryptedValue: short, databaseVersion: 24),
            decryptor: decryptor
        )

        let empty = try CookieFixture.blob(plaintext: Data(), password: password)
        try await expect(
            .empty,
            cookie: EncryptedCookie(hostKey: "claude.ai", encryptedValue: empty, databaseVersion: 23),
            decryptor: decryptor
        )
    }

    func testRejectsForbiddenCharactersAndInvalidText() async throws {
        let decryptor = ChromiumCookieDecryptor()
        for character in ["\r", "\n", ";", "\u{0}"] {
            let blob = try CookieFixture.blob(plaintext: Data("ab\(character)c".utf8), password: password)
            try await expect(
                .forbiddenCharacter,
                cookie: EncryptedCookie(hostKey: "claude.ai", encryptedValue: blob, databaseVersion: 23),
                decryptor: decryptor
            )
        }
        let invalid = try CookieFixture.blob(plaintext: Data([0xFF]), password: password)
        try await expect(
            .invalidText,
            cookie: EncryptedCookie(hostKey: "claude.ai", encryptedValue: invalid, databaseVersion: 23),
            decryptor: decryptor
        )
    }

    private func open(
        _ decryptor: ChromiumCookieDecryptor,
        version: Int,
        cookie: String,
        host: String,
        password: Data
    ) async throws -> String {
        try await decryptor.open(
            sealed(version: version, cookie: cookie, host: host, password: password),
            password: password
        )
    }

    private func sealed(version: Int, cookie: String, host: String, password: Data) throws -> EncryptedCookie {
        let blob = try CookieFixture.blob(version: version, cookie: cookie, host: host, password: password)
        return EncryptedCookie(hostKey: host, encryptedValue: blob, databaseVersion: version)
    }

    private func expect(
        _ expected: CookieDecryptError,
        blob: Data,
        decryptor: ChromiumCookieDecryptor
    ) async throws {
        try await expect(
            expected,
            cookie: EncryptedCookie(hostKey: "claude.ai", encryptedValue: blob, databaseVersion: 23),
            decryptor: decryptor
        )
    }

    private func expect(
        _ expected: CookieDecryptError,
        cookie: EncryptedCookie,
        decryptor: ChromiumCookieDecryptor
    ) async throws {
        do {
            _ = try await decryptor.open(cookie, password: password)
            XCTFail("expected \(expected)")
        } catch let error as CookieDecryptError {
            XCTAssertEqual(error, expected)
        }
    }

    private func hostWhoseDigestContainsTextBytes() -> String? {
        for index in 0..<300 {
            let host = "h\(index).claude.ai"
            let digest = CookieFixture.sha256(Data(host.utf8))
            if digest.contains(where: { $0 == 0 || $0 == 0x0A || $0 == 0x0D || $0 == 0x3B }) {
                return host
            }
        }
        return nil
    }
}
