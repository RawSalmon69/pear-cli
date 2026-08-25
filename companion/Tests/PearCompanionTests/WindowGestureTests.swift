import CoreGraphics
import XCTest

@testable import PearCompanion

/// Every rule the recogniser has to hold, driven entirely by injected input —
/// no trackpad, no window, no AX.
final class WindowGestureTests: XCTestCase {
    private typealias T = WindowGestureRecognizer.Threshold

    // MARK: - Harness

    /// Runs a whole gesture: `began`, the frames, `ended`. Returns whatever the
    /// `ended` frame produced, and fails if any earlier frame produced anything
    /// — nothing may fire while the fingers are still down.
    private func gesture(
        _ frames: [GestureInput], file: StaticString = #filePath, line: UInt = #line
    ) -> WindowAction? {
        var recognizer = WindowGestureRecognizer()
        XCTAssertNil(recognizer.accept(.began), "began fired", file: file, line: line)
        for frame in frames {
            XCTAssertNil(recognizer.accept(frame), "\(frame) fired mid-gesture", file: file, line: line)
        }
        return recognizer.accept(.ended)
    }

    /// Splits a total travel across several frames, so accumulation is under
    /// test as well as the final verdict.
    private func swipe(dx: CGFloat = 0, dy: CGFloat = 0, frames: Int = 4) -> [GestureInput] {
        (0..<frames).map { _ in
            .scrolled(dx: dx / CGFloat(frames), dy: dy / CGFloat(frames), isMomentum: false)
        }
    }

    private func momentum(dx: CGFloat = 0, dy: CGFloat = 0, frames: Int = 4) -> [GestureInput] {
        (0..<frames).map { _ in
            .scrolled(dx: dx / CGFloat(frames), dy: dy / CGFloat(frames), isMomentum: true)
        }
    }

    private func pinch(_ total: CGFloat, frames: Int = 4) -> [GestureInput] {
        (0..<frames).map { _ in .magnified(by: total / CGFloat(frames)) }
    }

    /// The eight compass directions as unit vectors, +x right and +y down.
    private let compass: [(name: String, dx: CGFloat, dy: CGFloat)] = [
        ("left", -1, 0), ("right", 1, 0), ("up", 0, -1), ("down", 0, 1),
        ("up-left", -1, -1), ("up-right", 1, -1),
        ("down-left", -1, 1), ("down-right", 1, 1),
    ]

    // MARK: - Direction mapping

    func testSwipeLeftSnapsTheLeftHalf() {
        XCTAssertEqual(gesture(swipe(dx: -120)), .snap(WindowZoneMath.leftHalf))
    }

    func testSwipeRightSnapsTheRightHalf() {
        XCTAssertEqual(gesture(swipe(dx: 120)), .snap(WindowZoneMath.rightHalf))
    }

    func testSwipeUpMaximises() {
        XCTAssertEqual(gesture(swipe(dy: -120)), .snap(WindowZoneMath.maximize))
    }

    func testSwipeDownMinimises() {
        XCTAssertEqual(gesture(swipe(dy: 120)), .minimize)
    }

    func testEachDiagonalSnapsItsMatchingQuarter() {
        XCTAssertEqual(gesture(swipe(dx: -120, dy: -120)), .snap(WindowZoneMath.topLeftQuarter))
        XCTAssertEqual(gesture(swipe(dx: 120, dy: -120)), .snap(WindowZoneMath.topRightQuarter))
        XCTAssertEqual(gesture(swipe(dx: -120, dy: 120)), .snap(WindowZoneMath.bottomLeftQuarter))
        XCTAssertEqual(gesture(swipe(dx: 120, dy: 120)), .snap(WindowZoneMath.bottomRightQuarter))
    }

    func testPinchOutMaximises() {
        XCTAssertEqual(gesture(pinch(0.3)), .snap(WindowZoneMath.maximize))
    }

    func testPinchInRestores() {
        XCTAssertEqual(gesture(pinch(-0.3)), .restore)
    }

    // MARK: - Momentum never acts

    func testMomentumAloneNeverFires() {
        XCTAssertNil(gesture(momentum(dx: -900)))
        XCTAssertNil(gesture(momentum(dy: 900)))
        XCTAssertNil(gesture(momentum(dx: 900, dy: 900)))
    }

    func testMomentumDoesNotAccumulateTowardAThreshold() {
        // Inertia far past every threshold, plus a real nudge that is nowhere
        // near one. If momentum counted, this would snap.
        XCTAssertNil(gesture(momentum(dx: -900) + swipe(dx: -10)))
    }

    func testMomentumAfterARealSwipeDoesNotFireASecondAction() {
        var recognizer = WindowGestureRecognizer()
        XCTAssertNil(recognizer.accept(.began))
        for frame in swipe(dx: -120) { XCTAssertNil(recognizer.accept(frame)) }
        XCTAssertEqual(recognizer.accept(.ended), .snap(WindowZoneMath.leftHalf))
        // The flick now coasts. Not one more action.
        for frame in momentum(dx: -900) { XCTAssertNil(recognizer.accept(frame)) }
        XCTAssertNil(recognizer.accept(.ended))
    }

    // MARK: - One action per gesture

    func testAGestureFiresExactlyOnce() {
        var recognizer = WindowGestureRecognizer()
        XCTAssertNil(recognizer.accept(.began))
        for frame in swipe(dx: 400) { XCTAssertNil(recognizer.accept(frame)) }
        XCTAssertEqual(recognizer.accept(.ended), .snap(WindowZoneMath.rightHalf))
        // A duplicate end frame is not a second gesture.
        XCTAssertNil(recognizer.accept(.ended))
    }

    func testScrollAfterTheGestureEndedIsIgnoredUntilAFreshBegan() {
        var recognizer = WindowGestureRecognizer()
        XCTAssertNil(recognizer.accept(.began))
        for frame in swipe(dx: -120) { XCTAssertNil(recognizer.accept(frame)) }
        XCTAssertEqual(recognizer.accept(.ended), .snap(WindowZoneMath.leftHalf))
        // Stray non-momentum frames with no `began` behind them do nothing…
        for frame in swipe(dy: 400) { XCTAssertNil(recognizer.accept(frame)) }
        XCTAssertNil(recognizer.accept(.ended))
        // …and none of that travel survives into the next gesture.
        XCTAssertNil(recognizer.accept(.began))
        XCTAssertNil(recognizer.accept(.ended))
    }

    func testAFreshBeganReArmsTheRecognizer() {
        var recognizer = WindowGestureRecognizer()
        XCTAssertNil(recognizer.accept(.began))
        for frame in swipe(dx: -120) { XCTAssertNil(recognizer.accept(frame)) }
        XCTAssertEqual(recognizer.accept(.ended), .snap(WindowZoneMath.leftHalf))
        XCTAssertNil(recognizer.accept(.began))
        for frame in swipe(dx: 120) { XCTAssertNil(recognizer.accept(frame)) }
        XCTAssertEqual(recognizer.accept(.ended), .snap(WindowZoneMath.rightHalf))
    }

    func testABeganMidGestureRestartsTheAccumulation() {
        var recognizer = WindowGestureRecognizer()
        XCTAssertNil(recognizer.accept(.began))
        for frame in swipe(dx: -400) { XCTAssertNil(recognizer.accept(frame)) }
        XCTAssertNil(recognizer.accept(.began))
        XCTAssertNil(recognizer.accept(.ended))
    }

    // MARK: - A threshold, not a hair trigger

    func testBelowTheThresholdDoesNothingAtAll() {
        for direction in compass {
            let travel = T.swipe - 1
            XCTAssertNil(
                gesture(swipe(dx: direction.dx * travel, dy: direction.dy * travel)),
                direction.name)
        }
    }

    func testExactlyTheThresholdCounts() {
        // One frame, so the assertion is about the boundary and not about
        // floating-point accumulation.
        XCTAssertEqual(
            gesture([.scrolled(dx: -T.swipe, dy: 0, isMomentum: false)]),
            .snap(WindowZoneMath.leftHalf))
    }

    func testASqueezeBelowThePinchThresholdDoesNothing() {
        XCTAssertNil(gesture(pinch(-(T.pinch - 0.05))))
        XCTAssertNil(gesture(pinch(T.pinch - 0.05)))
    }

    func testAGestureWithNoMotionAtAllDoesNothing() {
        XCTAssertNil(gesture([]))
    }

    // MARK: - Direction must be decisive

    func testADriftBetweenTheAxisAndDiagonalBandsCommitsToNothing() {
        // Ratio 0.5: too slanted to be an axis swipe, too flat to be a corner.
        XCTAssertNil(gesture(swipe(dx: -200, dy: -100)))
        XCTAssertNil(gesture(swipe(dx: 100, dy: 200)))
    }

    func testAWobblyAxisSwipeStillPicksItsAxis() {
        // Ratio 0.25 — a real left swipe with a shaky hand.
        XCTAssertEqual(gesture(swipe(dx: -200, dy: -50)), .snap(WindowZoneMath.leftHalf))
        XCTAssertEqual(gesture(swipe(dx: 50, dy: 200)), .minimize)
    }

    func testADownwardDiagonalIsNotMistakenForMinimise() {
        XCTAssertEqual(gesture(swipe(dx: 150, dy: 180)), .snap(WindowZoneMath.bottomRightQuarter))
        XCTAssertEqual(gesture(swipe(dx: -150, dy: 180)), .snap(WindowZoneMath.bottomLeftQuarter))
    }

    func testMinimiseIsNotMistakenForADownwardDiagonal() {
        XCTAssertEqual(gesture(swipe(dx: 20, dy: 200)), .minimize)
        XCTAssertEqual(gesture(swipe(dx: -20, dy: 200)), .minimize)
    }

    func testACornerNeedsRealTravelOnBothAxes() {
        // Ratio is diagonal-ish, but the short leg never reached the threshold.
        XCTAssertNil(gesture(swipe(dx: -50, dy: -65)))
    }

    // MARK: - Cancelled means nothing happened

    func testCancelledFiresNothingAndResets() {
        var recognizer = WindowGestureRecognizer()
        XCTAssertNil(recognizer.accept(.began))
        for frame in swipe(dx: -400) { XCTAssertNil(recognizer.accept(frame)) }
        XCTAssertNil(recognizer.accept(.cancelled))
        XCTAssertNil(recognizer.pending)
        // The abandoned travel must not carry into the next gesture.
        XCTAssertNil(recognizer.accept(.began))
        for frame in swipe(dx: -10) { XCTAssertNil(recognizer.accept(frame)) }
        XCTAssertNil(recognizer.accept(.ended))
    }

    func testAnEndAfterACancelFiresNothing() {
        var recognizer = WindowGestureRecognizer()
        XCTAssertNil(recognizer.accept(.began))
        for frame in swipe(dx: -400) { XCTAssertNil(recognizer.accept(frame)) }
        XCTAssertNil(recognizer.accept(.cancelled))
        XCTAssertNil(recognizer.accept(.ended))
    }

    // MARK: - Destructive actions

    func testADeepSqueezeCloses() {
        let action = gesture(pinch(-0.8))
        XCTAssertEqual(action, .close)
        XCTAssertEqual(action?.isDestructive, true)
    }

    func testADeepSqueezeThrownDownwardQuitsTheApp() {
        let action = gesture(pinch(-0.8) + swipe(dy: T.destructiveTravel + 40))
        XCTAssertEqual(action, .quitApp)
        XCTAssertEqual(action?.isDestructive, true)
    }

    func testASqueezeThatStopsShortOfCloseOnlyRestores() {
        XCTAssertEqual(gesture(pinch(-(T.pinchClose - 0.05))), .restore)
    }

    func testAQuitThatStopsShortOfTheThrowOnlyCloses() {
        XCTAssertEqual(gesture(pinch(-0.8) + swipe(dy: T.destructiveTravel - 40)), .close)
    }

    func testAQuitSizedSwipeWithoutTheSqueezeOnlyMinimises() {
        XCTAssertEqual(gesture(swipe(dy: T.destructiveTravel * 3)), .minimize)
    }

    func testTheThrowMustBeClearlyDownwardNotSideways() {
        // Long, but slanted — reads as a plain close, never a quit.
        XCTAssertEqual(
            gesture(pinch(-0.8) + swipe(dx: 400, dy: T.destructiveTravel + 40)), .close)
        // …and upward travel is not a throw at all.
        XCTAssertEqual(gesture(pinch(-0.8) + swipe(dy: -(T.destructiveTravel * 2))), .close)
    }

    func testNoSwipeOfAnyLengthInAnyDirectionIsDestructive() {
        // The whole point of putting close and quit on the pinch channel:
        // scroll deltas are pointer-accelerated, so travel alone must never be
        // able to reach an irreversible action.
        for direction in compass {
            for travel in [T.swipe, T.destructiveTravel, 2_000, 20_000] as [CGFloat] {
                let action = gesture(swipe(dx: direction.dx * travel, dy: direction.dy * travel))
                XCTAssertNotEqual(action?.isDestructive, true, "\(direction.name) \(travel)")
            }
        }
    }

    func testMomentumCannotUpgradeACloseIntoAQuit() {
        // The squeeze is real; the downward travel is inertia. Quit needs a
        // throw the user actually made.
        XCTAssertEqual(
            gesture(pinch(-0.8) + momentum(dy: T.destructiveTravel * 5)), .close)
    }

    func testDestructiveActionsNeedMateriallyMoreTravelThanASnap() {
        // The table itself, so a later tweak cannot quietly bring the
        // destructive tier down to snap range.
        XCTAssertGreaterThanOrEqual(T.pinchClose, T.pinch * 4)
        XCTAssertGreaterThanOrEqual(T.destructiveTravel, T.swipe * 4)
        // And behaviourally: snap-sized versions of both destructive motions
        // land on the mild action, not the destructive one.
        XCTAssertEqual(gesture([.magnified(by: -T.pinch)]), .restore)
        XCTAssertEqual(gesture(swipe(dy: T.swipe)), .minimize)
    }

    // MARK: - Pinch beats scroll drift

    func testASqueezeWinsOverTheScrollDriftItLeaks() {
        // Fingers converging drag the contact centroid; a two-finger scroll
        // emits no magnification at all, so the pinch is what the user meant.
        XCTAssertEqual(gesture(pinch(-0.3) + swipe(dx: -120)), .restore)
    }

    // MARK: - "Not yet" vs "never"

    func testPendingIsNilUntilTheMotionIsDecisive() {
        var recognizer = WindowGestureRecognizer()
        XCTAssertNil(recognizer.pending, "nothing is in flight yet")
        XCTAssertNil(recognizer.accept(.began))
        XCTAssertNil(recognizer.pending)
        XCTAssertNil(recognizer.accept(.scrolled(dx: -30, dy: 0, isMomentum: false)))
        XCTAssertNil(recognizer.pending, "below the threshold: not yet")
        XCTAssertNil(recognizer.accept(.scrolled(dx: -60, dy: -45, isMomentum: false)))
        XCTAssertNil(recognizer.pending, "ambiguous slant: never, at this size")
        XCTAssertNil(recognizer.accept(.scrolled(dx: -120, dy: 0, isMomentum: false)))
        XCTAssertEqual(recognizer.pending, .snap(WindowZoneMath.leftHalf))
        XCTAssertEqual(recognizer.accept(.ended), .snap(WindowZoneMath.leftHalf))
        XCTAssertNil(recognizer.pending, "spent")
    }

    func testPendingIgnoresMomentum() {
        var recognizer = WindowGestureRecognizer()
        XCTAssertNil(recognizer.accept(.began))
        for frame in momentum(dx: -900) { XCTAssertNil(recognizer.accept(frame)) }
        XCTAssertNil(recognizer.pending)
    }
}
