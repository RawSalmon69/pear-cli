import CryptoKit
import Foundation

/// A refunded order is removed from entitlement by a **static, signed file** at
/// `pear.phanthawas.dev/revoked.json`, deployed with the site. No server, no
/// per-user endpoint.
///
/// ```json
/// {
///   "serial": 3,
///   "issued": "2026-08-01T00:00:00Z",
///   "revoked": ["<sha256 of order id>", "…"],
///   "signature": "<base64 ed25519 over the canonical payload>"
/// }
/// ```
///
/// Five rules, all of them tested:
///
/// 1. **Fail-open, always.** Network error, 404, bad JSON, dead domain, bad
///    signature, unparseable date — none of them ever affect entitlement. A
///    refunded user keeping the app is an acceptable loss; a paying user locked
///    out by a DNS blip is not. Structurally: every failure arrives as
///    `.failure(reason)` and `decision` turns all of them into `.ignore`.
/// 2. **Signed**, domain-separated by `pear-revocation-v1` (see `SigningDomain`).
///    TLS protects the transport; the signature protects the authority.
/// 3. **Hashed order ids**, because the file is public and order ids are not.
/// 4. **Anonymous fetch** (see `RevocationChecker`).
/// 5. **Sticky and monotonic** (see `RevocationStore`).
struct RevocationList: Equatable, Sendable {
    let serial: Int
    let issued: Date
    let revoked: [String]

    /// The one thing the app says when a licence has been revoked. A refund is
    /// what actually happened; a generic error reads as a bug in Pear.
    static let refundedMessage = "This license was refunded"

    /// Where the file lives. Static path, no query string, no identifier.
    static let url = URL(string: "https://pear.phanthawas.dev/revoked.json")!

    /// The exact bytes covered by the signature, before domain separation.
    ///
    /// Line-oriented rather than re-serialized JSON: `revoke.sh` has to produce
    /// these bytes with `printf`, and canonical JSON in bash is a bug farm. The
    /// hashes are used in the order they appear in the file — never re-sorted
    /// here, or a list written in a different order would stop verifying.
    static func canonicalBody(serial: Int, issued: String, revoked: [String]) -> Data {
        var lines = ["serial=\(serial)", "issued=\(issued)"]
        lines.append(contentsOf: revoked.map { "revoked=\($0)" })
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// Parses and authenticates the fetched bytes. Every rejection is a reason,
    /// never a throw, so the caller cannot accidentally treat one as a failure
    /// that matters.
    static func parse(_ data: Data, publicKey: Curve25519.Signing.PublicKey) -> Load {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            return .failure(.malformedJSON)
        }
        guard
            let signature = Data(base64Encoded: LicenceText.normalized(wire.signature)),
            signature.count == 64
        else {
            return .failure(.malformedJSON)
        }

        let body = canonicalBody(serial: wire.serial, issued: wire.issued, revoked: wire.revoked)
        guard publicKey.isValidSignature(signature, for: SigningDomain.revocation.message(body)) else {
            return .failure(.badSignature)
        }

        // Parsed after the signature check, so this only ever rejects a file the
        // owner really signed — which means the file is not the shape we think
        // it is, and acting on it would be guessing.
        guard let issued = Self.iso8601().date(from: wire.issued) else {
            return .failure(.unparseableDate)
        }

        return .success(RevocationList(serial: wire.serial, issued: issued, revoked: wire.revoked))
    }

    /// The whole policy, in one pure function over an already-loaded list.
    ///
    /// - `knownSerial` is the highest serial this Mac has already applied. A
    ///   list with an older *or equal* serial is ignored outright, so a replayed
    ///   older file can never un-revoke anything.
    /// - There is deliberately no "reinstated" outcome. Revocation is sticky:
    ///   `RevocationStore` records it and never clears it.
    static func decision(
        list: Load,
        licenceHash: String,
        knownSerial: Int
    ) -> RevocationDecision {
        switch list {
        case let .failure(reason):
            // Rule 1, structurally: every failure mode lands here.
            return .ignore(reason)
        case let .success(list):
            guard list.serial > knownSerial else {
                return .ignore(.staleSerial(list.serial))
            }
            guard !licenceHash.isEmpty else { return .unchanged }
            let needle = licenceHash.lowercased()
            return list.revoked.contains { $0.lowercased() == needle } ? .revoked : .unchanged
        }
    }

    /// A loaded list, or the reason it does not count.
    typealias Load = Result<RevocationList, RevocationIgnoreReason>

    private struct Wire: Decodable {
        let serial: Int
        let issued: String
        let revoked: [String]
        let signature: String
    }

    /// Built per call: `ISO8601DateFormatter` is not `Sendable`, and this runs
    /// once a week at most.
    private static func iso8601() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}

/// Why a fetched list had no effect. Diagnostics only — every one of these is
/// fail-open by construction.
enum RevocationIgnoreReason: Error, Equatable, Sendable {
    /// Transport error, non-200, 404, dead domain, empty body.
    case unreachable
    /// Not JSON, missing fields, or a signature field that is not 64 bytes.
    case malformedJSON
    /// Signed by something other than the owner's key, or signed as a licence
    /// rather than as a revocation list.
    case badSignature
    /// Authentic, but `issued` is not an ISO-8601 instant.
    case unparseableDate
    /// Serial older than or equal to what this Mac already applied.
    case staleSerial(Int)
}

enum RevocationDecision: Equatable, Sendable {
    /// The list was authentic and newer, and this licence is not in it.
    case unchanged
    /// This licence is in an authentic, newer list.
    case revoked
    /// The list had no effect. Entitlement is untouched.
    case ignore(RevocationIgnoreReason)
}
