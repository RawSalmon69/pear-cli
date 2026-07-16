import XCTest
@testable import PearCompanion

/// Pure-logic coverage for the Monitor tool: byte-rate formatting and the
/// per-core CPU delta math. The samplers themselves touch hardware and are not
/// unit-tested; these are the parts that must be exactly right regardless of
/// the machine.
final class MonitorMetricsTests: XCTestCase {

    // MARK: - Byte-rate formatting

    func testRateFormatting() {
        let cases: [(Double, String)] = [
            (-100, "0 B/s"),
            (0, "0 B/s"),
            (512, "512 B/s"),
            (999, "999 B/s"),
            (1000, "1.0 KB/s"),
            (1500, "1.5 KB/s"),
            (10_000, "10.0 KB/s"),
            (999_000, "999.0 KB/s"),
            (1_000_000, "1.0 MB/s"),
            (2_500_000, "2.5 MB/s"),
            (1_000_000_000, "1.0 GB/s"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(MonitorFormat.rate(input), expected, "rate(\(input))")
        }
    }

    func testPercentClampsAndRounds() {
        XCTAssertEqual(MonitorFormat.percent(-0.5), "0%")
        XCTAssertEqual(MonitorFormat.percent(0), "0%")
        XCTAssertEqual(MonitorFormat.percent(0.284), "28%")
        XCTAssertEqual(MonitorFormat.percent(1.0), "100%")
        XCTAssertEqual(MonitorFormat.percent(1.5), "100%")
    }

    func testDurationFormatting() {
        XCTAssertEqual(MonitorFormat.duration(minutes: 0), "0:00")
        XCTAssertEqual(MonitorFormat.duration(minutes: 5), "0:05")
        XCTAssertEqual(MonitorFormat.duration(minutes: 134), "2:14")
    }

    // MARK: - CPU delta math

    /// Two cores over one interval. Layout per core is [user, system, idle,
    /// nice]; busy = (user + system + nice) deltas, total adds idle.
    func testCoreUsagesTwoCores() {
        // core0: user +50, system +20, idle +180, nice +0 -> 70 / 250 = 0.28
        // core1: user  +0, system  +0, idle +100, nice +0 ->  0 / 100 = 0.0
        let prev: [UInt32] = [100, 50, 800, 0, /* core1 */ 10, 10, 80, 0]
        let curr: [UInt32] = [150, 70, 980, 0, /* core1 */ 10, 10, 180, 0]

        let usages = CPUUsage.coreUsages(previous: prev, current: curr)
        XCTAssertEqual(usages.count, 2)
        XCTAssertEqual(usages[0], 0.28, accuracy: 0.0001)
        XCTAssertEqual(usages[1], 0.0, accuracy: 0.0001)
    }

    /// A fully saturated core (no idle delta) reads as 100%.
    func testCoreUsageFullyBusy() {
        let prev: [UInt32] = [0, 0, 0, 0]
        let curr: [UInt32] = [100, 0, 0, 0]  // all busy, zero idle
        let usages = CPUUsage.coreUsages(previous: prev, current: curr)
        XCTAssertEqual(usages, [1.0])
    }

    /// Counters are 32-bit and wrap; wrapping subtraction must still yield the
    /// true small delta rather than a huge one.
    func testCoreUsageHandlesCounterWrap() {
        // user wraps from max-9 to 10 -> real delta 20; idle +80 -> 20/100.
        let prev: [UInt32] = [UInt32.max - 9, 0, 1000, 0]
        let curr: [UInt32] = [10, 0, 1080, 0]
        let usages = CPUUsage.coreUsages(previous: prev, current: curr)
        XCTAssertEqual(usages.count, 1)
        XCTAssertEqual(usages[0], 0.2, accuracy: 0.0001)
    }

    /// Idle-only interval (machine asleep in the loop) is 0% busy, not NaN.
    func testCoreUsageAllIdle() {
        let prev: [UInt32] = [5, 5, 100, 0]
        let curr: [UInt32] = [5, 5, 300, 0]
        XCTAssertEqual(CPUUsage.coreUsages(previous: prev, current: curr), [0.0])
    }

    /// No ticks elapsed at all -> defined as 0, never a divide-by-zero.
    func testCoreUsageZeroTotal() {
        let same: [UInt32] = [7, 7, 7, 7]
        XCTAssertEqual(CPUUsage.coreUsages(previous: same, current: same), [0.0])
    }

    func testCoreUsagesRejectsMismatchedOrRaggedInput() {
        XCTAssertTrue(CPUUsage.coreUsages(previous: [1, 2, 3, 4], current: [1, 2, 3]).isEmpty)
        XCTAssertTrue(CPUUsage.coreUsages(previous: [1, 2, 3], current: [1, 2, 3]).isEmpty)
        XCTAssertTrue(CPUUsage.coreUsages(previous: [], current: []).isEmpty)
    }

    // MARK: - Refresh-rate mapping

    func testRefreshRateSecondsMapping() {
        XCTAssertEqual(MonitorRefreshRate.oneSecond.seconds, 1)
        XCTAssertEqual(MonitorRefreshRate.twoSeconds.seconds, 2)
        XCTAssertEqual(MonitorRefreshRate.fiveSeconds.seconds, 5)
    }

    func testRefreshRateRawValueRoundTrip() {
        for rate in MonitorRefreshRate.allCases {
            XCTAssertEqual(MonitorRefreshRate(rawValue: rate.rawValue), rate)
        }
        XCTAssertNil(MonitorRefreshRate(rawValue: "3"))
    }

    // MARK: - Prefs round-trip

    func testPrefsDefaultShowsEverythingAt2s() {
        XCTAssertEqual(MonitorPrefs.default.visibleSections, Set(MonitorSection.allCases))
        XCTAssertEqual(MonitorPrefs.default.refreshRate, .twoSeconds)
    }

    func testPrefsLoadFromEmptyDefaultsMatchesDefault() throws {
        let suite = "MonitorMetricsTests-empty"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // No keys written yet: sections default on, rate defaults to 2 s.
        XCTAssertEqual(MonitorPrefs.load(from: defaults), .default)
    }

    func testPrefsRoundTrip() throws {
        let suite = "MonitorMetricsTests-roundtrip"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let prefs = MonitorPrefs(
            visibleSections: [.cpu, .memory],  // network/battery/sensors hidden
            refreshRate: .fiveSeconds)
        prefs.save(to: defaults)

        let loaded = MonitorPrefs.load(from: defaults)
        XCTAssertEqual(loaded, prefs)
        XCTAssertEqual(loaded.visibleSections, [.cpu, .memory])
        XCTAssertFalse(loaded.visibleSections.contains(.network))
        XCTAssertEqual(loaded.refreshRate, .fiveSeconds)
    }

    func testPrefsLoadRejectsUnknownRefreshRate() throws {
        let suite = "MonitorMetricsTests-badrate"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("42", forKey: "monitor.refreshRate")
        XCTAssertEqual(MonitorPrefs.load(from: defaults).refreshRate, .twoSeconds)
    }

    // MARK: - Section filtering (hidden section ⇒ not sampled)

    /// An empty visible set does no hardware work at all — every branch is
    /// gated off — so the snapshot comes back empty.
    func testEmptySectionSetSamplesNothing() async {
        let sampler = MonitorSampler()
        let snap = await sampler.sample(sections: [])
        XCTAssertTrue(snap.isEmpty)
    }

    /// Sections left out of the set are never handed to their sampler, so they
    /// stay nil regardless of hardware; memory is absolute and present on every
    /// Mac, proving the requested section still runs.
    func testHiddenSectionsAreNeverPopulated() async {
        let sampler = MonitorSampler()
        _ = await sampler.sample(sections: [.memory])  // seed
        let snap = await sampler.sample(sections: [.memory])
        XCTAssertNil(snap.cpu)
        XCTAssertNil(snap.network)
        XCTAssertNil(snap.battery)
        XCTAssertNil(snap.sensors)
        XCTAssertNotNil(snap.memory)
    }
}
