import Foundation
import Observation

/// Why the app is locked. Each case gets its own wording, because "your trial
/// ended" and "this licence was refunded" are very different messages to receive
/// and a generic error for the second one reads as a bug.
enum ExpiryReason: Equatable, Sendable {
    case trialEnded
    case licenceRefunded
    /// A genuine licence bought for an older major version. Not a failure — an
    /// upgrade offer.
    case licenceForOlderMajor(maxMajor: Int)
}

/// What the user is entitled to right now.
enum Entitlement: Equatable, Sendable {
    case licensed(email: String)
    case trial(daysRemaining: Int)
    case expired(ExpiryReason)

    /// Whether the paid tools run. The single question the tool registry asks.
    var unlocksTools: Bool {
        switch self {
        case .licensed, .trial: return true
        case .expired: return false
        }
    }
}

/// Where the entered licence blob lives. The **signed string** is stored, never
/// a "licensed = true" flag: the entitlement is re-derived by verifying that
/// string against the baked-in key on every launch, so there is no boolean to
/// flip and nothing to forge short of the owner's private key.
///
/// Application Support rather than `UserDefaults`, for the same reason
/// `TrialState` avoids it — this is a record, not a preference.
struct LicenceFileStore: Sendable {
    static let fileName = "licence.\(LicenceVerifier.fileExtension)"

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PearCompanion", isDirectory: true)
    }

    private var file: URL { directory.appendingPathComponent(Self.fileName) }

    func read() -> String? { try? String(contentsOf: file, encoding: .utf8) }

    func write(_ text: String) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    func clear() { try? FileManager.default.removeItem(at: file) }
}

/// Resolves the entitlement from the three inputs that decide it, and is the one
/// place their precedence is written down.
///
/// `@Observable` so the panel, the settings pane and the locked state all follow
/// a licence being entered without a relaunch.
@MainActor
@Observable
final class EntitlementStore {
    private(set) var entitlement: Entitlement = .expired(.trialEnded)

    /// SHA-256 of the licensed order id, or nil when no valid licence is stored.
    /// The revocation list is public, so it carries hashes and never order ids.
    @ObservationIgnored private(set) var licenceHash: String?

    @ObservationIgnored private let licenceStore: LicenceFileStore
    @ObservationIgnored private let revocationStore: RevocationStore
    @ObservationIgnored private let trial: TrialState
    @ObservationIgnored private let verifier: LicenceVerifier?

    /// Fired when the entitlement actually changes value. `AppEnvironment` hangs
    /// the tool registry's `reregister()` here, so a licence entered mid-session
    /// brings the tools back without a relaunch.
    @ObservationIgnored var onChange: (() -> Void)?

    init(
        licenceStore: LicenceFileStore = LicenceFileStore(),
        revocationStore: RevocationStore = RevocationStore(),
        trial: TrialState = TrialState(),
        verifier: LicenceVerifier? = LicenceVerifier.app
    ) {
        self.licenceStore = licenceStore
        self.revocationStore = revocationStore
        self.trial = trial
        self.verifier = verifier
        refresh()
    }

    /// Verifies `text` and, only if it is genuinely valid, keeps it. An invalid
    /// paste never overwrites a working licence — the user gets the reason back
    /// and their existing entitlement is untouched.
    @discardableResult
    func activate(_ text: String) -> LicenceCheck {
        guard let verifier else { return .malformed }
        let check = verifier.check(text)
        if case .valid = check {
            licenceStore.write(text)
            refresh()
        }
        return check
    }

    /// Forgets the stored licence and falls back to whatever the trial says.
    /// Deliberately does not clear the revocation record — it is sticky by
    /// design, so a refunded licence re-entered stays refunded.
    func removeLicence() {
        licenceStore.clear()
        refresh()
    }

    /// Precedence, in order:
    ///
    /// 1. A stored licence that verifies **and** has not been revoked wins, for
    ///    as long as it covers this major version. Paid users never see a trial
    ///    countdown, and never lose access because a clock moved.
    /// 2. A revoked licence is `.licenceRefunded`, not a fallback to the trial:
    ///    a refund is not a fresh 14 days.
    /// 3. Otherwise the trial decides. A licence that fails to verify is treated
    ///    as absent rather than as an error state, so a corrupt file cannot lock
    ///    out someone whose trial is still running.
    func refresh() {
        let before = entitlement
        defer { if entitlement != before { onChange?() } }
        licenceHash = nil
        if let text = licenceStore.read(), let verifier {
            switch verifier.check(text) {
            case .valid(let licence):
                licenceHash = licence.orderHash
                if revocationStore.isRevoked {
                    entitlement = .expired(.licenceRefunded)
                } else {
                    entitlement = .licensed(email: licence.email)
                }
                return
            case .majorUnsupported(let maxMajor, _):
                entitlement = .expired(.licenceForOlderMajor(maxMajor: maxMajor))
                return
            case .badSignature, .malformed:
                break // fall through to the trial
            }
        }
        // The trial clock must not start before the paywall exists. Reading
        // `trial.status()` is what *begins* a trial, so calling it in a build
        // where `FeatureFlags.paywall` is off would silently burn 14 days for
        // everyone who has the app today — and they would be locked out the
        // instant the flag flipped, which is precisely the auto-update-into-a-
        // paywall failure this whole rollout is shaped to avoid.
        guard FeatureFlags.paywall else {
            entitlement = .trial(daysRemaining: TrialState.trialDays)
            return
        }
        switch trial.status() {
        case .active(let daysRemaining):
            entitlement = .trial(daysRemaining: daysRemaining)
        case .expired:
            entitlement = .expired(.trialEnded)
        }
    }

    /// Runs the weekly revocation check, if it is due, and folds the verdict in.
    ///
    /// Call from a background task, never from a launch path: it makes a network
    /// request. Every failure mode is fail-open inside `RevocationChecker`, so a
    /// dead domain or a 404 cannot touch entitlement — and there is nothing to do
    /// at all without a licence to check.
    func checkRevocationIfDue() async {
        guard let hash = licenceHash, let key = LicenceKey.publicKey else { return }
        let checker = RevocationChecker(publicKey: key, store: revocationStore)
        guard case .revoked = await checker.checkIfDue(licenceHash: hash) else { return }
        refresh()
    }
}
