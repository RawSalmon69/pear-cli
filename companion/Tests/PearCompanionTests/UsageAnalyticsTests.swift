import XCTest

@testable import PearCompanion

@MainActor
final class UsageAnalyticsTests: XCTestCase {
    /// A throwaway domain per test, and the sharing switch left where the test
    /// put it — the switch lives in `.standard`, which every test shares.
    private func makeAnalytics(_ name: String = #function, sharing: Bool = true) -> UsageAnalytics {
        // `#function` carries "()", which is not a usable suite name.
        let suite = "usage-" + name.filter { $0.isLetter || $0.isNumber }
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        UserDefaults.standard.set(sharing, forKey: Prefs.usageSharingKey)
        // No database: uploads are never attempted, and the tally is the part
        // under test.
        return UsageAnalytics(defaults: defaults, database: nil)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Prefs.usageSharingKey)
        super.tearDown()
    }

    func testTileTapsAndHotkeysAreCountedSeparatelyPerTool() {
        let usage = makeAnalytics()
        usage.recordTileTap("screenshot")
        usage.recordTileTap("screenshot")
        usage.recordHotkey("screenshot")
        usage.recordTileTap("disk")
        usage.recordPanelOpen()

        XCTAssertEqual(usage.counts["tile.screenshot"], 2)
        XCTAssertEqual(usage.counts["hotkey.screenshot"], 1)
        XCTAssertEqual(usage.counts["tile.disk"], 1)
        XCTAssertEqual(usage.counts["panel.open"], 1)
    }

    func testTurningSharingOffStopsTheCountingItself() {
        // Not merely withholding a tally that keeps growing in the background:
        // off means nothing is recorded.
        let usage = makeAnalytics(sharing: false)
        usage.recordTileTap("screenshot")
        usage.recordHotkey("disk")
        usage.recordPanelOpen()
        XCTAssertTrue(usage.counts.isEmpty)
    }

    func testCountsSurviveARelaunch() {
        let suite = "usage-persistence"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        UserDefaults.standard.set(true, forKey: Prefs.usageSharingKey)

        let first = UsageAnalytics(defaults: defaults, database: nil)
        first.recordTileTap("qr")
        first.recordTileTap("qr")

        let second = UsageAnalytics(defaults: defaults, database: nil)
        XCTAssertEqual(second.counts["tile.qr"], 2, "the tally is cumulative across launches")
    }

    func testForgetClearsTheTallyAndTheUploadClock() {
        let usage = makeAnalytics()
        usage.recordTileTap("shelf")
        _ = usage.installID
        usage.forget()
        XCTAssertTrue(usage.counts.isEmpty)
        XCTAssertTrue(usage.report.isEmpty)
    }

    func testTheInstallIDIsStableRandomAndNotDerivedFromTheMachine() {
        let usage = makeAnalytics()
        let first = usage.installID
        XCTAssertEqual(usage.installID, first, "stable across reads")
        XCTAssertNotNil(UUID(uuidString: first), "a plain random UUID")
        XCTAssertFalse(first.contains(NSUserName()), "nothing about the person")
        XCTAssertFalse(
            first.contains(ProcessInfo.processInfo.hostName), "nothing about the machine")
    }

    func testTwoInstallsGetDifferentIDs() {
        let a = makeAnalytics("idA")
        let b = makeAnalytics("idB")
        XCTAssertNotEqual(a.installID, b.installID)
    }

    func testTheReportRanksTheMostUsedFirst() {
        let usage = makeAnalytics()
        for _ in 0..<5 { usage.recordTileTap("disk") }
        for _ in 0..<9 { usage.recordTileTap("screenshot") }
        usage.recordTileTap("qr")

        XCTAssertEqual(usage.report.map(\.key), ["tile.screenshot", "tile.disk", "tile.qr"])
        XCTAssertEqual(usage.report.first?.count, 9)
    }

    func testTheReportCarriesOnlyToolKeysAndIntegers() {
        // The payload is a dictionary of counters. Anything that ever looks like
        // content — a path, a URL, free text — is a bug, so assert the shape.
        let usage = makeAnalytics()
        usage.recordTileTap("screenshot")
        usage.recordHotkey("ocr")
        usage.recordPanelOpen()
        for row in usage.report {
            XCTAssertTrue(
                row.key.hasPrefix("tile.") || row.key.hasPrefix("hotkey.") || row.key == "panel.open",
                "unexpected key in the payload: \(row.key)")
            XCTAssertFalse(row.key.contains("/"), "no paths in the payload")
            XCTAssertGreaterThan(row.count, 0)
        }
    }

    func testUploadingIsANoOpWithNoDatabaseAndNeverThrows() async {
        let usage = makeAnalytics()
        usage.recordTileTap("disk")
        await usage.uploadIfDue()
        await usage.uploadIfDue(force: true)
        XCTAssertEqual(usage.counts["tile.disk"], 1, "counters are not consumed by an upload")
    }
}
