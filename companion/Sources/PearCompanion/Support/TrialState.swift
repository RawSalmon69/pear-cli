import Foundation
import Security

/// Whether the free trial is still running, and for how much longer.
///
/// `daysRemaining` is always derived from the two persisted dates, never
/// stored, and never negative — a trial with no time left is `.expired`.
enum TrialStatus: Equatable, Sendable {
    case active(daysRemaining: Int)
    case expired
}

/// The two dates a trial is entirely defined by.
///
/// The reconciliation rules are **deliberately opposite**, and getting either
/// one backwards is the whole bug class here:
///
/// - `startedAt` takes the **earliest** value any store holds. Clearing one
///   store must not restart the trial.
/// - `newestSeen` takes the **latest** value any store holds. Winding the clock
///   back must not buy more days.
struct TrialRecord: Equatable, Sendable, Codable {
    /// When the trial began. Reconciled to the EARLIEST value seen.
    var startedAt: Date
    /// The newest date ever observed on this Mac. Reconciled to the LATEST
    /// value seen — a watermark, not a "last launch" timestamp.
    var newestSeen: Date
}

/// One place the trial record is kept. Two independent stores back the trial
/// (login Keychain + Application Support file) so deleting either one — or
/// deleting one and reinstalling with the other intact — does not restart it.
///
/// Both operations are deliberately non-throwing: a store that cannot be read,
/// holds garbage, or cannot be written is *no evidence*, never evidence of
/// expiry. Ambiguity fails toward the user, not toward the paywall.
protocol TrialStore: Sendable {
    /// The record this store holds, or nil when it holds none, holds something
    /// that does not decode, or cannot be reached at all.
    func read() -> TrialRecord?
    /// Best-effort persist. Silently does nothing if the store is unreachable.
    func write(_ record: TrialRecord)
}

/// The 14-day trial: every feature, no account, no card, no email.
///
/// State only — this type decides whether the trial is running and hands back a
/// `TrialStatus`. It gates nothing and draws nothing.
///
/// Every seam is injected: the clock is a closure and each store is a protocol,
/// so the tests never touch the real Keychain or the real Application Support
/// path.
struct TrialState: Sendable {
    /// The whole trial. The only place 14 appears.
    static let trialDays = 14
    static let day: TimeInterval = 24 * 60 * 60
    static var length: TimeInterval { Double(trialDays) * day }

    /// How far behind the watermark `now` may sit before we call it tampering.
    ///
    /// A strict `now < newestSeen` test would end the trial on an ordinary NTP
    /// correction or a drifting RTC, which is failing toward the paywall over
    /// something the user did not do. The tolerance is safe because the
    /// watermark is a *maximum*: whatever a user gains by nudging the clock back
    /// is capped at this one hour in total, not per launch.
    static let clockDriftTolerance: TimeInterval = 60 * 60

    let stores: [any TrialStore]
    let now: @Sendable () -> Date

    init(
        stores: [any TrialStore] = [KeychainTrialStore(), FileTrialStore()],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.stores = stores
        self.now = now
    }

    /// Reads every store, reconciles them, writes the result back to any store
    /// that was missing or behind, then answers the question.
    ///
    /// This touches the Keychain and the disk, so call it at launch or when
    /// something actually needs the answer — not from a view body that
    /// re-evaluates per frame.
    func status() -> TrialStatus {
        let now = self.now()
        let stored = stores.map { $0.read() }
        let record = Self.reconciled(stored, now: now)
        for (store, existing) in zip(stores, stored) where existing != record {
            store.write(record)
        }
        return Self.status(for: record, now: now)
    }

    /// The pure decision. Only two things end a trial: 14 days genuinely
    /// elapsed, or the clock rolled back behind the watermark.
    static func status(for record: TrialRecord, now: Date) -> TrialStatus {
        if now < record.newestSeen - clockDriftTolerance { return .expired }
        let remaining = length - now.timeIntervalSince(record.startedAt)
        guard remaining > 0 else { return .expired }
        // Round up so the last partial day still reads as a day. Clamped in
        // Double space, before the Int conversion: a start date in the future —
        // an ahead-of-time clock, or a decodable-but-absurd file — otherwise
        // overflows the conversion and traps.
        return .active(daysRemaining: Int(min(Double(trialDays), (remaining / day).rounded(.up))))
    }

    /// Folds what the stores hold into one record: earliest start, latest
    /// watermark. `nil` entries contribute nothing — only a machine where
    /// *every* store came back empty gets a fresh trial.
    static func reconciled(_ stored: [TrialRecord?], now: Date) -> TrialRecord {
        let known = stored.compactMap { $0 }
        guard
            let earliestStart = known.map(\.startedAt).min(),
            let highWatermark = known.map(\.newestSeen).max()
        else {
            return TrialRecord(startedAt: now, newestSeen: now)
        }
        return TrialRecord(startedAt: earliestStart, newestSeen: max(highWatermark, now))
    }
}

// MARK: - Real stores

extension TrialRecord {
    /// Both stores keep the same JSON blob, so there is one codec. The default
    /// `Date` strategy is used on purpose: it round-trips exactly, where
    /// `.iso8601` would quietly truncate the watermark to whole seconds.
    var json: Data? { try? JSONEncoder().encode(self) }

    init?(json data: Data) {
        guard let record = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = record
    }
}

/// The trial record in the login Keychain, as a generic-password item. Survives
/// a wiped Application Support folder — including one wiped by `pear clean`.
///
/// The login (file-based) Keychain on purpose, not the data-protection one:
/// `kSecUseDataProtectionKeychain` needs a `keychain-access-groups` entitlement
/// the app does not carry, and `CoupleKey` already proves this path works in the
/// notarised build.
///
/// Measured with an ad-hoc-signed binary, which is what a `build.sh` dev build
/// is: add / read / update / delete all succeed for the binary that created the
/// item, but a *rebuilt* binary is a different code identity, so its read hits
/// the item's ACL — one "wants to use your confidential information" prompt per
/// rebuild, and `errSecAuthFailed` if it is denied or interaction is off.
/// (`kSecUseAuthenticationUIFail` does not suppress it; the legacy Keychain
/// ignores the key.) Signed builds share one stable Developer ID identity and
/// never see this. Either way every failure path returns nil or does nothing, so
/// the file store carries the trial rather than the trial reading as expired.
struct KeychainTrialStore: TrialStore {
    let service: String
    let account: String

    init(service: String = "com.rawsalmon69.pear.companion", account: String = "trial") {
        self.service = service
        self.account = account
    }

    private var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() -> TrialRecord? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return TrialRecord(json: data)
    }

    func write(_ record: TrialRecord) {
        guard let data = record.json else { return }
        let update = [kSecValueData as String: data] as CFDictionary
        if SecItemUpdate(item as CFDictionary, update) == errSecItemNotFound {
            var attributes = item
            attributes[kSecValueData as String] = data
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }
}

/// The trial record at
/// `~/Library/Application Support/PearCompanion/trial.json`. Survives a Keychain
/// the app cannot reach, and is the store that carries an unsigned dev build.
struct FileTrialStore: TrialStore {
    let url: URL

    init(url: URL = FileTrialStore.defaultURL) {
        self.url = url
    }

    /// Same folder as the shelf, the scratchpad and the capture store (the app
    /// is not sandboxed).
    static var defaultURL: URL {
        let base =
            FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("PearCompanion", isDirectory: true)
            .appendingPathComponent("trial.json")
    }

    func read() -> TrialRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return TrialRecord(json: data)
    }

    func write(_ record: TrialRecord) {
        guard let data = record.json else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
