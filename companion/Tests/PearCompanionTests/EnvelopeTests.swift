import XCTest
import CryptoKit
@testable import PearCompanion

final class EnvelopeTests: XCTestCase {
    func testTextRoundTrip() throws {
        let envelope = Envelope(key: SymmetricKey(size: .bits256))
        let plaintext = Data("i love you 🍐 — see you tonight".utf8)
        let sealed = try envelope.seal(plaintext)
        XCTAssertNotEqual(sealed, plaintext)
        let opened = try envelope.open(sealed)
        XCTAssertEqual(opened, plaintext)
    }

    func testBinaryRoundTrip() throws {
        let envelope = Envelope(key: SymmetricKey(size: .bits256))
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        let plaintext = Data(bytes)
        let opened = try envelope.open(try envelope.seal(plaintext))
        XCTAssertEqual(opened, plaintext)
    }

    func testTamperedCiphertextThrows() throws {
        let envelope = Envelope(key: SymmetricKey(size: .bits256))
        var sealed = try envelope.seal(Data("secret".utf8))
        // Flip one bit in the ciphertext body (past the 12-byte nonce).
        sealed[sealed.count / 2] ^= 0x01
        XCTAssertThrowsError(try envelope.open(sealed))
    }

    func testWrongKeyFails() throws {
        let sender = Envelope(key: SymmetricKey(size: .bits256))
        let stranger = Envelope(key: SymmetricKey(size: .bits256))
        let sealed = try sender.seal(Data("secret".utf8))
        XCTAssertThrowsError(try stranger.open(sealed))
    }

    func testGarbageDataThrows() {
        let envelope = Envelope(key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try envelope.open(Data("not an envelope".utf8)))
        XCTAssertThrowsError(try envelope.open(Data()))
    }

    func testGeneratedCoupleKeyIsValidBase64Key() throws {
        let base64 = CoupleKey.generate()
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertEqual(data.count, 32)

        // A generated key must work end to end with the envelope.
        let envelope = Envelope(key: SymmetricKey(data: data))
        let opened = try envelope.open(try envelope.seal(Data("hello".utf8)))
        XCTAssertEqual(opened, Data("hello".utf8))
    }
}
