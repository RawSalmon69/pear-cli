import XCTest
@testable import PearCompanion

final class SwipeAccumulatorTests: XCTestCase {
    /// One notch below the emission threshold, kept as a fraction so the test
    /// doesn't hard-code the constant's exact value.
    private let big = SwipeAccumulator.threshold + 10

    func testFullSwipeEmitsExactlyOnce() {
        var acc = SwipeAccumulator()
        XCTAssertNil(acc.feed(deltaX: -10, deltaY: 0, phase: .began))
        XCTAssertNil(acc.feed(deltaX: -20, deltaY: 0, phase: .changed))
        // Crosses the threshold on this frame.
        XCTAssertEqual(acc.feed(deltaX: -30, deltaY: 0, phase: .changed), .next)
        // Further travel in the same gesture must not fire again.
        XCTAssertNil(acc.feed(deltaX: -40, deltaY: 0, phase: .changed))
        XCTAssertNil(acc.feed(deltaX: 0, deltaY: 0, phase: .ended))
    }

    func testVerticalScrollIsIgnored() {
        var acc = SwipeAccumulator()
        XCTAssertNil(acc.feed(deltaX: 0, deltaY: -100, phase: .began))
        // Vertical-dominant frames never accumulate, so a threshold is never hit.
        XCTAssertNil(acc.feed(deltaX: 5, deltaY: -200, phase: .changed))
        XCTAssertNil(acc.feed(deltaX: 5, deltaY: -200, phase: .changed))
        XCTAssertNil(acc.feed(deltaX: 0, deltaY: 0, phase: .ended))
    }

    func testMomentumDoesNotFire() {
        var acc = SwipeAccumulator()
        // A big momentum frame from a fresh accumulator must not emit.
        XCTAssertNil(acc.feed(deltaX: -big, deltaY: 0, phase: .momentum))
    }

    func testMomentumAfterASwipeDoesNotDoubleFire() {
        var acc = SwipeAccumulator()
        XCTAssertEqual(acc.feed(deltaX: -big, deltaY: 0, phase: .began), .next)
        XCTAssertNil(acc.feed(deltaX: 0, deltaY: 0, phase: .ended))
        // Inertia frames coasting in the same direction stay silent.
        XCTAssertNil(acc.feed(deltaX: -big, deltaY: 0, phase: .momentum))
        XCTAssertNil(acc.feed(deltaX: -big, deltaY: 0, phase: .momentum))
    }

    func testDirectionFollowsSign() {
        var forward = SwipeAccumulator()
        XCTAssertEqual(forward.feed(deltaX: -big, deltaY: 0, phase: .began), .next)

        var backward = SwipeAccumulator()
        XCTAssertEqual(backward.feed(deltaX: big, deltaY: 0, phase: .began), .previous)
    }

    func testBelowThresholdDoesNotEmit() {
        var acc = SwipeAccumulator()
        XCTAssertNil(acc.feed(deltaX: -10, deltaY: 0, phase: .began))
        XCTAssertNil(acc.feed(deltaX: -10, deltaY: 0, phase: .changed))
        XCTAssertNil(acc.feed(deltaX: 0, deltaY: 0, phase: .ended))
    }

    func testReArmsForTheNextGesture() {
        var acc = SwipeAccumulator()
        // First gesture stays under the threshold.
        XCTAssertNil(acc.feed(deltaX: -20, deltaY: 0, phase: .began))
        XCTAssertNil(acc.feed(deltaX: 0, deltaY: 0, phase: .ended))
        // A new `.began` resets accumulation, so the second gesture can fire.
        XCTAssertEqual(acc.feed(deltaX: -big, deltaY: 0, phase: .began), .next)
    }
}
