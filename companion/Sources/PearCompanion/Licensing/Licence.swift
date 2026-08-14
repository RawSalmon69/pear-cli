import CryptoKit
import Foundation

/// Domain separation for every Ed25519 signature Pear verifies.
///
/// The signed bytes are always `label ‖ "\n" ‖ body`, so two different domains
/// can never produce the same message. That is what stops a licence being
/// replayed as a revocation list, or a revocation list as a licence: both are
/// signed by the same key, and the label is the only thing that says which one
/// the owner meant. Every signer and verifier — Swift and shell — goes through
/// here; there is no second place a message is assembled.
enum SigningDomain: String, Sendable {
    case licence = "pear-licence-v1"
    case revocation = "pear-revocation-v1"

    func message(_ body: Data) -> Data {
        Data(rawValue.utf8) + Data("\n".utf8) + body
    }
}

/// The owner's Ed25519 public key, baked into the binary. There is no
/// activation server: the app verifies licences locally, works offline forever,
/// and keeps working if the payment processor disappears.
enum LicenceKey {
    /// **PLACEHOLDER — replace before selling anything.**
    ///
    /// Base64 of the 32 raw bytes of the owner's Ed25519 public key. Generate
    /// the real pair on the owner's Mac with `companion/scripts/license-keygen.sh`.
    /// **The private half must never enter this repo** — it lives in
    /// `~/.pear-licensing/`, and the keygen script refuses any path inside a git
    /// worktree. Losing it means no licence can ever be issued or revoked again,
    /// so it wants an offline backup.
    ///
    /// This is the real key, generated 2026-08-15. Replacing it invalidates every
    /// licence already issued.
    static let publicKeyBase64 = "yVy1D+TPA7kI/aHc2Iy/4VtPjF2aT+/mcY+yzP7WPgg="

    /// The baked-in key, or nil if the constant above was pasted wrong.
    static var publicKey: Curve25519.Signing.PublicKey? {
        publicKey(base64: publicKeyBase64)
    }

    static func publicKey(base64: String) -> Curve25519.Signing.PublicKey? {
        guard let raw = Data(base64Encoded: LicenceText.normalized(base64)), raw.count == 32 else {
            return nil
        }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }
}

/// What the owner signed, one per order.
///
/// `maxMajor: 3` means "every 3.x update"; Pear 4 is a paid upgrade. There is
/// no device limit — no server exists to count against, and the buyer's email
/// shown in Settings is the whole enforcement model.
struct Licence: Equatable, Sendable, Codable {
    let email: String
    let orderID: String
    let issuedAt: Date
    let maxMajor: Int

    /// The identifier the *public* revocation list carries. Order ids are not
    /// public, so the list holds their SHA-256 instead.
    var orderHash: String { Licence.hash(orderID: orderID) }

    static func hash(orderID: String) -> String {
        SHA256.hash(data: Data(orderID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// The four outcomes of checking a licence. They stay distinct because the UI
/// words each one differently — collapsing them into a bool loses the only
/// information the user needs to fix the problem.
enum LicenceCheck: Equatable, Sendable {
    /// Signed by the owner's key and valid for this major version.
    case valid(Licence)
    /// Well-formed, but not signed by the owner's key. Tampered or invented.
    case badSignature
    /// Not a licence at all: undecodable, truncated, or unreadable contents.
    case malformed
    /// Genuine, but bought for an older major version. Needs a paid upgrade.
    case majorUnsupported(maxMajor: Int, appMajor: Int)

    /// Default user-facing wording. The UI may reword these, but the four
    /// outcomes exist so that it can.
    var message: String {
        switch self {
        case .valid:
            return "Licence verified"
        case .badSignature:
            return "This licence key isn't valid."
        case .malformed:
            return "That doesn't look like a Pear licence key."
        case let .majorUnsupported(maxMajor, appMajor):
            return "This licence covers Pear \(maxMajor).x. Pear \(appMajor) is a paid upgrade."
        }
    }
}

/// Verifies licence strings against a public key. Pure: no network, no
/// filesystem, no clock. The key and the app's major version are injected so
/// tests can sign fixtures with an ephemeral pair.
struct LicenceVerifier: Sendable {
    /// A licence file dropped onto the app carries this extension.
    static let fileExtension = "pearlicense"

    let publicKey: Curve25519.Signing.PublicKey
    let appMajor: Int

    /// This build's verifier: the baked-in key and this build's major version.
    /// Nil only if `LicenceKey.publicKeyBase64` was pasted wrong.
    static var app: LicenceVerifier? {
        guard let key = LicenceKey.publicKey else { return nil }
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        // An unreadable version falls back to 1, which accepts every licence:
        // the wrong direction to fail is locking out a buyer.
        return LicenceVerifier(publicKey: key, appMajor: short.flatMap(Self.major(ofVersion:)) ?? 1)
    }

    /// Leading integer of a marketing version string ("3.1.2" -> 3).
    static func major(ofVersion version: String) -> Int? {
        Int(version.split(separator: ".").first ?? "")
    }

    /// A licence string as pasted by a human — leading/trailing junk from a mail
    /// client is tolerated, the signature is not.
    func check(_ text: String) -> LicenceCheck {
        guard let blob = Data(base64Encoded: LicenceText.normalized(text)), blob.count > 64 else {
            return .malformed
        }

        // Signature first, so only authenticated bytes are ever parsed.
        let signature = blob.prefix(64)
        let payload = blob.dropFirst(64)
        guard publicKey.isValidSignature(signature, for: SigningDomain.licence.message(payload)) else {
            return .badSignature
        }

        guard
            let licence = try? LicenceText.decoder.decode(Licence.self, from: payload),
            !licence.email.isEmpty,
            !licence.orderID.isEmpty
        else {
            return .malformed
        }

        guard licence.maxMajor >= appMajor else {
            return .majorUnsupported(maxMajor: licence.maxMajor, appMajor: appMajor)
        }
        return .valid(licence)
    }

    /// A `.pearlicense` file dropped onto the app. The read is the only
    /// filesystem touch in licensing; everything else is pure.
    func check(contentsOf url: URL) -> LicenceCheck {
        guard
            let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else {
            return .malformed
        }
        return check(text)
    }
}

/// Text handling for pasted base64. Tolerant on input, strict on the signature.
enum LicenceText {
    /// Quote and invisible characters a mail client wraps a key in. Whitespace
    /// is handled separately (it covers newlines, tabs and non-breaking spaces).
    private static let noise: Set<Character> = [
        "\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}",
        "\u{00AB}", "\u{00BB}", "`", "\u{200B}", "\u{FEFF}",
    ]

    /// Strips wrapping noise, folds base64url into standard base64, and repairs
    /// missing padding. Deliberately does *not* strip arbitrary characters:
    /// dropping letters would silently turn "Your key: AAAA" into a different
    /// blob instead of rejecting it.
    static func normalized(_ raw: String) -> String {
        var cleaned = String(raw.filter { !$0.isWhitespace && !noise.contains($0) })
        cleaned = cleaned.replacingOccurrences(of: "-", with: "+")
        cleaned = cleaned.replacingOccurrences(of: "_", with: "/")
        let remainder = cleaned.count % 4
        if remainder > 0 {
            cleaned += String(repeating: "=", count: 4 - remainder)
        }
        return cleaned
    }

    /// Licence payloads carry `issuedAt` as a plain ISO-8601 instant.
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
