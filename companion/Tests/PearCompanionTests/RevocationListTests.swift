import CryptoKit
import XCTest

@testable import PearCompanion

/// Counts fetches without touching the network, so "never fetched" is provable.
private actor FetchSpy {
    private(set) var calls = 0
    private let result: Result<Data, Error>

    init(_ result: Result<Data, Error>) {
        self.result = result
    }

    func fetch() throws -> Data {
        calls += 1
        return try result.get()
    }
}

private struct DeadDomain: Error {}

final class RevocationListTests: XCTestCase {
    private let hashA = Licence.hash(orderID: "ord_refunded")
    private let hashB = Licence.hash(orderID: "ord_kept")

    // MARK: - Fail-open (rule 1). One test per failure mode.

    func testUnreachableNetworkIsIgnored() async {
        let keys = LicenceFixture.keyPair()
        let spy = FetchSpy(.failure(DeadDomain()))
        let (checker, store, suite) = makeChecker(publicKey: keys.public) { try await spy.fetch() }
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let decision = await checker.check(licenceHash: hashA)
        XCTAssertEqual(decision, .ignore(.unreachable))
        XCTAssertFalse(store.isRevoked)
        XCTAssertEqual(store.knownSerial, 0)
        XCTAssertNotNil(store.lastChecked, "a failed fetch still counts, or it retries forever")
    }

    /// A 404 (or any non-200) reaches the same place: `liveFetch` throws, and a
    /// throw is `.unreachable`.
    func testNotFoundIsIgnored() async {
        let keys = LicenceFixture.keyPair()
        let spy = FetchSpy(.failure(RevocationFetchError.notAvailable))
        let (checker, store, suite) = makeChecker(publicKey: keys.public) { try await spy.fetch() }
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let decision = await checker.check(licenceHash: hashA)
        XCTAssertEqual(decision, .ignore(.unreachable))
        XCTAssertFalse(store.isRevoked)
    }

    func testBadJSONIsIgnored() {
        let keys = LicenceFixture.keyPair()
        for body in ["", "not json", "{}", "[]", "{\"serial\":1}"] {
            let load = RevocationList.parse(Data(body.utf8), publicKey: keys.public)
            XCTAssertEqual(
                RevocationList.decision(list: load, licenceHash: hashA, knownSerial: 0),
                .ignore(.malformedJSON),
                "expected \(body.isEmpty ? "<empty>" : body) to be ignored"
            )
        }
    }

    func testSignatureThatIsNotSixtyFourBytesIsIgnored() {
        let keys = LicenceFixture.keyPair()
        let data = LicenceFixture.json(
            serial: 1,
            issued: "2026-08-01T00:00:00Z",
            revoked: [hashA],
            signature: Data(repeating: 7, count: 10).base64EncodedString()
        )
        let load = RevocationList.parse(data, publicKey: keys.public)
        XCTAssertEqual(
            RevocationList.decision(list: load, licenceHash: hashA, knownSerial: 0),
            .ignore(.malformedJSON)
        )
    }

    func testListSignedByAnotherKeyIsIgnored() throws {
        let owner = LicenceFixture.keyPair()
        let forger = LicenceFixture.keyPair()
        let data = try LicenceFixture.revocationJSON(
            serial: 9,
            revoked: [hashA],
            signedBy: forger.private
        )

        let load = RevocationList.parse(data, publicKey: owner.public)
        XCTAssertEqual(
            RevocationList.decision(list: load, licenceHash: hashA, knownSerial: 0),
            .ignore(.badSignature)
        )
    }

    /// Domain separation, revocation side: the owner's own key, the right bytes,
    /// the wrong label. A licence signature can never be replayed as authority
    /// over the revocation list.
    func testListSignedUnderTheLicenceDomainIsIgnored() throws {
        let keys = LicenceFixture.keyPair()
        let data = try LicenceFixture.revocationJSON(
            serial: 9,
            revoked: [hashA],
            signedBy: keys.private,
            domain: .licence
        )

        let load = RevocationList.parse(data, publicKey: keys.public)
        XCTAssertEqual(
            RevocationList.decision(list: load, licenceHash: hashA, knownSerial: 0),
            .ignore(.badSignature)
        )
    }

    /// And the reverse: a licence blob handed to the revocation parser.
    func testALicenceIsNotARevocationList() throws {
        let keys = LicenceFixture.keyPair()
        let licence = try LicenceFixture.licenceString(LicenceFixture.sample(), signedBy: keys.private)
        let load = RevocationList.parse(Data(licence.utf8), publicKey: keys.public)
        XCTAssertEqual(
            RevocationList.decision(list: load, licenceHash: hashA, knownSerial: 0),
            .ignore(.malformedJSON)
        )
    }

    func testUnparseableIssuedDateIsIgnored() throws {
        let keys = LicenceFixture.keyPair()
        let data = try LicenceFixture.revocationJSON(
            serial: 9,
            issued: "last Tuesday",
            revoked: [hashA],
            signedBy: keys.private
        )

        let load = RevocationList.parse(data, publicKey: keys.public)
        XCTAssertEqual(
            RevocationList.decision(list: load, licenceHash: hashA, knownSerial: 0),
            .ignore(.unparseableDate)
        )
    }

    func testNoIgnoreReasonEverChangesEntitlement() {
        let reasons: [RevocationIgnoreReason] = [
            .unreachable, .malformedJSON, .badSignature, .unparseableDate, .staleSerial(2),
        ]
        for reason in reasons {
            let suite = "RevocationStore-ignore-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = RevocationStore(defaults: defaults)

            // An unrevoked Mac is never revoked by a failure…
            store.apply(.ignore(reason), from: .failure(reason), now: Date())
            XCTAssertFalse(store.isRevoked, "\(reason) must not revoke anything")
            XCTAssertEqual(store.knownSerial, 0, "\(reason) must not move the serial")
            XCTAssertNotNil(store.lastChecked, "\(reason) still counts as a check")

            // …and an already-revoked one is not reinstated by one either.
            defaults.set(true, forKey: RevocationStore.revokedKey)
            store.apply(.ignore(reason), from: .failure(reason), now: Date())
            XCTAssertTrue(store.isRevoked, "\(reason) must not un-revoke")
        }
    }

    // MARK: - The decision

    func testHashInANewerListRevokes() throws {
        let keys = LicenceFixture.keyPair()
        let data = try LicenceFixture.revocationJSON(
            serial: 3,
            revoked: [hashB, hashA],
            signedBy: keys.private
        )
        let load = RevocationList.parse(data, publicKey: keys.public)
        XCTAssertEqual(RevocationList.decision(list: load, licenceHash: hashA, knownSerial: 2), .revoked)
    }

    func testHashAbsentFromANewerListChangesNothing() throws {
        let keys = LicenceFixture.keyPair()
        let data = try LicenceFixture.revocationJSON(serial: 3, revoked: [hashB], signedBy: keys.private)
        let load = RevocationList.parse(data, publicKey: keys.public)
        XCTAssertEqual(RevocationList.decision(list: load, licenceHash: hashA, knownSerial: 2), .unchanged)
    }

    func testEmptySignedListChangesNothing() throws {
        let keys = LicenceFixture.keyPair()
        let data = try LicenceFixture.revocationJSON(serial: 1, revoked: [], signedBy: keys.private)
        let load = RevocationList.parse(data, publicKey: keys.public)
        XCTAssertEqual(RevocationList.decision(list: load, licenceHash: hashA, knownSerial: 0), .unchanged)
    }

    func testHashComparisonIgnoresCase() throws {
        let keys = LicenceFixture.keyPair()
        let data = try LicenceFixture.revocationJSON(
            serial: 1,
            revoked: [hashA.uppercased()],
            signedBy: keys.private
        )
        let load = RevocationList.parse(data, publicKey: keys.public)
        XCTAssertEqual(RevocationList.decision(list: load, licenceHash: hashA, knownSerial: 0), .revoked)
    }

    func testAnEmptyLicenceHashNeverMatches() throws {
        let keys = LicenceFixture.keyPair()
        let data = try LicenceFixture.revocationJSON(serial: 1, revoked: [""], signedBy: keys.private)
        let load = RevocationList.parse(data, publicKey: keys.public)
        XCTAssertEqual(RevocationList.decision(list: load, licenceHash: "", knownSerial: 0), .unchanged)
    }

    // MARK: - Monotonic (rule 5)

    func testEqualOrOlderSerialIsIgnoredEvenWhenItRevokes() throws {
        let keys = LicenceFixture.keyPair()
        for serial in [1, 4, 5] {
            let data = try LicenceFixture.revocationJSON(
                serial: serial,
                revoked: [hashA],
                signedBy: keys.private
            )
            let load = RevocationList.parse(data, publicKey: keys.public)
            XCTAssertEqual(
                RevocationList.decision(list: load, licenceHash: hashA, knownSerial: 5),
                .ignore(.staleSerial(serial)),
                "serial \(serial) is not newer than 5"
            )
        }
    }

    func testAReplayedOlderListCannotUnrevoke() throws {
        let keys = LicenceFixture.keyPair()
        let suite = "RevocationStore-replay-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RevocationStore(defaults: defaults)

        let revoking = RevocationList.parse(
            try LicenceFixture.revocationJSON(serial: 4, revoked: [hashA], signedBy: keys.private),
            publicKey: keys.public
        )
        store.apply(
            RevocationList.decision(list: revoking, licenceHash: hashA, knownSerial: store.knownSerial),
            from: revoking,
            now: Date()
        )
        XCTAssertTrue(store.isRevoked)
        XCTAssertEqual(store.knownSerial, 4)

        // An attacker (or a stale CDN) serves serial 2 with an empty list.
        let older = RevocationList.parse(
            try LicenceFixture.revocationJSON(serial: 2, revoked: [], signedBy: keys.private),
            publicKey: keys.public
        )
        let decision = RevocationList.decision(
            list: older,
            licenceHash: hashA,
            knownSerial: store.knownSerial
        )
        XCTAssertEqual(decision, .ignore(.staleSerial(2)))
        store.apply(decision, from: older, now: Date())

        XCTAssertTrue(store.isRevoked, "an older list must never un-revoke")
        XCTAssertEqual(store.knownSerial, 4, "the serial must never go backwards")
    }

    // MARK: - Sticky (rule 5)

    func testANewerListThatDropsTheHashDoesNotUnrevoke() throws {
        let keys = LicenceFixture.keyPair()
        let suite = "RevocationStore-sticky-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RevocationStore(defaults: defaults)

        let revoking = RevocationList.parse(
            try LicenceFixture.revocationJSON(serial: 4, revoked: [hashA], signedBy: keys.private),
            publicKey: keys.public
        )
        store.apply(.revoked, from: revoking, now: Date())
        XCTAssertTrue(store.isRevoked)

        let later = RevocationList.parse(
            try LicenceFixture.revocationJSON(serial: 5, revoked: [hashB], signedBy: keys.private),
            publicKey: keys.public
        )
        let decision = RevocationList.decision(list: later, licenceHash: hashA, knownSerial: 4)
        XCTAssertEqual(decision, .unchanged)
        store.apply(decision, from: later, now: Date())

        XCTAssertTrue(store.isRevoked, "revocation is sticky; there is no un-revoke path")
        XCTAssertEqual(store.knownSerial, 5)
    }

    // MARK: - Cadence

    func testNeverCheckedIsDue() {
        XCTAssertTrue(RevocationCadence.isDue(lastChecked: nil, now: Date(), jitter: 0))
    }

    func testJustCheckedIsNotDue() {
        let now = Date()
        XCTAssertFalse(RevocationCadence.isDue(lastChecked: now, now: now, jitter: 0))
        XCTAssertFalse(
            RevocationCadence.isDue(lastChecked: now.addingTimeInterval(-3600), now: now, jitter: 0))
    }

    func testSevenDaysIsTheFloorAndJitterPushesItOut() {
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60

        XCTAssertFalse(
            RevocationCadence.isDue(lastChecked: now.addingTimeInterval(-6 * day), now: now, jitter: 0))
        XCTAssertTrue(
            RevocationCadence.isDue(lastChecked: now.addingTimeInterval(-7 * day), now: now, jitter: 0))
        // 7 days elapsed but this install drew a full day of jitter.
        XCTAssertFalse(
            RevocationCadence.isDue(
                lastChecked: now.addingTimeInterval(-7 * day), now: now, jitter: day))
        XCTAssertTrue(
            RevocationCadence.isDue(
                lastChecked: now.addingTimeInterval(-8 * day), now: now, jitter: day))
    }

    func testJitterIsClampedToTheDocumentedWindow() {
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60
        let sevenDaysAgo = now.addingTimeInterval(-7 * day)

        // Negative jitter cannot pull the check earlier than the interval…
        XCTAssertTrue(RevocationCadence.isDue(lastChecked: sevenDaysAgo, now: now, jitter: -day))
        // …and a nonsense jitter cannot push it past 7 days + 24h.
        XCTAssertTrue(
            RevocationCadence.isDue(
                lastChecked: now.addingTimeInterval(-8 * day), now: now, jitter: 999 * day))
        XCTAssertEqual(RevocationCadence.interval, 7 * day)
        XCTAssertEqual(RevocationCadence.maxJitter, day)
    }

    func testClockMovedBackwardsIsDue() {
        let now = Date()
        XCTAssertTrue(
            RevocationCadence.isDue(lastChecked: now.addingTimeInterval(3600), now: now, jitter: 0))
    }

    func testRandomJitterStaysInWindow() {
        for _ in 0..<50 {
            let jitter = RevocationCadence.randomJitter()
            XCTAssertGreaterThanOrEqual(jitter, 0)
            XCTAssertLessThanOrEqual(jitter, RevocationCadence.maxJitter)
        }
    }

    func testCheckIfDueDoesNotFetchBeforeItIsTime() async throws {
        let keys = LicenceFixture.keyPair()
        let data = try LicenceFixture.revocationJSON(serial: 2, revoked: [hashA], signedBy: keys.private)
        let spy = FetchSpy(.success(data))
        let (checker, store, suite) = makeChecker(publicKey: keys.public) { try await spy.fetch() }
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        // First call: never checked, so it is due.
        let first = await checker.checkIfDue(licenceHash: hashA)
        XCTAssertEqual(first, .revoked)
        let afterFirst = await spy.calls
        XCTAssertEqual(afterFirst, 1)

        // Second call, same day: not due, and nothing is fetched.
        let second = await checker.checkIfDue(licenceHash: hashA)
        XCTAssertNil(second)
        let afterSecond = await spy.calls
        XCTAssertEqual(afterSecond, 1)
        XCTAssertTrue(store.isRevoked)
    }

    func testCheckIfDueRunsOnceTheIntervalHasElapsed() async throws {
        let keys = LicenceFixture.keyPair()
        let data = try LicenceFixture.revocationJSON(serial: 2, revoked: [], signedBy: keys.private)
        let spy = FetchSpy(.success(data))
        let (checker, _, suite) = makeChecker(publicKey: keys.public) { try await spy.fetch() }
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let start = Date()
        let first = await checker.checkIfDue(licenceHash: hashA, now: start)
        XCTAssertEqual(first, .unchanged)

        // 8 days later beats the 7-day interval plus any jitter the store rolled,
        // so it fetches again. The file has not moved on, so the same serial is
        // now stale — a weekly re-read of an unchanged list is a no-op.
        let later = start.addingTimeInterval(8 * 24 * 60 * 60)
        let second = await checker.checkIfDue(licenceHash: hashA, now: later)
        XCTAssertEqual(second, .ignore(.staleSerial(2)))
        let calls = await spy.calls
        XCTAssertEqual(calls, 2)
    }

    // MARK: - Wording and the anonymous URL

    func testRevokedMessageNamesTheRefund() {
        XCTAssertEqual(RevocationList.refundedMessage, "This license was refunded")
    }

    func testTheFetchURLCarriesNoIdentifier() {
        let url = RevocationList.url
        XCTAssertEqual(url.absoluteString, "https://pear.phanthawas.dev/revoked.json")
        XCTAssertNil(url.query)
        XCTAssertNil(url.user)
        XCTAssertNil(url.fragment)
    }

    // MARK: -

    private func makeChecker(
        publicKey: Curve25519.Signing.PublicKey,
        fetch: @escaping RevocationChecker.Fetcher
    ) -> (RevocationChecker, RevocationStore, String) {
        let suite = "RevocationChecker-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = RevocationStore(defaults: defaults)
        return (RevocationChecker(publicKey: publicKey, store: store, fetch: fetch), store, suite)
    }
}
