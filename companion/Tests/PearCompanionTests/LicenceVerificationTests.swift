import CryptoKit
import XCTest

@testable import PearCompanion

/// Licence and revocation fixtures, signed with an **ephemeral** keypair
/// generated inside the test process. No private key exists anywhere in this
/// repo — not even a throwaway one — which is the point: the owner's signing key
/// lives outside the worktree and nothing here can stand in for it.
enum LicenceFixture {
    static func keyPair() -> (private: Curve25519.Signing.PrivateKey, public: Curve25519.Signing.PublicKey) {
        let key = Curve25519.Signing.PrivateKey()
        return (key, key.publicKey)
    }

    static func sample(
        email: String = "buyer@example.com",
        orderID: String = "ord_9f2c17",
        maxMajor: Int = 3
    ) -> Licence {
        Licence(
            email: email,
            orderID: orderID,
            issuedAt: Date(timeIntervalSince1970: 1_785_000_000),
            maxMajor: maxMajor
        )
    }

    /// A licence string exactly as `issue-license.sh` produces it:
    /// base64(signature ‖ payload JSON).
    static func licenceString(
        _ licence: Licence,
        signedBy key: Curve25519.Signing.PrivateKey,
        domain: SigningDomain = .licence
    ) throws -> String {
        try blob(payload: encoder.encode(licence), signedBy: key, domain: domain)
    }

    static func blob(
        payload: Data,
        signedBy key: Curve25519.Signing.PrivateKey,
        domain: SigningDomain = .licence
    ) throws -> String {
        let signature = try key.signature(for: domain.message(payload))
        return (signature + payload).base64EncodedString()
    }

    /// A `revoked.json` byte-for-byte compatible with what `revoke.sh` writes.
    static func revocationJSON(
        serial: Int,
        issued: String = "2026-08-01T00:00:00Z",
        revoked: [String],
        signedBy key: Curve25519.Signing.PrivateKey,
        domain: SigningDomain = .revocation
    ) throws -> Data {
        let body = RevocationList.canonicalBody(serial: serial, issued: issued, revoked: revoked)
        let signature = try key.signature(for: domain.message(body))
        return json(
            serial: serial,
            issued: issued,
            revoked: revoked,
            signature: signature.base64EncodedString()
        )
    }

    static func json(serial: Int, issued: String, revoked: [String], signature: String) -> Data {
        let hashes = revoked.map { "\"\($0)\"" }.joined(separator: ",")
        let text = """
            {"serial":\(serial),"issued":"\(issued)","revoked":[\(hashes)],"signature":"\(signature)"}
            """
        return Data(text.utf8)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

final class LicenceVerificationTests: XCTestCase {
    // MARK: - The happy path

    func testValidLicenceVerifiesAndCarriesItsFields() throws {
        let keys = LicenceFixture.keyPair()
        let licence = LicenceFixture.sample()
        let text = try LicenceFixture.licenceString(licence, signedBy: keys.private)

        let verifier = LicenceVerifier(publicKey: keys.public, appMajor: 3)
        XCTAssertEqual(verifier.check(text), .valid(licence))
    }

    func testOrderHashIsLowercaseSHA256OfTheOrderID() {
        let licence = LicenceFixture.sample(orderID: "ord_123")
        let expected = SHA256.hash(data: Data("ord_123".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(licence.orderHash, expected)
        XCTAssertEqual(licence.orderHash.count, 64)
        XCTAssertEqual(licence.orderHash, licence.orderHash.lowercased())
    }

    // MARK: - Bad signature

    func testSignatureFromAnotherKeyIsRejected() throws {
        let owner = LicenceFixture.keyPair()
        let forger = LicenceFixture.keyPair()
        let text = try LicenceFixture.licenceString(LicenceFixture.sample(), signedBy: forger.private)

        let verifier = LicenceVerifier(publicKey: owner.public, appMajor: 3)
        XCTAssertEqual(verifier.check(text), .badSignature)
    }

    func testEditedPayloadIsRejected() throws {
        let keys = LicenceFixture.keyPair()
        let text = try LicenceFixture.licenceString(
            LicenceFixture.sample(email: "buyer@example.com"),
            signedBy: keys.private
        )
        var blob = try XCTUnwrap(Data(base64Encoded: text))
        // Rewrite one byte of the payload (past the 64-byte signature).
        blob[70] = blob[70] ^ 0x01

        let verifier = LicenceVerifier(publicKey: keys.public, appMajor: 3)
        XCTAssertEqual(verifier.check(blob.base64EncodedString()), .badSignature)
    }

    func testEditedSignatureIsRejected() throws {
        let keys = LicenceFixture.keyPair()
        let text = try LicenceFixture.licenceString(LicenceFixture.sample(), signedBy: keys.private)
        var blob = try XCTUnwrap(Data(base64Encoded: text))
        blob[0] = blob[0] ^ 0x01

        let verifier = LicenceVerifier(publicKey: keys.public, appMajor: 3)
        XCTAssertEqual(verifier.check(blob.base64EncodedString()), .badSignature)
    }

    /// Domain separation, licence side: the same key signing the same bytes under
    /// the revocation label produces something a licence check refuses.
    func testLicenceSignedUnderTheRevocationDomainIsRejected() throws {
        let keys = LicenceFixture.keyPair()
        let text = try LicenceFixture.licenceString(
            LicenceFixture.sample(),
            signedBy: keys.private,
            domain: .revocation
        )

        let verifier = LicenceVerifier(publicKey: keys.public, appMajor: 3)
        XCTAssertEqual(verifier.check(text), .badSignature)
    }

    func testDomainLabelsAreTheDocumentedStringsAndDiffer() {
        XCTAssertEqual(SigningDomain.licence.rawValue, "pear-licence-v1")
        XCTAssertEqual(SigningDomain.revocation.rawValue, "pear-revocation-v1")

        let body = Data("serial=1".utf8)
        XCTAssertNotEqual(SigningDomain.licence.message(body), SigningDomain.revocation.message(body))
        XCTAssertEqual(
            SigningDomain.revocation.message(body),
            Data("pear-revocation-v1\nserial=1".utf8)
        )
    }

    // MARK: - Malformed

    func testEmptyAndGarbageInputAreMalformed() {
        let keys = LicenceFixture.keyPair()
        let verifier = LicenceVerifier(publicKey: keys.public, appMajor: 3)

        XCTAssertEqual(verifier.check(""), .malformed)
        XCTAssertEqual(verifier.check("    \n\t  "), .malformed)
        XCTAssertEqual(verifier.check("not a licence at all!!"), .malformed)
    }

    func testBlobShorterThanASignatureIsMalformed() {
        let keys = LicenceFixture.keyPair()
        let verifier = LicenceVerifier(publicKey: keys.public, appMajor: 3)

        // 64 bytes: a signature and nothing to sign.
        XCTAssertEqual(verifier.check(Data(repeating: 0, count: 64).base64EncodedString()), .malformed)
        XCTAssertEqual(verifier.check(Data(repeating: 0, count: 12).base64EncodedString()), .malformed)
    }

    func testAuthenticPayloadThatIsNotAPayloadIsMalformed() throws {
        let keys = LicenceFixture.keyPair()
        let text = try LicenceFixture.blob(payload: Data("hello, not json".utf8), signedBy: keys.private)

        let verifier = LicenceVerifier(publicKey: keys.public, appMajor: 3)
        XCTAssertEqual(verifier.check(text), .malformed)
    }

    func testAuthenticPayloadWithEmptyIdentityIsMalformed() throws {
        let keys = LicenceFixture.keyPair()
        let verifier = LicenceVerifier(publicKey: keys.public, appMajor: 3)

        let noEmail = try LicenceFixture.licenceString(
            LicenceFixture.sample(email: ""),
            signedBy: keys.private
        )
        XCTAssertEqual(verifier.check(noEmail), .malformed)

        let noOrder = try LicenceFixture.licenceString(
            LicenceFixture.sample(orderID: ""),
            signedBy: keys.private
        )
        XCTAssertEqual(verifier.check(noOrder), .malformed)
    }

    // MARK: - Major version

    func testLicenceForAnOlderMajorNeedsAnUpgrade() throws {
        let keys = LicenceFixture.keyPair()
        let text = try LicenceFixture.licenceString(
            LicenceFixture.sample(maxMajor: 3),
            signedBy: keys.private
        )

        let verifier = LicenceVerifier(publicKey: keys.public, appMajor: 4)
        XCTAssertEqual(verifier.check(text), .majorUnsupported(maxMajor: 3, appMajor: 4))
    }

    func testMaxMajorCoversEveryPointReleaseOfThatMajor() throws {
        let keys = LicenceFixture.keyPair()
        let text = try LicenceFixture.licenceString(
            LicenceFixture.sample(maxMajor: 3),
            signedBy: keys.private
        )

        // 3.0, 3.1, 3.17 all report appMajor 3.
        XCTAssertEqual(LicenceVerifier(publicKey: keys.public, appMajor: 3).check(text).isValid, true)
        // And a licence bought for a later major still works on this one.
        let generous = try LicenceFixture.licenceString(
            LicenceFixture.sample(maxMajor: 5),
            signedBy: keys.private
        )
        XCTAssertEqual(LicenceVerifier(publicKey: keys.public, appMajor: 3).check(generous).isValid, true)
    }

    func testMajorOfVersionReadsTheLeadingComponent() {
        XCTAssertEqual(LicenceVerifier.major(ofVersion: "3.1.2"), 3)
        XCTAssertEqual(LicenceVerifier.major(ofVersion: "3"), 3)
        XCTAssertEqual(LicenceVerifier.major(ofVersion: "12.0"), 12)
        XCTAssertNil(LicenceVerifier.major(ofVersion: ""))
        XCTAssertNil(LicenceVerifier.major(ofVersion: "beta"))
    }

    // MARK: - Tolerant input, strict signature

    func testWhitespaceAndSmartQuotesFromAMailClientAreTolerated() throws {
        let keys = LicenceFixture.keyPair()
        let text = try LicenceFixture.licenceString(LicenceFixture.sample(), signedBy: keys.private)
        let verifier = LicenceVerifier(publicKey: keys.public, appMajor: 3)

        // Hard-wrapped by a mail client.
        let wrapped = stride(from: 0, to: text.count, by: 40).map {
            String(text.dropFirst($0).prefix(40))
        }.joined(separator: "\n")
        XCTAssertEqual(verifier.check(wrapped).isValid, true)

        // Curly quotes, a non-breaking space and a zero-width space.
        XCTAssertEqual(verifier.check("\u{201C}\u{00A0}\(text)\u{200B}\u{201D}").isValid, true)
        XCTAssertEqual(verifier.check("  '\(text)'  ").isValid, true)
    }

    func testMissingPaddingAndBase64URLAreTolerated() throws {
        let keys = LicenceFixture.keyPair()
        let text = try LicenceFixture.licenceString(LicenceFixture.sample(), signedBy: keys.private)
        let verifier = LicenceVerifier(publicKey: keys.public, appMajor: 3)

        let unpadded = text.replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(verifier.check(unpadded).isValid, true)

        let urlSafe = text
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        XCTAssertEqual(verifier.check(urlSafe).isValid, true)
    }

    /// Tolerance stops at whitespace and quotes. Stripping arbitrary characters
    /// would silently decode a *different* blob instead of refusing this one.
    func testSurroundingProseIsRefusedRatherThanSilentlyStripped() throws {
        let keys = LicenceFixture.keyPair()
        let text = try LicenceFixture.licenceString(LicenceFixture.sample(), signedBy: keys.private)
        let verifier = LicenceVerifier(publicKey: keys.public, appMajor: 3)

        let check = verifier.check("Here is your key: \(text) — enjoy!")
        XCTAssertNotEqual(check.isValid, true)
        XCTAssertEqual(check, .malformed)
    }

    // MARK: - The dropped-in file

    /// The one filesystem touch in licensing: a `.pearlicense` file dropped onto
    /// the app. Verification itself stays pure.
    func testPearLicenseFileIsAccepted() throws {
        let keys = LicenceFixture.keyPair()
        let licence = LicenceFixture.sample()
        let text = try LicenceFixture.licenceString(licence, signedBy: keys.private)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pear-\(UUID().uuidString)")
            .appendingPathExtension(LicenceVerifier.fileExtension)
        try Data("\(text)\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let verifier = LicenceVerifier(publicKey: keys.public, appMajor: 3)
        XCTAssertEqual(verifier.check(contentsOf: url), .valid(licence))
        XCTAssertEqual(LicenceVerifier.fileExtension, "pearlicense")
    }

    func testMissingFileIsMalformedRatherThanACrash() {
        let keys = LicenceFixture.keyPair()
        let verifier = LicenceVerifier(publicKey: keys.public, appMajor: 3)
        let url = URL(fileURLWithPath: "/nope/\(UUID().uuidString).pearlicense")
        XCTAssertEqual(verifier.check(contentsOf: url), .malformed)
    }

    // MARK: - The baked-in key

    /// Catches a mis-pasted public key constant: 32 raw bytes, base64, and a
    /// point CryptoKit accepts.
    func testBakedInPublicKeyParses() {
        XCTAssertNotNil(LicenceKey.publicKey, "LicenceKey.publicKeyBase64 is not a 32-byte Ed25519 key")
        XCTAssertNotNil(LicenceVerifier.app)
    }

    func testBakedInPlaceholderRejectsLicencesSignedByAnybodyElse() throws {
        let anyone = LicenceFixture.keyPair()
        let text = try LicenceFixture.licenceString(LicenceFixture.sample(), signedBy: anyone.private)
        let verifier = try XCTUnwrap(LicenceVerifier.app)
        XCTAssertEqual(verifier.check(text), .badSignature)
    }

    // MARK: - Wording

    func testEachOutcomeHasItsOwnWording() {
        let messages = [
            LicenceCheck.valid(LicenceFixture.sample()).message,
            LicenceCheck.badSignature.message,
            LicenceCheck.malformed.message,
            LicenceCheck.majorUnsupported(maxMajor: 3, appMajor: 4).message,
        ]
        XCTAssertEqual(Set(messages).count, 4)
        XCTAssertFalse(messages.contains(where: \.isEmpty))
        XCTAssertTrue(
            LicenceCheck.majorUnsupported(maxMajor: 3, appMajor: 4).message.contains("3.x"))
    }
}

extension LicenceCheck {
    fileprivate var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}
