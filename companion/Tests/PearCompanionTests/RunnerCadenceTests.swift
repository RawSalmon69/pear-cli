import XCTest
@testable import PearCompanion

/// Pure-logic coverage for the menu-bar runner's CPU-load → frame-interval
/// mapping (adapted from RunCat365). The animation timer and CPU sampler touch
/// time and hardware and are not unit-tested; this is the part that must be
/// exactly right on every machine.
final class RunnerCadenceTests: XCTestCase {

    /// Idle (0% CPU) ambles at exactly the idle interval.
    func testIdleFloor() {
        XCTAssertEqual(
            RunnerCadence.frameInterval(cpuFraction: 0),
            RunnerCadence.idleInterval,
            accuracy: 1e-9)
    }

    /// Pegged (100% CPU) sprints at exactly the pegged interval.
    func testPeggedCeiling() {
        XCTAssertEqual(
            RunnerCadence.frameInterval(cpuFraction: 1),
            RunnerCadence.peggedInterval,
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

    /// A midpoint load lands strictly between the endpoints (the mapping isn't
    /// degenerate) and matches the RunCat-shaped `base / speed` curve.
    func testMidpointBetweenEndpoints() {
        let mid = RunnerCadence.frameInterval(cpuFraction: 0.5)
        XCTAssertGreaterThan(mid, RunnerCadence.peggedInterval)
        XCTAssertLessThan(mid, RunnerCadence.idleInterval)
        // speed = 1 + 0.5*(0.200/0.040 - 1) = 3 -> 0.200 / 3.
        XCTAssertEqual(mid, RunnerCadence.idleInterval / 3, accuracy: 1e-9)
    }
}
