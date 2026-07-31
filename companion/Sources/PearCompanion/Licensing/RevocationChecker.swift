import CryptoKit
import Foundation

/// When it is time to look at the revocation list again.
///
/// Written as a pure function over `(lastChecked, now, jitter)` so the cadence
/// is testable without waiting a week.
enum RevocationCadence {
    /// At most once per 7 days…
    static let interval: TimeInterval = 7 * 24 * 60 * 60
    /// …plus up to 24h of jitter, so a fleet of Macs does not all fetch the file
    /// on the same minute.
    static let maxJitter: TimeInterval = 24 * 60 * 60

    /// - Note: due does not mean "now". The caller runs the check at background
    ///   priority and **never on a launch path** — nothing about entitlement
    ///   waits on this.
    static func isDue(lastChecked: Date?, now: Date, jitter: TimeInterval) -> Bool {
        guard let lastChecked else { return true }
        // Clock moved backwards: the stored date is nonsense, so re-check rather
        // than wait out an interval that will never elapse.
        if now < lastChecked { return true }
        let wait = interval + min(max(jitter, 0), maxJitter)
        return now.timeIntervalSince(lastChecked) >= wait
    }

    static func randomJitter() -> TimeInterval { .random(in: 0...maxJitter) }
}

/// The local record of what the revocation list has told this Mac.
///
/// Keys live here rather than in `Prefs` because nothing in the UI toggles them:
/// they are a record, not a preference.
///
/// `@unchecked` because `UserDefaults` is documented thread-safe but not
/// annotated `Sendable`; the store adds no state of its own.
struct RevocationStore: @unchecked Sendable {
    static let revokedKey = "licenceRevoked"
    static let serialKey = "licenceRevocationSerial"
    static let lastCheckedKey = "licenceRevocationLastChecked"
    static let jitterKey = "licenceRevocationJitter"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Sticky: set once, never cleared.
    var isRevoked: Bool { defaults.bool(forKey: Self.revokedKey) }

    /// Highest serial ever applied. Monotonic.
    var knownSerial: Int { defaults.integer(forKey: Self.serialKey) }

    var lastChecked: Date? {
        guard let seconds = defaults.object(forKey: Self.lastCheckedKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// This install's jitter for the next check, rolled after each attempt.
    var jitter: TimeInterval { defaults.double(forKey: Self.jitterKey) }

    var isDue: Bool { isDue(now: Date()) }

    func isDue(now: Date) -> Bool {
        RevocationCadence.isDue(lastChecked: lastChecked, now: now, jitter: jitter)
    }

    /// Folds one decision into the record.
    ///
    /// - **Sticky**: a recorded revocation is never cleared. Not by a newer list
    ///   that omits the hash, not by a failed fetch, not by anything — which is
    ///   why there is no un-revoke path anywhere in this file.
    /// - **Monotonic**: the serial only climbs, so an older or replayed list
    ///   cannot lower the bar for the next one.
    /// - `lastChecked` advances on **every** attempt, including failures. A 404
    ///   or a dead domain must not turn into a retry storm.
    func apply(_ decision: RevocationDecision, from list: RevocationList.Load, now: Date) {
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastCheckedKey)
        defaults.set(RevocationCadence.randomJitter(), forKey: Self.jitterKey)

        if case .revoked = decision {
            defaults.set(true, forKey: Self.revokedKey)
        }
        if case let .success(list) = list, list.serial > knownSerial {
            defaults.set(list.serial, forKey: Self.serialKey)
        }
    }
}

/// Fetches the revocation list and applies its verdict.
///
/// The fetcher is injected, so no test touches the network. The live one is an
/// **anonymous** GET: a static URL, no query string, no identifier, no custom
/// header. The server learns "a Pear user checked in" and nothing more.
struct RevocationChecker: Sendable {
    typealias Fetcher = @Sendable () async throws -> Data

    private let fetch: Fetcher
    private let publicKey: Curve25519.Signing.PublicKey
    private let store: RevocationStore

    init(
        publicKey: Curve25519.Signing.PublicKey,
        store: RevocationStore = RevocationStore(),
        fetch: Fetcher? = nil
    ) {
        self.publicKey = publicKey
        self.store = store
        self.fetch = fetch ?? RevocationChecker.liveFetch
    }

    /// This build's checker, or nil if the baked-in key was pasted wrong.
    static func app(store: RevocationStore = RevocationStore()) -> RevocationChecker? {
        guard let key = LicenceKey.publicKey else { return nil }
        return RevocationChecker(publicKey: key, store: store)
    }

    /// One check, if the cadence allows it. Returns the decision that was
    /// applied, or nil when it was not yet time.
    ///
    /// Call from `Task(priority: .background)` once the app is up and idle —
    /// **never from a launch path**. Nothing here can revoke entitlement in a
    /// hurry, and nothing may make launch wait on the network.
    @discardableResult
    func checkIfDue(licenceHash: String, now: Date = Date()) async -> RevocationDecision? {
        guard store.isDue(now: now) else { return nil }
        return await check(licenceHash: licenceHash, now: now)
    }

    /// One check, cadence ignored. Fail-open in every branch: the fetch's throw
    /// becomes a reason, and `decision` turns every reason into `.ignore`.
    @discardableResult
    func check(licenceHash: String, now: Date = Date()) async -> RevocationDecision {
        let load: RevocationList.Load
        do {
            load = RevocationList.parse(try await fetch(), publicKey: publicKey)
        } catch {
            load = .failure(.unreachable)
        }

        let decision = RevocationList.decision(
            list: load,
            licenceHash: licenceHash,
            knownSerial: store.knownSerial
        )
        store.apply(decision, from: load, now: now)
        return decision
    }

    /// Anonymous GET of the static file. Any non-200 throws, and every throw is
    /// fail-open at the call site.
    private static func liveFetch() async throws -> Data {
        var request = URLRequest(url: RevocationList.url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RevocationFetchError.notAvailable
        }
        return data
    }
}

enum RevocationFetchError: Error {
    case notAvailable
}
