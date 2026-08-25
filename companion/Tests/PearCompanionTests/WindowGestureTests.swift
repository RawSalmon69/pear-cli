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

    func testSwipeUpTogglesFullScreen() {
        // Not maximise: Swish's up-swipe puts the window into a full-screen
        // Space, and "it just moved up and got bigger" is exactly the complaint
        // maximise-on-up earned.
        XCTAssertEqual(gesture(swipe(dy: -120)), .fullScreen)
    }

    func testFullScreenIsNotDestructive() {
        // The same gesture takes the window back out, so a mis-fire costs one
        // more gesture and nothing else.
        XCTAssertEqual(WindowAction.fullScreen.isDestructive, false)
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

    // MARK: - The pinch ladder

    // Each rung is asserted at exactly its threshold, from one frame, so the
    // assertion is about the boundary and not about how four fractions of a
    // squeeze happen to round when they are added up.

    func testALightSqueezeRestores() {
        XCTAssertEqual(gesture([.magnified(by: -T.pinch)]), .restore)
    }

    func testAFirmSqueezeCloses() {
        let action = gesture([.magnified(by: -T.pinchClose)])
        XCTAssertEqual(action, .close)
        XCTAssertEqual(action?.isDestructive, true)
    }

    func testSqueezingAllTheWayQuits() {
        let action = gesture([.magnified(by: -T.pinchQuit)])
        XCTAssertEqual(action, .quitApp)
        XCTAssertEqual(action?.isDestructive, true)
    }

    /// …and once across several frames, because the recogniser is what sums
    /// them: a squeeze delivered in twenty increments still has to reach quit.
    func testASqueezeAccumulatesAcrossItsFramesToTheDeepestRung() {
        XCTAssertEqual(gesture(pinch(-0.95, frames: 20)), .quitApp)
    }

    /// The gaps between the rungs, not only the rungs themselves: a squeeze
    /// landing anywhere inside a band has to read as that band's action.
    func testEveryPointInABandReadsAsThatBandsAction() {
        for total in stride(from: T.pinch, to: T.pinchClose, by: 0.05) {
            XCTAssertEqual(gesture([.magnified(by: -total)]), .restore, "\(total)")
        }
        for total in stride(from: T.pinchClose, to: T.pinchQuit, by: 0.05) {
            XCTAssertEqual(gesture([.magnified(by: -total)]), .close, "\(total)")
        }
        for total in stride(from: T.pinchQuit, through: 1.0, by: 0.05) {
            XCTAssertEqual(gesture([.magnified(by: -total)]), .quitApp, "\(total)")
        }
    }

    /// Every shortfall degrades *downward*. Single-frame, so each assertion is
    /// about the boundary rather than about floating-point accumulation.
    func testASqueezeThatStopsShortOfQuitOnlyCloses() {
        XCTAssertEqual(
            gesture([.magnified(by: -(T.pinchQuit - 0.01))]), .close,
            "not-quite-quit must be close, not nothing")
    }

    func testASqueezeThatStopsShortOfCloseOnlyRestores() {
        XCTAssertEqual(gesture([.magnified(by: -(T.pinchClose - 0.01))]), .restore)
    }

    func testASqueezeThatStopsShortOfRestoreDoesNothing() {
        XCTAssertNil(gesture([.magnified(by: -(T.pinch - 0.01))]))
    }

    /// An enthusiastic close must not land on quit. Overshooting the close
    /// threshold by three quarters of itself is still a close.
    func testOvershootingACloseIsStillAClose() {
        XCTAssertEqual(gesture(pinch(-(T.pinchClose * 1.75))), .close)
    }

    /// The ladder lives on the pinch channel *only*. Scroll deltas are
    /// pointer-accelerated, so travel alone must never reach an irreversible
    /// action, however far it goes.
    func testNoSwipeOfAnyLengthInAnyDirectionIsDestructive() {
        for direction in compass {
            for travel in [T.swipe, 240, 2_000, 20_000] as [CGFloat] {
                let action = gesture(swipe(dx: direction.dx * travel, dy: direction.dy * travel))
                XCTAssertNotEqual(action?.isDestructive, true, "\(direction.name) \(travel)")
            }
        }
    }

    /// A long downward swipe is the shape the old quit gesture had — a deep
    /// squeeze thrown downward. On its own it is a minimise and nothing else,
    /// however long it is.
    func testAVeryLongDownwardSwipeOnlyMinimises() {
        XCTAssertEqual(gesture(swipe(dy: 2_000)), .minimize)
    }

    func testTravelCannotDeepenAPinchVerdict() {
        // Neither real travel nor inertia may promote a close into a quit: the
        // rung is decided by the squeeze and by nothing else.
        XCTAssertEqual(gesture(pinch(-0.6) + swipe(dy: 2_000)), .close)
        XCTAssertEqual(gesture(pinch(-0.6) + momentum(dy: 2_000)), .close)
        XCTAssertEqual(gesture(pinch(-0.6) + swipe(dx: -2_000, dy: 2_000)), .close)
    }

    func testTheThresholdTableKeepsItsRungsApart() {
        // The table itself, so a later tweak cannot quietly bring a destructive
        // rung down into benign range or bunch two rungs together.
        XCTAssertGreaterThanOrEqual(T.pinchClose, T.pinch * 3)
        XCTAssertGreaterThanOrEqual(T.pinchQuit, T.pinchClose * 1.8)
        XCTAssertGreaterThanOrEqual(
            T.pinchQuit - T.pinchClose, T.pinchClose - T.pinch,
            "close→quit must be at least as wide as restore→close")
        // A pinch-in of 1.0 is the fingers meeting, so the deepest rung has to
        // stay inside the channel to be reachable at all.
        XCTAssertLessThan(T.pinchQuit, 1.0)
        // And behaviourally: a snap-sized squeeze lands on the mild action.
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
