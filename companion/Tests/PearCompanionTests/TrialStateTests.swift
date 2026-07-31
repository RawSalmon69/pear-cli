import XCTest
@testable import PearCompanion

/// An in-memory trial store. `@unchecked Sendable`: `record` is only ever
/// touched from the test's own thread, so no test reaches the real Keychain or
/// the real Application Support path.
private final class MemoryTrialStore: TrialStore, @unchecked Sendable {
    var record: TrialRecord?
    var writes = 0

    init(_ record: TrialRecord? = nil) {
        self.record = record
    }

    func read() -> TrialRecord? { record }

    func write(_ record: TrialRecord) {
        self.record = record
        writes += 1
    }
}

/// A store that cannot be reached at all: reads come back empty, writes vanish.
/// Stands in for the Keychain on an unsigned build.
private final class UnreachableTrialStore: TrialStore, @unchecked Sendable {
    var writeAttempts = 0

    func read() -> TrialRecord? { nil }

    func write(_ record: TrialRecord) { writeAttempts += 1 }
}

/// File-scope so the injected clocks stay `@Sendable` closures over plain
/// values instead of capturing the test case.
private let day = TrialState.day
private let installed = Date(timeIntervalSinceReferenceDate: 0)

final class TrialStateTests: XCTestCase {
    // MARK: - Length and remaining days

    func testTrialIsFourteenDaysLong() {
        XCTAssertEqual(TrialState.trialDays, 14)
        XCTAssertEqual(TrialState.length, 14 * day)
    }

    func testFreshInstallStartsATrialAndSeedsBothStores() {
        let keychain = MemoryTrialStore()
        let file = MemoryTrialStore()
        let state = TrialState(stores: [keychain, file], now: { installed })

        XCTAssertEqual(state.status(), .active(daysRemaining: 14))
        XCTAssertEqual(keychain.record, TrialRecord(startedAt: installed, newestSeen: installed))
        XCTAssertEqual(file.record, keychain.record, "a fresh trial is written to every store")
    }

    func testDayThirteenIsActiveWithOneDayRemaining() {
        XCTAssertEqual(
            status(startedAt: installed, newestSeen: installed, now: installed + 13 * day),
            .active(daysRemaining: 1))
    }

    func testTheLastPartialDayStillReadsAsOneDayRemaining() {
        XCTAssertEqual(
            status(startedAt: installed, newestSeen: installed, now: installed + 13.5 * day),
            .active(daysRemaining: 1))
    }

    func testDayFourteenIsExpired() {
        XCTAssertEqual(
            status(startedAt: installed, newestSeen: installed, now: installed + 14 * day),
            .expired)
    }

    func testWellBeyondDayFourteenIsExpiredAndNeverReportsNegativeDays() {
        for elapsed in [14.0, 15.0, 90.0, 4000.0] {
            XCTAssertEqual(
                status(startedAt: installed, newestSeen: installed, now: installed + elapsed * day),
                .expired,
                "\(elapsed) days in must be expired, never active with negative days")
        }
    }

    func testDaysRemainingNeverExceedsTheTrialLength() {
        // A store holding a start date in the future (the clock was ahead at
        // install, then corrected) must not report 15 days remaining.
        let future = installed + 2 * day
        XCTAssertEqual(
            status(startedAt: future, newestSeen: installed, now: installed),
            .active(daysRemaining: 14))
    }

    // MARK: - Two stores: the START DATE takes the EARLIEST value

    func testEarliestStartDateWinsWhenTheKeychainIsOlderThanTheFile() {
        let keychain = MemoryTrialStore(record(startedAt: installed))
        let file = MemoryTrialStore(record(startedAt: installed + 13 * day))
        let now = installed + 13 * day
        let state = TrialState(stores: [keychain, file], now: { now })

        XCTAssertEqual(
            state.status(), .active(daysRemaining: 1),
            "the older Keychain start date wins, so 13 days are already gone")
        XCTAssertEqual(
            file.record?.startedAt, installed,
            "the later store is corrected back to the earliest start date")
    }

    func testEarliestStartDateWinsWhenTheFileIsOlderThanTheKeychain() {
        let keychain = MemoryTrialStore(record(startedAt: installed + 13 * day))
        let file = MemoryTrialStore(record(startedAt: installed))
        let now = installed + 13 * day
        let state = TrialState(stores: [keychain, file], now: { now })

        XCTAssertEqual(state.status(), .active(daysRemaining: 1))
        XCTAssertEqual(keychain.record?.startedAt, installed)
    }

    func testAFreshStoreDoesNotRestartATrialTheOtherStoreAlreadyKnowsAbout() {
        // The shape a reinstall takes: one store still holds the original
        // start, the other is brand new and would happily start over.
        let keychain = MemoryTrialStore(record(startedAt: installed))
        let file = MemoryTrialStore()
        let now = installed + 20 * day
        let state = TrialState(stores: [keychain, file], now: { now })

        XCTAssertEqual(state.status(), .expired, "a wiped store cannot buy a second trial")
    }

    func testWipedFileIsRepopulatedFromTheKeychain() {
        let started = installed
        let keychain = MemoryTrialStore(record(startedAt: started))
        let file = MemoryTrialStore()
        let now = started + 2 * day
        let state = TrialState(stores: [keychain, file], now: { now })

        XCTAssertEqual(state.status(), .active(daysRemaining: 12))
        XCTAssertEqual(file.record?.startedAt, started, "the missing store is written back")
    }

    func testWipedKeychainIsRepopulatedFromTheFile() {
        let started = installed
        let keychain = MemoryTrialStore()
        let file = MemoryTrialStore(record(startedAt: started))
        let now = started + 2 * day
        let state = TrialState(stores: [keychain, file], now: { now })

        XCTAssertEqual(state.status(), .active(daysRemaining: 12))
        XCTAssertEqual(keychain.record?.startedAt, started)
    }

    func testBothStoresWipedStartsAFreshTrial() {
        // The known limit of having no activation server: with the Keychain
        // item deleted AND the Application Support file deleted, nothing on the
        // machine remembers the trial, so it begins again. Stated plainly
        // because it is a deliberate accepted cost, not an oversight.
        let keychain = MemoryTrialStore()
        let file = MemoryTrialStore()
        let now = installed + 400 * day
        let state = TrialState(stores: [keychain, file], now: { now })

        XCTAssertEqual(state.status(), .active(daysRemaining: 14))
        XCTAssertEqual(keychain.record?.startedAt, now)
    }

    func testAStoreThatIsAlreadyCorrectIsNotRewritten() {
        let now = installed + day
        let agreed = TrialRecord(startedAt: installed, newestSeen: now)
        let keychain = MemoryTrialStore(agreed)
        let file = MemoryTrialStore(agreed)
        let state = TrialState(stores: [keychain, file], now: { now })

        _ = state.status()
        XCTAssertEqual(keychain.writes, 0)
        XCTAssertEqual(file.writes, 0)
    }

    // MARK: - Two stores: the WATERMARK takes the LATEST value

    func testWatermarkTakesTheLatestValueAcrossTheStores() {
        let keychain = MemoryTrialStore(record(startedAt: installed, newestSeen: installed + 5 * day))
        let file = MemoryTrialStore(record(startedAt: installed, newestSeen: installed + day))
        let state = TrialState(stores: [keychain, file], now: { installed + 2 * day })

        // Latest watermark (day 5) wins over the file's day 1, and `now` (day 2)
        // sits behind it by more than the tolerance: the clock went back.
        XCTAssertEqual(state.status(), .expired)
        XCTAssertEqual(file.record?.newestSeen, installed + 5 * day)
    }

    func testWatermarkAdvancesToNowInEveryStore() {
        let keychain = MemoryTrialStore(record(startedAt: installed, newestSeen: installed))
        let file = MemoryTrialStore(record(startedAt: installed, newestSeen: installed))
        let now = installed + 3 * day
        let state = TrialState(stores: [keychain, file], now: { now })

        XCTAssertEqual(state.status(), .active(daysRemaining: 11))
        XCTAssertEqual(keychain.record?.newestSeen, now)
        XCTAssertEqual(file.record?.newestSeen, now)
    }

    func testWatermarkIsNeverMovedBackwards() {
        let seen = installed + 10 * day
        let keychain = MemoryTrialStore(record(startedAt: installed, newestSeen: seen))
        let file = MemoryTrialStore(record(startedAt: installed, newestSeen: seen))
        let state = TrialState(stores: [keychain, file], now: { installed + day })

        _ = state.status()
        XCTAssertEqual(keychain.record?.newestSeen, seen, "a rolled-back clock never lowers the watermark")
        XCTAssertEqual(file.record?.newestSeen, seen)
    }

    // MARK: - Clock tampering

    func testClockRolledBackBehindTheWatermarkExpiresTheTrial() {
        // Day 10 has been seen; the user winds the clock back to day 2 to buy
        // eight more days. It buys nothing.
        XCTAssertEqual(
            status(startedAt: installed, newestSeen: installed + 10 * day, now: installed + 2 * day),
            .expired)
    }

    func testClockRolledBackBeforeTheStartDateExpiresTheTrial() {
        XCTAssertEqual(
            status(startedAt: installed, newestSeen: installed + 5 * day, now: installed - 100 * day),
            .expired)
    }

    func testClockRolledForwardPastTheTrialThenBackToRealTimeStaysExpired() {
        // Jumping to day 30 burns the trial and lifts the watermark to day 30.
        let jumped = installed + 30 * day
        XCTAssertEqual(status(startedAt: installed, newestSeen: jumped, now: jumped), .expired)
        // Coming back to the real day 3 does not resurrect it.
        XCTAssertEqual(
            status(startedAt: installed, newestSeen: jumped, now: installed + 3 * day), .expired)
    }

    func testClockRolledForwardInsideTheTrialThenBackToRealTimeIsSaneEndToEnd() {
        // Real time is day 3. The clock jumps to day 6, then returns to day 3.
        let keychain = MemoryTrialStore(record(startedAt: installed))
        let file = MemoryTrialStore(record(startedAt: installed))

        let jumped = installed + 6 * day
        XCTAssertEqual(
            TrialState(stores: [keychain, file], now: { jumped }).status(),
            .active(daysRemaining: 8), "a forward jump inside the trial just spends days faster")

        let realNow = installed + 3 * day
        XCTAssertEqual(
            TrialState(stores: [keychain, file], now: { realNow }).status(), .expired,
            "returning behind the day-6 watermark reads as tampering")
        XCTAssertEqual(keychain.record?.newestSeen, jumped)
    }

    func testSmallBackwardClockDriftDoesNotExpireTheTrial() {
        // An NTP correction or a drifting RTC is not tampering. The tolerance
        // is capped in total, because the watermark only ever moves up.
        let seen = installed + 5 * day
        // 59 minutes before the day-5 watermark leaves 9 days and change, which
        // ceils to 10.
        XCTAssertEqual(
            status(startedAt: installed, newestSeen: seen, now: seen - 59 * 60),
            .active(daysRemaining: 10))
        XCTAssertEqual(
            status(startedAt: installed, newestSeen: seen, now: seen - 61 * 60),
            .expired, "beyond the tolerance it is a rolled-back clock")
    }

    // MARK: - Failing toward the user, not the paywall

    func testAnUnreachableKeychainDegradesToTheFileStore() {
        let keychain = UnreachableTrialStore()
        let file = MemoryTrialStore(record(startedAt: installed))
        let now = installed + 4 * day
        let state = TrialState(stores: [keychain, file], now: { now })

        XCTAssertEqual(
            state.status(), .active(daysRemaining: 10),
            "a Keychain the app cannot reach is no evidence, never evidence of expiry")
        XCTAssertEqual(keychain.writeAttempts, 1, "the write is still attempted, and its failure ignored")
        XCTAssertEqual(file.record?.newestSeen, now, "the file store carries the trial on its own")
    }

    func testACorruptFileDoesNotExpireTheTrial() throws {
        // A real FileTrialStore over a temp path (never the app's real
        // Application Support folder) so the decode path is the one under test.
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json {[".utf8).write(to: url)

        let file = FileTrialStore(url: url)
        XCTAssertNil(file.read(), "garbage decodes to nothing, not to a date")

        let keychain = MemoryTrialStore(record(startedAt: installed))
        let now = installed + 4 * day
        XCTAssertEqual(
            TrialState(stores: [keychain, file], now: { now }).status(),
            .active(daysRemaining: 10))
        XCTAssertEqual(
            file.read()?.startedAt, installed, "the corrupt file is replaced by the reconciled record")
    }

    func testACorruptFileOnItsOwnStartsAFreshTrialRatherThanExpiring() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x00, 0x01, 0x02]).write(to: url)

        let now = installed + 100 * day
        XCTAssertEqual(
            TrialState(stores: [FileTrialStore(url: url)], now: { now }).status(),
            .active(daysRemaining: 14))
    }

    func testAnAbsurdButDecodableDateNeitherCrashesNorExpires() throws {
        // Valid JSON, finite doubles, nonsense values. The days-remaining
        // conversion has to clamp before it reaches Int or it traps.
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"startedAt":1e300,"newestSeen":-1e300}"#.utf8).write(to: url)

        XCTAssertEqual(
            TrialState(stores: [FileTrialStore(url: url)], now: { installed }).status(),
            .active(daysRemaining: 14))
    }

    func testAMissingFileStoreDirectoryIsCreatedOnWrite() {
        let url = tempURL()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))

        let file = FileTrialStore(url: url)
        file.write(record(startedAt: installed))
        XCTAssertEqual(file.read()?.startedAt, installed)
    }

    func testFileStoreRoundTripsBothDatesExactly() {
        let url = tempURL()
        let stored = TrialRecord(startedAt: installed, newestSeen: installed + 1234.5678)
        let file = FileTrialStore(url: url)
        file.write(stored)

        XCTAssertEqual(file.read(), stored, "the watermark must survive a round trip to the byte")
    }

    func testEveryStoreEmptyAndUnwritableStillLeavesTheUserWithAWorkingTrial() {
        let state = TrialState(
            stores: [UnreachableTrialStore(), UnreachableTrialStore()],
            now: { installed })
        XCTAssertEqual(state.status(), .active(daysRemaining: 14))
    }

    // MARK: - Helpers

    private func status(startedAt: Date, newestSeen: Date, now: Date) -> TrialStatus {
        TrialState.status(for: TrialRecord(startedAt: startedAt, newestSeen: newestSeen), now: now)
    }

    private func record(startedAt: Date, newestSeen: Date? = nil) -> TrialRecord {
        TrialRecord(startedAt: startedAt, newestSeen: newestSeen ?? startedAt)
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TrialStateTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("trial.json")
    }
}
