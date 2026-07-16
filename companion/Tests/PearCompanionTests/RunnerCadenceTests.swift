import XCTest
@testable import PearCompanion

/// Pure-logic coverage for the menu-bar runner's CPU-load → frame-interval
/// mapping (adopted from menubar_runcat: `0.2 / clamp(usage% / 5, 1, 20)`). The
/// animation timer and CPU sampler touch time and hardware and are not
/// unit-tested; this is the part that must be exactly right on every machine.
final class RunnerCadenceTests: XCTestCase {

    /// The advertised endpoints: 200 ms at idle (upstream's), 50 ms pegged —
    /// deliberately above upstream's 10 ms, because our frame swap re-renders
    /// the SwiftUI MenuBarExtra label and a 10 ms tick burned ~28% CPU while
    /// feeding the load signal that set its own cadence.
    func testEndpointValues() {
        XCTAssertEqual(RunnerCadence.idleInterval, 0.200, accuracy: 1e-9)
        XCTAssertEqual(RunnerCadence.peggedInterval, 0.050, accuracy: 1e-9)
    }

    /// Idle (0% CPU) ambles at exactly the idle interval.
    func testIdleFloor() {
        XCTAssertEqual(
            RunnerCadence.frameInterval(cpuFraction: 0),
            RunnerCadence.idleInterval,
            accuracy: 1e-9)
    }

    /// Pegged (100% CPU) sprints at exactly the pegged interval (0.2 / 4).
    func testPeggedCeiling() {
        XCTAssertEqual(
            RunnerCadence.frameInterval(cpuFraction: 1),
            RunnerCadence.peggedInterval,
            accuracy: 1e-9)
    }

    /// Upstream clamps `speed` to 1 for the first 5% of load, so the runner
    /// stays at the flat idle amble there rather than creeping faster.
    func testFlatBelowFivePercent() {
        XCTAssertEqual(
            RunnerCadence.frameInterval(cpuFraction: 0.03),
            RunnerCadence.idleInterval,
            accuracy: 1e-9)
    }

    /// More load never means a slower runner: the interval is monotonically
    /// non-increasing across the whole 0…1 range.
    func testMonotonicNonIncreasing() {
        var previous = RunnerCadence.frameInterval(cpuFraction: 0)
        for step in 1...100 {
            let interval = RunnerCadence.frameInterval(cpuFraction: Double(step) / 100)
            XCTAssertLessThanOrEqual(interval, previous, "step \(step)")
            previous = interval
        }
    }

    /// Out-of-range input (negative, or above 1 from a bad sample) clamps to the
    /// endpoints rather than producing a runaway or stalled timer.
    func testClampsOutOfRange() {
        XCTAssertEqual(
            RunnerCadence.frameInterval(cpuFraction: -5),
            RunnerCadence.idleInterval,
            accuracy: 1e-9)
        XCTAssertEqual(
            RunnerCadence.frameInterval(cpuFraction: 42),
            RunnerCadence.peggedInterval,
            accuracy: 1e-9)
        // Every result stays inside the advertised bounds.
        for raw in stride(from: -1.0, through: 2.0, by: 0.05) {
            let interval = RunnerCadence.frameInterval(cpuFraction: raw)
            XCTAssertGreaterThanOrEqual(interval, RunnerCadence.peggedInterval, "raw \(raw)")
            XCTAssertLessThanOrEqual(interval, RunnerCadence.idleInterval, "raw \(raw)")
        }
    }

    /// A mid-range load lands strictly between the endpoints (the mapping isn't
    /// degenerate) and matches upstream's curve below the lowered ceiling.
    func testMidpointBetweenEndpoints() {
        let mid = RunnerCadence.frameInterval(cpuFraction: 0.15)
        XCTAssertGreaterThan(mid, RunnerCadence.peggedInterval)
        XCTAssertLessThan(mid, RunnerCadence.idleInterval)
        // usage% = 15 -> speed = clamp(15/5, 1, 4) = 3 -> 0.200 / 3.
        XCTAssertEqual(mid, RunnerCadence.idleInterval / 3, accuracy: 1e-9)
        // Anything at or past 20% load is already at the ceiling.
        XCTAssertEqual(
            RunnerCadence.frameInterval(cpuFraction: 0.5),
            RunnerCadence.peggedInterval,
            accuracy: 1e-9)
    }
}
