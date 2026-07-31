import XCTest
@testable import PearCompanion

/// The rollout has two safety properties that are easy to lose and expensive to
/// get wrong, because both fail on real people's machines rather than in CI:
/// the lock must not engage before the signing key is real, and the trial clock
/// must not start before the lock exists.
@MainActor
final class EntitlementRolloutTests: XCTestCase {
    /// A trial store that records whether anyone asked, so "the clock never
    /// started" is observable rather than asserted by inspection.
    private final class SpyStore: TrialStore, @unchecked Sendable {
        private(set) var reads = 0
        private(set) var writes = 0
        private var record: TrialRecord?

        func read() -> TrialRecord? {
            reads += 1
            return record
        }

        func write(_ record: TrialRecord) {
            writes += 1
            self.record = record
        }
    }

    private func store(_ spy: SpyStore, now: Date) -> TrialState {
        TrialState(stores: [spy], now: { now })
    }

    /// Reading the trial is what *begins* it. Shipping the licensing code with
    /// the paywall off must therefore not read it at all, or everyone who has
    /// the app today quietly burns their 14 days and is locked out the moment
    /// the flag flips.
    func testTheTrialClockDoesNotStartWhileThePaywallIsOff() throws {
        try XCTSkipIf(FeatureFlags.paywall, "only meaningful in a pre-launch build")
        let spy = SpyStore()
        let entitlement = EntitlementStore(
            licenceStore: LicenceFileStore(directory: emptyDirectory()),
            trial: store(spy, now: Date())
        )

        XCTAssertEqual(spy.reads, 0, "nothing may read the trial before the paywall is real")
        XCTAssertEqual(spy.writes, 0, "and nothing may start it")
        XCTAssertEqual(entitlement.entitlement, .trial(daysRemaining: TrialState.trialDays))
    }

    /// While the flag is off nothing is locked, whatever the trial would have
    /// said. This is the property that makes the licensing code safe to ship
    /// ahead of the key.
    func testNothingIsLockedWhileThePaywallIsOff() throws {
        try XCTSkipIf(FeatureFlags.paywall, "only meaningful in a pre-launch build")
        let entitlement = EntitlementStore(
            licenceStore: LicenceFileStore(directory: emptyDirectory()),
            trial: store(SpyStore(), now: Date())
        )

        XCTAssertTrue(entitlement.entitlement.unlocksTools)
    }

    /// The placeholder key must not verify anything. If this ever fails, someone
    /// pasted a real key in and the flag needs the rest of the rollout done.
    func testAnArbitraryStringIsNotAValidLicence() {
        let entitlement = EntitlementStore(
            licenceStore: LicenceFileStore(directory: emptyDirectory()),
            trial: store(SpyStore(), now: Date())
        )

        if case .valid = entitlement.activate("not-a-licence") {
            XCTFail("an arbitrary string must never verify")
        }
    }

    /// A licence file that does not parse leaves the user on their trial rather
    /// than in an error state — a corrupt file is not evidence of expiry.
    func testACorruptLicenceFileFallsBackRatherThanLockingOut() {
        let directory = emptyDirectory()
        let store = LicenceFileStore(directory: directory)
        store.write("}}} not base64 {{{")

        let entitlement = EntitlementStore(
            licenceStore: store, trial: self.store(SpyStore(), now: Date()))

        XCTAssertTrue(entitlement.entitlement.unlocksTools)
        XCTAssertNil(entitlement.licenceHash)
    }

    private func emptyDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pear-entitlement-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
