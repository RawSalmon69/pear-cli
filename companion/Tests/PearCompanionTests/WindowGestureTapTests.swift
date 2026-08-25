import AppKit
import ApplicationServices
import CoreGraphics
import XCTest

@testable import PearCompanion

/// Logic-level cover for the trackpad window gestures: the swallow rule, who
/// owns a gesture, how a scroll event is decoded, and what reaches the mover.
///
/// No event tap and no global monitor: `WindowGestureTap.start()` refuses to
/// touch the system under `swift test`, and every case drives `handle` — the
/// same function the real tap's callback calls — with synthesised frames.
///
/// **The swallow assertions are the point of this file.** This tap sees every
/// scroll event on the machine, so a case that feeds a frame asserts on the
/// returned Bool, not just on the mover.
@MainActor
final class WindowGestureTapTests: XCTestCase {
    // MARK: - Doubles

    private final class RecordingMover: WindowMover {
        var previews: [WindowAction?] = []
        var commits: [WindowAction] = []

        func preview(_ action: WindowAction?) { previews.append(action) }
        func commit(_ action: WindowAction) { commits.append(action) }
    }

    /// Counts how many times the policy asks whether the pointer is on a title
    /// bar. `answers` is consumed in order and the last value repeats, so a case
    /// can say "on a bar when it began, off it ever after".
    private final class TitleBarSpy {
        private(set) var calls = 0
        private var answers: [Bool]

        init(_ answers: [Bool]) { self.answers = answers }

        func ask() -> Bool {
            defer { calls += 1 }
            return answers.count > 1 ? answers.removeFirst() : (answers.first ?? false)
        }
    }

    // MARK: - Fixtures

    private func began(dx: CGFloat = 0, dy: CGFloat = 0, momentum: Bool = false) -> ScrollFrame {
        ScrollFrame(phase: .began, isMomentum: momentum, dx: dx, dy: dy)
    }

    private func changed(dx: CGFloat = 0, dy: CGFloat = 0, momentum: Bool = false) -> ScrollFrame {
        ScrollFrame(phase: .changed, isMomentum: momentum, dx: dx, dy: dy)
    }

    private let ended = ScrollFrame(phase: .ended, isMomentum: false, dx: 0, dy: 0)
    private let cancelled = ScrollFrame(phase: .cancelled, isMomentum: false, dx: 0, dy: 0)
    /// An inertia frame as the window server actually delivers it: momentum set,
    /// no scroll phase at all.
    private let coasting = ScrollFrame(phase: .other, isMomentum: true, dx: 300, dy: 0)

    // MARK: - The swallow rule

    /// The single most important case: a two-finger scroll that did not start on
    /// a title bar belongs to the app under the pointer, start to finish.
    func testAGestureThatDidNotBeginOnATitleBarIsNeverSwallowed() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([false])

        var outcomes = [policy.handle(began(dx: 5), isOverTitleBar: spy.ask)]
        for _ in 0..<5 { outcomes.append(policy.handle(changed(dx: 60), isOverTitleBar: spy.ask)) }
        outcomes.append(policy.handle(ended, isOverTitleBar: spy.ask))
        outcomes.append(policy.handle(coasting, isOverTitleBar: spy.ask))

        XCTAssertEqual(outcomes.filter(\.swallow).count, 0, "not one frame may be swallowed")
        XCTAssertTrue(outcomes.allSatisfy { $0.commit == nil })
        XCTAssertTrue(outcomes.allSatisfy { $0.preview == .unchanged })
        XCTAssertFalse(policy.ownsGesture)
    }

    /// The mirror: once a gesture is ours it stays ours, even though the pointer
    /// has left the title bar long before the fingers lift. Abandoning halfway
    /// would hand the app the tail of a scroll it never saw the start of.
    func testAGestureThatBeganOnATitleBarIsSwallowedForItsWholeDuration() {
        var policy = WindowGesturePolicy()
        // On a bar for the first question, off it for every later one.
        let spy = TitleBarSpy([true, false])

        XCTAssertTrue(policy.handle(began(dx: 5), isOverTitleBar: spy.ask).swallow)
        for _ in 0..<5 {
            XCTAssertTrue(policy.handle(changed(dx: 40), isOverTitleBar: spy.ask).swallow)
        }
        XCTAssertTrue(policy.ownsGesture)

        let last = policy.handle(ended, isOverTitleBar: spy.ask)
        XCTAssertTrue(last.swallow)
        XCTAssertEqual(last.commit, .snap(WindowZoneMath.rightHalf))
        XCTAssertFalse(policy.ownsGesture, "the gesture is spent the moment it ends")
    }

    /// Ownership is a question asked once. Asking again per event would both cost
    /// an Accessibility round-trip per frame and let the answer change mid-swipe.
    func testOwnershipIsDecidedOncePerGesture() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])

        _ = policy.handle(began(), isOverTitleBar: spy.ask)
        for _ in 0..<20 { _ = policy.handle(changed(dx: 3), isOverTitleBar: spy.ask) }
        _ = policy.handle(ended, isOverTitleBar: spy.ask)
        XCTAssertEqual(spy.calls, 1, "one lookup for a whole gesture")

        _ = policy.handle(began(), isOverTitleBar: spy.ask)
        _ = policy.handle(ended, isOverTitleBar: spy.ask)
        XCTAssertEqual(spy.calls, 2, "and exactly one more for the next gesture")
    }

    /// Inertia is the window server's doing, not the user's, and it arrives with
    /// no scroll phase — so it is nobody's gesture and goes to the app.
    func testTheInertiaTailIsNotSwallowed() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])

        _ = policy.handle(began(), isOverTitleBar: spy.ask)
        _ = policy.handle(changed(dx: 200), isOverTitleBar: spy.ask)
        XCTAssertEqual(policy.handle(ended, isOverTitleBar: spy.ask).commit,
                       .snap(WindowZoneMath.rightHalf))

        let coast = policy.handle(coasting, isOverTitleBar: spy.ask)
        XCTAssertFalse(coast.swallow)
        XCTAssertNil(coast.commit)
        XCTAssertEqual(spy.calls, 1, "and it never even asks where the pointer is")
    }

    /// The one way this tap could swallow a long run of somebody else's scrolling
    /// is by holding ownership after its gesture is over — which needs the
    /// `ended` frame to go missing, as it would if the system switched the tap
    /// off mid-gesture. Inertia proves the fingers lifted, so it lets go, and it
    /// fires nothing: a gesture whose end was never seen should do nothing.
    func testInertiaReleasesAGestureWhoseEndWasLost() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])

        _ = policy.handle(began(), isOverTitleBar: spy.ask)
        _ = policy.handle(changed(dx: 200), isOverTitleBar: spy.ask)
        XCTAssertTrue(policy.ownsGesture)

        let coast = policy.handle(coasting, isOverTitleBar: spy.ask)
        XCTAssertFalse(coast.swallow)
        XCTAssertNil(coast.commit)
        XCTAssertEqual(coast.preview, .show(nil), "and the orphaned preview comes down")
        XCTAssertFalse(policy.ownsGesture)

        // The late `ended` is now nobody's, and the next gesture is unaffected.
        XCTAssertFalse(policy.handle(ended, isOverTitleBar: spy.ask).swallow)
        XCTAssertTrue(policy.handle(began(), isOverTitleBar: spy.ask).swallow)
    }

    /// A momentum frame reaching the recogniser mid-gesture must be reported *as*
    /// momentum, so it accumulates nothing: 400 points of coasting cannot
    /// manufacture a snap the user's fingers never made. The paired assertion
    /// below is what keeps this from passing vacuously.
    func testMomentumTravelIsReportedAsMomentumAndNeverFires() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])

        _ = policy.handle(began(), isOverTitleBar: spy.ask)
        let coast = policy.handle(changed(dx: 400, momentum: true), isOverTitleBar: spy.ask)
        XCTAssertEqual(coast.preview, .unchanged, "inertia is not travel, so nothing is pending")
        XCTAssertNil(policy.handle(ended, isOverTitleBar: spy.ask).commit)

        // The identical travel with the fingers actually down does fire.
        var real = WindowGesturePolicy()
        let realSpy = TitleBarSpy([true])
        _ = real.handle(began(), isOverTitleBar: realSpy.ask)
        _ = real.handle(changed(dx: 400), isOverTitleBar: realSpy.ask)
        XCTAssertEqual(real.handle(ended, isOverTitleBar: realSpy.ask).commit,
                       .snap(WindowZoneMath.rightHalf))
    }

    /// Momentum cannot *begin* a gesture either, and is cheap enough to reject
    /// that it never costs a lookup.
    func testMomentumCannotBeginAGesture() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])

        let outcome = policy.handle(began(dx: 90, momentum: true), isOverTitleBar: spy.ask)
        XCTAssertFalse(outcome.swallow)
        XCTAssertFalse(policy.ownsGesture)
        XCTAssertEqual(spy.calls, 0)
    }

    /// Every shape the policy did not expect resolves to pass-through: a frame
    /// with no phase, and the three transitions arriving with no gesture open.
    func testUnexpectedFramesPassThrough() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])
        let strays = [
            ScrollFrame(phase: .other, isMomentum: false, dx: 200, dy: 0),
            changed(dx: 200), ended, cancelled,
        ]

        for frame in strays {
            let outcome = policy.handle(frame, isOverTitleBar: spy.ask)
            XCTAssertFalse(outcome.swallow, "\(frame.phase) with no gesture open must pass through")
            XCTAssertNil(outcome.commit)
            XCTAssertEqual(outcome.preview, .unchanged)
        }
        XCTAssertEqual(spy.calls, 0, "and none of them decides ownership")
    }

    /// A phaseless frame arriving mid-gesture leaks to the app rather than being
    /// swallowed on a maybe — and does not tear down the gesture around it.
    func testAPhaselessFrameMidGestureFailsOpenWithoutBreakingTheGesture() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])

        _ = policy.handle(began(), isOverTitleBar: spy.ask)
        _ = policy.handle(changed(dx: 200), isOverTitleBar: spy.ask)
        XCTAssertFalse(
            policy.handle(ScrollFrame(phase: .other, isMomentum: false, dx: 0, dy: 0),
                          isOverTitleBar: spy.ask).swallow)
        XCTAssertTrue(policy.ownsGesture)
        XCTAssertEqual(policy.handle(ended, isOverTitleBar: spy.ask).commit,
                       .snap(WindowZoneMath.rightHalf))
    }

    // MARK: - Pinch

    /// Pinch is gated on the same ownership bit, and never swallows: it arrives
    /// through a read-only monitor, so saying otherwise would be a lie.
    func testPinchOnlyCountsInsideAnOwnedGesture() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])

        let stray = policy.magnified(by: -0.8)
        XCTAssertEqual(stray, WindowGesturePolicy.Outcome(), "no gesture, no effect")

        _ = policy.handle(began(), isOverTitleBar: spy.ask)
        let squeeze = policy.magnified(by: -0.7)
        XCTAssertFalse(squeeze.swallow, "a monitor cannot swallow")
        XCTAssertEqual(squeeze.preview, .show(.close))
        XCTAssertEqual(policy.handle(ended, isOverTitleBar: spy.ask).commit, .close)
    }

    // MARK: - Preview

    /// The preview is written per input event, so an unchanged value must not be
    /// re-sent: it drives an observable and an Accessibility resolve.
    func testThePreviewIsOnlyIssuedWhenItChanges() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])

        _ = policy.handle(began(), isOverTitleBar: spy.ask)
        XCTAssertEqual(policy.handle(changed(dx: 200), isOverTitleBar: spy.ask).preview,
                       .show(.snap(WindowZoneMath.rightHalf)))
        for _ in 0..<5 {
            XCTAssertEqual(policy.handle(changed(dx: 10), isOverTitleBar: spy.ask).preview,
                           .unchanged, "the same zone must not be re-sent")
        }
        XCTAssertEqual(policy.handle(changed(dx: -600), isOverTitleBar: spy.ask).preview,
                       .show(.snap(WindowZoneMath.leftHalf)))
        XCTAssertEqual(policy.handle(ended, isOverTitleBar: spy.ask).preview, .show(nil),
                       "the frame that commits also hides")
    }

    func testCancellingHidesThePreviewAndFiresNothing() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])

        _ = policy.handle(began(), isOverTitleBar: spy.ask)
        _ = policy.handle(changed(dx: 200), isOverTitleBar: spy.ask)
        let outcome = policy.handle(cancelled, isOverTitleBar: spy.ask)
        XCTAssertTrue(outcome.swallow, "the cancel belongs to a gesture Pear owned")
        XCTAssertNil(outcome.commit)
        XCTAssertEqual(outcome.preview, .show(nil))
        XCTAssertFalse(policy.ownsGesture)
    }

    // MARK: - Decoding a real scroll event

    /// The sign convention, pinned to the SDK rather than to memory.
    ///
    /// Two facts this rests on, asserted here so a future SDK that changes
    /// either one fails loudly instead of snapping every window to the wrong
    /// side: `PointDeltaAxis1/2` *are* `NSEvent.scrollingDeltaY/X`, and field 137
    /// *is* `isDirectionInvertedFromDevice`. Natural scrolling means the content
    /// follows the fingers, so with it on the deltas already are finger travel
    /// (+x right, +y down); with it off both axes negate.
    func testScrollEventDecodingAndSignConvention() throws {
        let natural = try XCTUnwrap(makeEvent(axis1: 10, axis2: 20, inverted: 1))
        let asNSEvent = try XCTUnwrap(NSEvent(cgEvent: natural))
        XCTAssertEqual(asNSEvent.scrollingDeltaY, 10, "PointDeltaAxis1 is scrollingDeltaY")
        XCTAssertEqual(asNSEvent.scrollingDeltaX, 20, "PointDeltaAxis2 is scrollingDeltaX")
        XCTAssertTrue(asNSEvent.isDirectionInvertedFromDevice, "field 137 is that flag")

        let inverted = ScrollFrame.read(natural)
        XCTAssertEqual(inverted.dy, 10, "natural scrolling: content follows the fingers")
        XCTAssertEqual(inverted.dx, 20)

        let classic = ScrollFrame.read(try XCTUnwrap(makeEvent(axis1: 10, axis2: 20, inverted: 0)))
        XCTAssertEqual(classic.dy, -10, "natural scrolling off: the content moves the other way")
        XCTAssertEqual(classic.dx, -20)
    }

    /// CoreGraphics' scroll phase is a plain sequence, not the `NSEvent.Phase`
    /// bitmask it looks like. Reading it as the bitmask would take every
    /// `changed` frame for an `ended` one and end the gesture on its first move.
    func testScrollPhaseDecoding() throws {
        let expected: [Int64: ScrollFrame.Phase] = [
            0: .other, 1: .began, 2: .changed, 4: .ended, 8: .cancelled, 128: .other,
        ]
        for (raw, phase) in expected {
            let event = try XCTUnwrap(makeEvent(axis1: 1, axis2: 0, inverted: 1, phase: raw))
            XCTAssertEqual(ScrollFrame.read(event).phase, phase, "scroll phase field \(raw)")
        }
    }

    func testMomentumPhaseDecoding() throws {
        for raw: Int64 in [1, 2, 3] {
            let event = try XCTUnwrap(makeEvent(axis1: 1, axis2: 0, inverted: 1, momentum: raw))
            XCTAssertTrue(ScrollFrame.read(event).isMomentum, "momentum phase \(raw)")
        }
        let still = try XCTUnwrap(makeEvent(axis1: 1, axis2: 0, inverted: 1, momentum: 0))
        XCTAssertFalse(ScrollFrame.read(still).isMomentum)
    }

    private func makeEvent(
        axis1: Int32, axis2: Int32, inverted: Int64, phase: Int64 = 2, momentum: Int64 = 0
    ) -> CGEvent? {
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: axis1, wheel2: axis2, wheel3: 0),
            let invertedField = CGEventField(rawValue: 137)
        else { return nil }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.setIntegerValueField(invertedField, value: inverted)
        return event
    }

    // MARK: - The tap around the policy

    /// A stand-in resolver where every point sits in its own small title bar, so
    /// a lookup 300 points away is a genuinely different window.
    ///
    /// The clock never moves, so the resolver's own 100ms floor between lookups
    /// is in force for the whole test — which is what makes an `invalidate()`
    /// visible as an extra lookup rather than as nothing at all.
    private func makeHitResolver(calls: @escaping () -> Void) -> WindowUnderPointer {
        let element = AXUIElementCreateSystemWide()
        return WindowUnderPointer(
            lookup: { point in
                calls()
                let bar = CGRect(x: point.x - 20, y: point.y - 10, width: 40, height: 20)
                return .titleBar(TitleBarHit(window: element, windowFrame: bar, titleBar: bar))
            },
            clock: { 1_000 })
    }

    /// Ordinary window content: nothing here is ever a title bar.
    private func makeMissResolver() -> WindowUnderPointer {
        WindowUnderPointer(lookup: { _ in .nothing }, clock: { 1_000 })
    }

    private let barPoint = CGPoint(x: 200, y: 210)

    /// A committed move makes the cached title bar a lie — the window is not
    /// where it was. The next gesture on a different window must therefore cost
    /// a fresh lookup, even inside the resolver's throttle window.
    func testCommittingInvalidatesTheCachedTitleBar() {
        var lookups = 0
        let mover = RecordingMover()
        let tap = WindowGestureTap(
            mover: mover, windows: makeHitResolver(calls: { lookups += 1 }))
        tap.start()

        XCTAssertTrue(tap.handle(began(), at: barPoint))
        XCTAssertTrue(tap.handle(changed(dx: 200), at: barPoint))
        XCTAssertTrue(tap.handle(ended, at: barPoint))
        XCTAssertEqual(mover.commits, [.snap(WindowZoneMath.rightHalf)])
        XCTAssertEqual(mover.previews, [.snap(WindowZoneMath.rightHalf), nil],
                       "preview, then hidden after the commit")
        XCTAssertEqual(lookups, 1)

        // A second gesture well outside the first cached title bar. Without the
        // invalidate the throttle would answer nil and this would not be ours.
        let elsewhere = CGPoint(x: 900, y: 700)
        XCTAssertTrue(tap.handle(began(), at: elsewhere))
        XCTAssertEqual(lookups, 2, "the commit dropped the cache")
    }

    /// The disabled-tool contract. A stopped tap must be structurally unable to
    /// swallow, and must not leave a preview overlay on screen.
    func testStopLeavesNothingArmed() {
        let mover = RecordingMover()
        let tap = WindowGestureTap(mover: mover, windows: makeHitResolver(calls: {}))
        tap.start()
        XCTAssertTrue(tap.isArmed)
        XCTAssertTrue(tap.handle(began(), at: barPoint))
        XCTAssertTrue(tap.handle(changed(dx: 200), at: barPoint))

        tap.stop()
        XCTAssertFalse(tap.isArmed)
        XCTAssertEqual(mover.previews.count, 2)
        XCTAssertNil(mover.previews.last ?? .snap(WindowZoneMath.maximize),
                     "the preview is taken down")
        XCTAssertTrue(mover.commits.isEmpty, "a gesture torn down mid-swipe fires nothing")

        let before = mover.previews.count
        XCTAssertFalse(tap.handle(began(), at: barPoint), "a stopped tap swallows nothing")
        XCTAssertFalse(tap.handle(changed(dx: 400), at: barPoint))
        XCTAssertFalse(tap.handle(ended, at: barPoint))
        XCTAssertFalse(tap.magnified(by: -0.9))
        XCTAssertEqual(mover.previews.count, before, "and touches nothing")
        XCTAssertTrue(mover.commits.isEmpty)
    }

    func testAnUnstartedTapPassesEverythingThrough() {
        let mover = RecordingMover()
        let tap = WindowGestureTap(mover: mover, windows: makeHitResolver(calls: {}))

        XCTAssertFalse(tap.handle(began(), at: barPoint))
        XCTAssertFalse(tap.handle(changed(dx: 400), at: barPoint))
        XCTAssertTrue(mover.commits.isEmpty)
        XCTAssertTrue(mover.previews.isEmpty)
    }

    /// The mover is held weakly, so a tap outliving its owner fails open rather
    /// than holding a swallow decision it can no longer act on.
    func testATapWhoseMoverHasGoneAwayFailsOpen() {
        var mover: RecordingMover? = RecordingMover()
        let tap = WindowGestureTap(mover: mover!, windows: makeHitResolver(calls: {}))
        tap.start()
        mover = nil

        XCTAssertFalse(tap.handle(began(), at: barPoint))
        XCTAssertFalse(tap.handle(changed(dx: 400), at: barPoint))
        XCTAssertFalse(tap.handle(ended, at: barPoint))
    }

    /// A gesture that starts over ordinary window content — the common case, and
    /// the one that would break scrolling everywhere if it were wrong.
    func testAGestureStartedOffAnyTitleBarIsInvisibleToTheApp() {
        let mover = RecordingMover()
        let tap = WindowGestureTap(mover: mover, windows: makeMissResolver())
        tap.start()

        let content = CGPoint(x: 400, y: 500)
        XCTAssertFalse(tap.handle(began(), at: content))
        XCTAssertFalse(tap.handle(changed(dx: 400), at: content))
        XCTAssertFalse(tap.handle(ended, at: content))
        XCTAssertTrue(mover.commits.isEmpty)
        XCTAssertTrue(mover.previews.isEmpty)
    }
}
