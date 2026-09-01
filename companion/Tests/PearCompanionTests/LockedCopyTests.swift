import CryptoKit
import XCTest

@testable import PearCompanion

/// The locked state and the licence pane are the two screens a person reads
/// while deciding whether Pear was worth paying for, so the copy is asserted
/// here as writing: the exact sentence per `ExpiryReason`, the refund sentence
/// verbatim, the promise about the user's own content, and the rule that a
/// rejected licence comes back in the rejecting check's own words.
///
/// Layout is deliberately untested — there is no screen in CI, and a snapshot of
/// a glass card would test the material, not the wording.
@MainActor
final class LockedCopyTests: XCTestCase {
    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("license-pane-\(UUID().uuidString)", isDirectory: true)
        suite = "license-pane-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        // A suite left behind is a global this test set; unique names keep it
        // from reaching another test, removing it keeps it off the disk.
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - Trial ended

    func testTheTrialEndedCopyStatesWhatHappenedAndWhatItCosts() {
        let copy = LockedCopy.of(.trialEnded)
        XCTAssertEqual(copy.headline, "The trial has ended")
        XCTAssertEqual(
            copy.detail,
            "Pear ran with everything switched on for fourteen days. "
                + "The tools are paused now, and a license turns them back on.")
        XCTAssertEqual(
            copy.price,
            "$19, once, for every Pear 3.x update, on any Mac you own. No subscription.")
        XCTAssertEqual(copy.symbol, "hourglass")
    }

    // MARK: - Refunded

    func testTheRefundedHeadlineIsTheRefundSentenceVerbatim() {
        XCTAssertEqual(LockedCopy.of(.licenceRefunded).headline, RevocationList.refundedMessage)
        XCTAssertEqual(LockedCopy.of(.licenceRefunded).headline, "This license was refunded")
    }

    func testTheRefundedCopyOffersAHumanRatherThanAnError() {
        let copy = LockedCopy.of(.licenceRefunded)
        XCTAssertEqual(
            copy.detail,
            "The order behind this license was refunded, so it no longer unlocks the tools. "
                + "If that is a surprise, write to contact@phanthawas.dev and we will sort it out.")
        XCTAssertTrue(copy.detail.contains(LockedCopy.supportEmail))
        XCTAssertEqual(copy.price, "A new license is $19, once.")
        XCTAssertEqual(copy.symbol, "arrow.uturn.backward")
    }

    // MARK: - Licence for an older major

    func testTheOlderMajorCopyReadsAsAnUpgradeOfferNotAFailure() {
        let copy = LockedCopy.of(.licenceForOlderMajor(maxMajor: 3))
        XCTAssertEqual(copy.headline, "Your license covers Pear 3")
        XCTAssertEqual(
            copy.detail,
            "Nothing is wrong with it. This is a newer major version, which is a separate "
                + "purchase, discounted for people who already own Pear 3. "
                + "Your Pear 3 install keeps working.")
        XCTAssertEqual(copy.symbol, "arrow.up.circle")
    }

    func testAnOwnerIsNeverQuotedTheNewBuyerPrice() {
        let copy = LockedCopy.of(.licenceForOlderMajor(maxMajor: 3))
        XCTAssertEqual(copy.price, "Existing owners upgrade at a discount.")
        XCTAssertFalse(copy.price.contains("$19"))
    }

    func testTheOlderMajorCopyNamesTheMajorTheLicenceActuallyCovers() {
        XCTAssertEqual(
            LockedCopy.of(.licenceForOlderMajor(maxMajor: 4)).headline,
            "Your license covers Pear 4")
        XCTAssertTrue(
            LockedCopy.of(.licenceForOlderMajor(maxMajor: 4)).detail.contains("Pear 4 install"))
    }

    // MARK: - Shared lines

    func testTheContentPromiseNamesTheTwoToolsThatKeepWorking() {
        // `site/terms.html` §2 promises this in writing, and `Tool.survivesExpiry`
        // is what makes it true; the card has to say it out loud.
        XCTAssertEqual(
            LockedCopy.contentPromise,
            "Scratchpad and Shelf keep working. Your notes and shelf items stay open and exportable.")
    }

    func testTheBuyLinkGoesToThePricingPage() {
        XCTAssertEqual(LockedCopy.pricingURL.absoluteString, "https://pear.phanthawas.dev/pricing")
    }

    func testNoLockedCopyShoutsOrReachesForAPadlock() {
        let reasons: [ExpiryReason] = [
            .trialEnded, .licenceRefunded, .licenceForOlderMajor(maxMajor: 3),
        ]
        for reason in reasons {
            let copy = LockedCopy.of(reason)
            for line in [copy.headline, copy.detail, copy.price] {
                XCTAssertFalse(line.contains("!"), "urgency in: \(line)")
            }
            // Nothing here is a security failure, so nothing here wears a padlock.
            XCTAssertFalse(copy.symbol.contains("lock"), "padlock for \(reason)")
        }
    }

    // MARK: - The trial line

    func testTheLastDayOfTheTrialIsSaidInTheSingular() {
        XCTAssertEqual(LockedCopy.trialStatus(daysRemaining: 1), "Last day of your trial")
        // Defensive: an active trial is never 0 days, but rounding is not ours.
        XCTAssertEqual(LockedCopy.trialStatus(daysRemaining: 0), "Last day of your trial")
    }

    func testTheTrialCountsDownInWholeDays() {
        XCTAssertEqual(LockedCopy.trialStatus(daysRemaining: 3), "3 days left in your trial")
        XCTAssertEqual(LockedCopy.trialStatus(daysRemaining: 14), "14 days left in your trial")
    }

    func testThePanelSaysNothingAboutTheTrialUntilTheLastFewDays() {
        XCTAssertNil(LockedCopy.trialNotice(daysRemaining: 14))
        XCTAssertNil(LockedCopy.trialNotice(daysRemaining: 4))
        XCTAssertEqual(LockedCopy.noticeDays, 3)
        XCTAssertEqual(LockedCopy.trialNotice(daysRemaining: 3), "3 days left in your trial.")
        XCTAssertEqual(LockedCopy.trialNotice(daysRemaining: 1), "Last day of your trial.")
    }

    // MARK: - What the pane says after an attempt

    func testARejectedLicenceComesBackInTheRejectingChecksOwnWords() {
        let rejections: [LicenceCheck] = [
            .badSignature, .malformed, .majorUnsupported(maxMajor: 3, appMajor: 4),
        ]
        for check in rejections {
            XCTAssertEqual(LicenceSettingsView.status(after: check), check.message)
        }
        // Spelled out, so a future reword of the pane cannot quietly replace the
        // check's diagnosis with a generic one.
        XCTAssertEqual(
            LicenceSettingsView.status(after: .badSignature), "This license key isn't valid.")
        XCTAssertEqual(
            LicenceSettingsView.status(after: .malformed),
            "That doesn't look like a Pear license key.")
        XCTAssertEqual(
            LicenceSettingsView.status(after: .majorUnsupported(maxMajor: 3, appMajor: 4)),
            "This license covers Pear 3.x. Pear 4 is a paid upgrade.")
    }

    func testAnAcceptedLicenceSaysWhatHappensNext() {
        let message = LicenceSettingsView.status(after: .valid(LicenceFixture.sample()))
        XCTAssertEqual(message, LicenceSettingsView.activatedMessage)
        XCTAssertEqual(
            message, "License verified. Every tool is back on.")
    }

    // MARK: - End to end through the real store

    func testAGarbagePasteIsRejectedWithoutDisturbingARunningTrial() throws {
        let store = makeStore()
        let check = store.activate("this is not a license")
        XCTAssertEqual(check, .malformed)
        XCTAssertEqual(LicenceSettingsView.status(after: check), check.message)
        XCTAssertEqual(store.entitlement, .trial(daysRemaining: TrialState.trialDays))
    }

    func testAGoodPasteLicensesTheMacAndRemovingItFallsBackToTheTrial() throws {
        let keys = LicenceFixture.keyPair()
        let store = makeStore(publicKey: keys.public)
        let text = try LicenceFixture.licenceString(
            LicenceFixture.sample(email: "buyer@example.com"), signedBy: keys.private)

        let check = store.activate(text)
        guard case .valid = check else { return XCTFail("expected a valid license, got \(check)") }
        XCTAssertEqual(LicenceSettingsView.status(after: check), LicenceSettingsView.activatedMessage)
        // The pane shows this address on purpose: it is the whole enforcement model.
        XCTAssertEqual(store.entitlement, .licensed(email: "buyer@example.com"))

        store.removeLicence()
        XCTAssertEqual(store.entitlement, .trial(daysRemaining: TrialState.trialDays))
    }

    /// A real `EntitlementStore` with every seam pointed somewhere disposable: a
    /// temp licence directory, a private defaults suite, and a trial with no
    /// stores at all (which reads as a fresh 14 days without touching the
    /// Keychain or Application Support).
    private func makeStore(
        publicKey: Curve25519.Signing.PublicKey = Curve25519.Signing.PrivateKey().publicKey
    ) -> EntitlementStore {
        EntitlementStore(
            licenceStore: LicenceFileStore(directory: directory),
            revocationStore: RevocationStore(defaults: defaults),
            trial: TrialState(stores: []),
            verifier: LicenceVerifier(publicKey: publicKey, appMajor: 3)
        )
    }
}
