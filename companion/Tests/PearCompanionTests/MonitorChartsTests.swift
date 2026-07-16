import XCTest
@testable import PearCompanion

/// Pure-logic coverage for the Monitor history charts: the fixed-capacity ring
/// buffer, the one bit of chart math worth isolating (`ChartGeometry.normalized`),
/// and the model-level history gating (a hidden section stops recording and its
/// buffer is cleared on hide). The `Canvas` drawing itself is not unit-tested;
/// these are the parts that must be exactly right regardless of the view.
final class MonitorChartsTests: XCTestCase {

    // MARK: - Ring buffer

    func testAppendBelowCapacityKeepsInsertionOrder() {
        var buffer = HistoryBuffer<Int>(capacity: 5)
        XCTAssertTrue(buffer.isEmpty)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)
        XCTAssertEqual(buffer.count, 3)
        XCTAssertFalse(buffer.isEmpty)
        XCTAssertEqual(buffer.values, [1, 2, 3])
    }

    func testAppendAtCapacityStaysFull() {
        var buffer = HistoryBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.values, [1, 2, 3])
    }

    func testWrapEvictsOldestOldestFirst() {
        var buffer = HistoryBuffer<Int>(capacity: 3)
        for v in 1...5 { buffer.append(v) }
        // Oldest two (1, 2) evicted; values stay chronological.
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.values, [3, 4, 5])
    }

    func testWrapPastMultipleLaps() {
        var buffer = HistoryBuffer<Int>(capacity: 4)
        for v in 1...10 { buffer.append(v) }
        XCTAssertEqual(buffer.count, 4)
        XCTAssertEqual(buffer.values, [7, 8, 9, 10])
    }

    func testCapacityFloorOfOne() {
        var buffer = HistoryBuffer<Int>(capacity: 0)
        XCTAssertEqual(buffer.capacity, 1)
        buffer.append(1)
        buffer.append(2)
        XCTAssertEqual(buffer.count, 1)
        XCTAssertEqual(buffer.values, [2])
    }

    func testClearResetsToEmpty() {
        var buffer = HistoryBuffer<Int>(capacity: 3)
        for v in 1...5 { buffer.append(v) }
        buffer.clear()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.values, [])
        // Reusable after clearing, and starts fresh at the beginning.
        buffer.append(42)
        XCTAssertEqual(buffer.values, [42])
    }

    // MARK: - Chart geometry

    func testNormalizedRejectsFewerThanTwo() {
        XCTAssertEqual(ChartGeometry.normalized([], maxValue: 1), [])
        XCTAssertEqual(ChartGeometry.normalized([0.5], maxValue: 1), [])
    }

    func testNormalizedScalesAndClamps() {
        let out = ChartGeometry.normalized([0, 0.5, 1, 2, -1], maxValue: 1)
        XCTAssertEqual(out, [0, 0.5, 1, 1, 0])
    }

    func testNormalizedScalesToMaxValue() {
        let out = ChartGeometry.normalized([0, 50, 100, 200], maxValue: 100)
        XCTAssertEqual(out, [0, 0.5, 1, 1])
    }

    func testNormalizedNonPositiveMaxTreatedAsOne() {
        // Divisor floors at 1 rather than dividing by zero/negative.
        XCTAssertEqual(ChartGeometry.normalized([0, 0.5, 1], maxValue: 0), [0, 0.5, 1])
        XCTAssertEqual(ChartGeometry.normalized([0, 0.5, 1], maxValue: -5), [0, 0.5, 1])
    }

    // MARK: - Model history gating

    private static func sampleSnapshot() -> MonitorSnapshot {
        MonitorSnapshot(
            cpu: CPUSample(cores: [], total: 0.5),
            memory: MemorySample(total: 100, used: 40, wired: 0, compressed: 0, free: 60),
            network: NetworkSample(downBytesPerSec: 1000, upBytesPerSec: 500, interfaceName: nil))
    }

    @MainActor
    func testRecordHistoryAppendsForVisibleSections() throws {
        let suite = "MonitorChartsTests-record"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = MonitorModel(defaults: defaults)  // default prefs: everything visible
        model.recordHistory(Self.sampleSnapshot())

        XCTAssertEqual(model.cpuHistory.values, [0.5])
        XCTAssertEqual(model.memoryHistory.count, 1)
        XCTAssertEqual(model.memoryHistory.values.first ?? .nan, 0.4, accuracy: 0.0001)
        XCTAssertEqual(model.netDownHistory.values, [1000])
        XCTAssertEqual(model.netUpHistory.values, [500])
    }

    @MainActor
    func testHiddenSectionIsNotRecorded() throws {
        let suite = "MonitorChartsTests-gate"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = MonitorModel(defaults: defaults)
        model.prefs.visibleSections.remove(.network)  // hide before recording

        model.recordHistory(Self.sampleSnapshot())  // snapshot still carries a network sample

        XCTAssertTrue(model.netDownHistory.isEmpty)
        XCTAssertTrue(model.netUpHistory.isEmpty)
        XCTAssertEqual(model.cpuHistory.count, 1, "visible sections still record")
    }

    @MainActor
    func testHidingSectionClearsItsBuffer() throws {
        let suite = "MonitorChartsTests-clear"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = MonitorModel(defaults: defaults)
        model.recordHistory(Self.sampleSnapshot())  // network visible ⇒ populated
        XCTAssertFalse(model.netDownHistory.isEmpty)

        model.prefs.visibleSections.remove(.network)  // triggers clear-on-hide

        XCTAssertTrue(model.netDownHistory.isEmpty)
        XCTAssertTrue(model.netUpHistory.isEmpty)
        XCTAssertFalse(model.cpuHistory.isEmpty, "other sections untouched")
    }
}
