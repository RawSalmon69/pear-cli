import Foundation
import CryptoKit

/// AES-GCM authenticated envelope over a 256-bit symmetric key.
///
/// `seal` returns the combined representation (nonce ‖ ciphertext ‖ tag) that
/// travels in a CloudKit field or CKAsset. `open` verifies the GCM tag and
/// throws on any AEAD failure — callers treat a throw as "not ours or
/// tampered" and ignore the record.
struct Envelope {
    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    func seal(_ data: Data) throws -> Data {
        let box = try AES.GCM.seal(data, using: key)
        guard let combined = box.combined else {
            throw EnvelopeError.sealFailed
        }
        return combined
    }

    func open(_ data: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key)
    }
}

enum EnvelopeError: Error {
    /// AES-GCM with a default nonce always yields a combined box; this only
    /// fires on an internal CryptoKit contract violation.
    case sealFailed
}
