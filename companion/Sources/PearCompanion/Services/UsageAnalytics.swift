import CloudKit
import Foundation
import OSLog

/// Counts which tools actually get used, and reports the counts to the owner's
/// CloudKit container so the product can be cut down on evidence instead of
/// guesswork.
///
/// What is recorded: a per-tool tally of tile taps and hotkey presses, the app
/// and macOS versions, and a random install id. Nothing about *what* was done —
/// no screenshot contents, no clipboard text, no filenames, no window titles, no
/// timestamps per event. The tally is a dictionary of integers and that is the
/// whole payload.
///
/// It can be turned off in Settings → General, which stops both the counting and
/// the upload, and the same pane prints the exact payload so the claim above is
/// checkable rather than a promise. `site/privacy.html` documents it as the
/// fourth network connection the app makes.
@MainActor
@Observable
final class UsageAnalytics {
    /// One record per install, overwritten on every upload, in the public
    /// database — the private database would land in each user's own account
    /// where the owner could never read it.
    private static let recordType = "UsageReport"
    private static let containerID = "iCloud.com.rawsalmon69.pear"

    /// Upload at most this often. The counters are cumulative, so a missed
    /// window loses nothing.
    private static let uploadInterval: TimeInterval = 6 * 60 * 60

    private let defaults: UserDefaults
    private let database: CKDatabase?
    private let logger = Logger(subsystem: "com.rawsalmon69.pear.companion", category: "usage")

    /// Live counts, so the Settings pane can show what would be sent.
    private(set) var counts: [String: Int]

    /// `database: nil` means "never upload" — which is what tests use, and what
    /// any build without CloudKit gets. The container is built only by `live()`,
    /// deliberately: `CKContainer(identifier:)` **traps** in a process without
    /// the iCloud entitlement, so constructing one anywhere a test can reach
    /// takes the whole suite down with SIGTRAP. Do not put it back behind an
    /// environment sniff — `XCTestConfigurationFilePath` is not set under
    /// `swift test` on this toolchain, which is exactly how that crash happened.
    init(defaults: UserDefaults = .standard, database: CKDatabase?) {
        self.defaults = defaults
        self.counts = (defaults.dictionary(forKey: Prefs.usageCountsKey) as? [String: Int]) ?? [:]
        self.database = database
    }

    /// The production instance, built once by `AppEnvironment.live()`.
    static func live(defaults: UserDefaults = .standard) -> UsageAnalytics {
        UsageAnalytics(
            defaults: defaults,
            database: CKContainer(identifier: containerID).publicCloudDatabase)
    }

    // MARK: - Recording

    /// A tool was opened from its tile.
    func recordTileTap(_ toolID: String) { bump("tile.\(toolID)") }

    /// A tool's global shortcut fired.
    func recordHotkey(_ toolID: String) { bump("hotkey.\(toolID)") }

    /// The companion panel was opened.
    func recordPanelOpen() { bump("panel.open") }

    /// Counting stops the moment sharing is off, so turning it off does not
    /// merely withhold a tally that keeps growing in the background.
    private func bump(_ key: String) {
        guard Prefs.usageSharingEnabled else { return }
        counts[key, default: 0] += 1
        defaults.set(counts, forKey: Prefs.usageCountsKey)
    }

    // MARK: - Reporting

    /// The exact payload, in the order the Settings pane lists it.
    var report: [(key: String, count: Int)] {
        counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (key: $0.key, count: $0.value) }
    }

    /// Wipes the tally on this Mac. Offered next to the opt-out so turning
    /// sharing off can also erase what was already counted.
    func forget() {
        counts = [:]
        defaults.removeObject(forKey: Prefs.usageCountsKey)
        defaults.removeObject(forKey: Prefs.usageLastUploadKey)
    }

    /// Uploads if sharing is on and the interval has elapsed. Every failure is
    /// silent and non-fatal: no iCloud account, no network, a schema that has not
    /// been deployed yet — none of that is the user's problem, and none of it may
    /// interrupt the app.
    func uploadIfDue(force: Bool = false) async {
        guard Prefs.usageSharingEnabled, !counts.isEmpty, let database else { return }
        let last = defaults.object(forKey: Prefs.usageLastUploadKey) as? Date
        if !force, let last, Date().timeIntervalSince(last) < Self.uploadInterval { return }

        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(recordName: "usage-\(installID)"))
        record["installID"] = installID as CKRecordValue
        record["appVersion"] = appVersion as CKRecordValue
        record["systemVersion"] = ProcessInfo.processInfo.operatingSystemVersionString as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue
        // One JSON blob rather than a field per tool: adding a tool must not mean
        // editing the CloudKit schema.
        if let json = try? JSONEncoder().encode(counts) {
            record["counts"] = String(decoding: json, as: UTF8.self) as CKRecordValue
        }

        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            defaults.set(Date(), forKey: Prefs.usageLastUploadKey)
        } catch {
            logger.debug("usage upload skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Identity

    /// A random id, generated once per install and never derived from anything
    /// about the machine or the person: it distinguishes installs from each other
    /// and identifies nobody.
    var installID: String {
        if let existing = defaults.string(forKey: Prefs.usageInstallIDKey) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: Prefs.usageInstallIDKey)
        return fresh
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
