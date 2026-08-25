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

    /// Records the **pair**: an action reaching the right window matters as much
    /// as the action, so every call keeps the window it named and the cases that
    /// only care about the action read it back through `previews`/`commits`.
    private final class RecordingMover: WindowMover {
        private(set) var previewCalls: [(action: WindowAction?, window: AXUIElement?)] = []
        private(set) var commitCalls: [(action: WindowAction, window: AXUIElement?)] = []

        var previews: [WindowAction?] { previewCalls.map(\.action) }
        var commits: [WindowAction] { commitCalls.map(\.action) }

        func preview(_ action: WindowAction?, on window: AXUIElement?) {
            previewCalls.append((action, window))
        }

        func commit(_ action: WindowAction, on window: AXUIElement?) {
            commitCalls.append((action, window))
        }
    }

    /// Two windows that are genuinely different names for different windows:
    /// `AXUIElementCreateApplication` is a local call needing no live app, and
    /// two pids give two elements `CFEqual` tells apart (asserted below, so a
    /// case comparing them cannot pass vacuously).
    ///
    /// `nonisolated(unsafe)` because the spy below cannot be `@MainActor` — the
    /// policy takes a plain, non-`Sendable` closure on purpose — and these are
    /// immutable CF handles nothing ever writes.
    nonisolated(unsafe) private static let windowA = AXUIElementCreateApplication(4_242)
    nonisolated(unsafe) private static let windowB = AXUIElementCreateApplication(4_243)

    /// Counts how many times the policy asks what is under the pointer, and
    /// answers with a *named* window. `answers` is consumed in order and the last
    /// value repeats, so a case can say "on window A's bar when it began, off
    /// any bar ever after" — or "on A, then on B", which is how a gesture whose
    /// front window changes underneath it is spelled.
    private final class TitleBarSpy {
        private(set) var calls = 0
        private var answers: [AXUIElement?]

        /// The plain spelling for cases that only care whether the pointer was on
        /// *a* title bar: true means window A.
        init(_ answers: [Bool]) {
            self.answers = answers.map { $0 ? WindowGestureTapTests.windowA : nil }
        }

        init(windows: [AXUIElement?]) { answers = windows }

        func ask() -> TitleBarHit? {
            defer { calls += 1 }
            let window = answers.count > 1 ? answers.removeFirst() : (answers.first ?? nil)
            return window.map { WindowGestureTapTests.hit(on: $0) }
        }
    }

    /// A title-bar hit naming `window`. The rects are incidental here — the
    /// policy only reads the window out of it. Nonisolated for the spy above.
    nonisolated private static func hit(on window: AXUIElement) -> TitleBarHit {
        let bar = CGRect(x: 0, y: 0, width: 400, height: 28)
        return TitleBarHit(window: window, windowFrame: bar, titleBar: bar)
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

        var outcomes = [policy.handle(began(dx: 5), titleBarUnderPointer: spy.ask)]
        for _ in 0..<5 {
            outcomes.append(policy.handle(changed(dx: 60), titleBarUnderPointer: spy.ask))
        }
        outcomes.append(policy.handle(ended, titleBarUnderPointer: spy.ask))
        outcomes.append(policy.handle(coasting, titleBarUnderPointer: spy.ask))

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

        XCTAssertTrue(policy.handle(began(dx: 5), titleBarUnderPointer: spy.ask).swallow)
        for _ in 0..<5 {
            XCTAssertTrue(policy.handle(changed(dx: 40), titleBarUnderPointer: spy.ask).swallow)
        }
        XCTAssertTrue(policy.ownsGesture)

        let last = policy.handle(ended, titleBarUnderPointer: spy.ask)
        XCTAssertTrue(last.swallow)
        XCTAssertEqual(last.commit, .snap(WindowZoneMath.rightHalf))
        XCTAssertFalse(policy.ownsGesture, "the gesture is spent the moment it ends")
    }

    /// Ownership is a question asked once. Asking again per event would both cost
    /// an Accessibility round-trip per frame and let the answer change mid-swipe.
    func testOwnershipIsDecidedOncePerGesture() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])

        _ = policy.handle(began(), titleBarUnderPointer: spy.ask)
        for _ in 0..<20 { _ = policy.handle(changed(dx: 3), titleBarUnderPointer: spy.ask) }
        _ = policy.handle(ended, titleBarUnderPointer: spy.ask)
        XCTAssertEqual(spy.calls, 1, "one lookup for a whole gesture")

        _ = policy.handle(began(), titleBarUnderPointer: spy.ask)
        _ = policy.handle(ended, titleBarUnderPointer: spy.ask)
        XCTAssertEqual(spy.calls, 2, "and exactly one more for the next gesture")
    }

    /// Inertia is the window server's doing, not the user's, and it arrives with
    /// no scroll phase — so it is nobody's gesture and goes to the app.
    func testTheInertiaTailIsNotSwallowed() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])

        _ = policy.handle(began(), titleBarUnderPointer: spy.ask)
        _ = policy.handle(changed(dx: 200), titleBarUnderPointer: spy.ask)
        XCTAssertEqual(policy.handle(ended, titleBarUnderPointer: spy.ask).commit,
                       .snap(WindowZoneMath.rightHalf))

        let coast = policy.handle(coasting, titleBarUnderPointer: spy.ask)
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

        _ = policy.handle(began(), titleBarUnderPointer: spy.ask)
        _ = policy.handle(changed(dx: 200), titleBarUnderPointer: spy.ask)
        XCTAssertTrue(policy.ownsGesture)

        let coast = policy.handle(coasting, titleBarUnderPointer: spy.ask)
        XCTAssertFalse(coast.swallow)
        XCTAssertNil(coast.commit)
        XCTAssertEqual(coast.preview, .show(nil), "and the orphaned preview comes down")
        XCTAssertFalse(policy.ownsGesture)

        // The late `ended` is now nobody's, and the next gesture is unaffected.
        XCTAssertFalse(policy.handle(ended, titleBarUnderPointer: spy.ask).swallow)
        XCTAssertTrue(policy.handle(began(), titleBarUnderPointer: spy.ask).swallow)
    }

    /// A momentum frame reaching the recogniser mid-gesture must be reported *as*
    /// momentum, so it accumulates nothing: 400 points of coasting cannot
    /// manufacture a snap the user's fingers never made. The paired assertion
    /// below is what keeps this from passing vacuously.
    func testMomentumTravelIsReportedAsMomentumAndNeverFires() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])

        _ = policy.handle(began(), titleBarUnderPointer: spy.ask)
        let coast = policy.handle(changed(dx: 400, momentum: true), titleBarUnderPointer: spy.ask)
        XCTAssertEqual(coast.preview, .unchanged, "inertia is not travel, so nothing is pending")
        XCTAssertNil(policy.handle(ended, titleBarUnderPointer: spy.ask).commit)

        // The identical travel with the fingers actually down does fire.
        var real = WindowGesturePolicy()
        let realSpy = TitleBarSpy([true])
        _ = real.handle(began(), titleBarUnderPointer: realSpy.ask)
        _ = real.handle(changed(dx: 400), titleBarUnderPointer: realSpy.ask)
        XCTAssertEqual(real.handle(ended, titleBarUnderPointer: realSpy.ask).commit,
                       .snap(WindowZoneMath.rightHalf))
    }

    /// Momentum cannot *begin* a gesture either, and is cheap enough to reject
    /// that it never costs a lookup.
    func testMomentumCannotBeginAGesture() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])

        let outcome = policy.handle(began(dx: 90, momentum: true), titleBarUnderPointer: spy.ask)
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
            let outcome = policy.handle(frame, titleBarUnderPointer: spy.ask)
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

        _ = policy.handle(began(), titleBarUnderPointer: spy.ask)
        _ = policy.handle(changed(dx: 200), titleBarUnderPointer: spy.ask)
        XCTAssertFalse(
            policy.handle(ScrollFrame(phase: .other, isMomentum: false, dx: 0, dy: 0),
                          titleBarUnderPointer: spy.ask).swallow)
        XCTAssertTrue(policy.ownsGesture)
        XCTAssertEqual(policy.handle(ended, titleBarUnderPointer: spy.ask).commit,
                       .snap(WindowZoneMath.rightHalf))
    }

    // MARK: - Pinch

    /// Pinch is gated on the same ownership bit, and never swallows: it arrives
    /// through a read-only monitor, so saying otherwise would be a lie.
    func testPinchOnlyCountsInsideAnOwnedGesture() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])

        // Over ordinary content a stray pinch still does nothing: the lookup
        // says there is no title bar here, so the gesture never arms.
        let stray = policy.magnified(by: -0.8, titleBarUnderPointer: { nil })
        XCTAssertEqual(stray, WindowGesturePolicy.Outcome(), "no title bar, no effect")

        _ = policy.handle(began(), titleBarUnderPointer: spy.ask)
        let squeeze = policy.magnified(by: -0.7, titleBarUnderPointer: spy.ask)
        XCTAssertFalse(squeeze.swallow, "a monitor cannot swallow")
        XCTAssertEqual(squeeze.preview, .show(.close))
        XCTAssertEqual(policy.handle(ended, titleBarUnderPointer: spy.ask).commit, .close)
    }

    /// The bug the owner hit: pinch-to-close never fired, because ownership was
    /// only ever established from the *scroll* stream and a pinch produces no
    /// phased scroll frames. The guard was unreachable, not conservative.
    func testAPinchAloneArmsAndCommitsWithNoScrollAtAll() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])

        // No scroll frame has ever been seen.
        let squeeze = policy.magnified(by: -0.7, titleBarUnderPointer: spy.ask)
        XCTAssertTrue(policy.ownsGesture, "a pinch on a title bar owns the gesture")
        XCTAssertFalse(squeeze.swallow, "and still cannot swallow")
        XCTAssertEqual(squeeze.preview, .show(.close))

        XCTAssertEqual(policy.magnifyEnded().commit, .close, "and commits on release")
        XCTAssertFalse(policy.ownsGesture)
    }

    /// The lookup still decides. A pinch over a document arms nothing.
    func testAPinchOverContentArmsNothing() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([false])
        _ = policy.magnified(by: -0.9, titleBarUnderPointer: spy.ask)
        XCTAssertFalse(policy.ownsGesture)
        XCTAssertEqual(policy.magnifyEnded(), WindowGesturePolicy.Outcome())
    }

    /// Ownership is still decided once: a pinch that armed does not re-ask.
    func testAPinchAsksForTheTitleBarOnlyOnce() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])
        for _ in 0..<12 { _ = policy.magnified(by: -0.05, titleBarUnderPointer: spy.ask) }
        XCTAssertEqual(spy.calls, 1)
    }

    // MARK: - Preview

    /// The preview is written per input event, so an unchanged value must not be
    /// re-sent: it drives an observable and an Accessibility resolve.
    func testThePreviewIsOnlyIssuedWhenItChanges() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])

        _ = policy.handle(began(), titleBarUnderPointer: spy.ask)
        XCTAssertEqual(policy.handle(changed(dx: 200), titleBarUnderPointer: spy.ask).preview,
                       .show(.snap(WindowZoneMath.rightHalf)))
        for _ in 0..<5 {
            XCTAssertEqual(policy.handle(changed(dx: 10), titleBarUnderPointer: spy.ask).preview,
                           .unchanged, "the same zone must not be re-sent")
        }
        XCTAssertEqual(policy.handle(changed(dx: -600), titleBarUnderPointer: spy.ask).preview,
                       .show(.snap(WindowZoneMath.leftHalf)))
        XCTAssertEqual(policy.handle(ended, titleBarUnderPointer: spy.ask).preview, .show(nil),
                       "the frame that commits also hides")
    }

    func testCancellingHidesThePreviewAndFiresNothing() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy([true])

        _ = policy.handle(began(), titleBarUnderPointer: spy.ask)
        _ = policy.handle(changed(dx: 200), titleBarUnderPointer: spy.ask)
        let outcome = policy.handle(cancelled, titleBarUnderPointer: spy.ask)
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
    private func makeHitResolver(
        window: AXUIElement = windowA, calls: @escaping () -> Void
    ) -> WindowUnderPointer {
        WindowUnderPointer(
            lookup: { point in
                calls()
                let bar = CGRect(x: point.x - 20, y: point.y - 10, width: 40, height: 20)
                return .titleBar(TitleBarHit(window: window, windowFrame: bar, titleBar: bar))
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
        XCTAssertFalse(tap.magnified(by: -0.9, at: barPoint))
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

    // MARK: - Which window the action lands on

    /// The bug this shape exists for, stated directly: the window a gesture acts
    /// on is the window whose title bar it began over — never "whatever is
    /// frontmost". Nothing in this test can even ask what is frontmost, which is
    /// the point: the name travels with the gesture.
    func testAGestureNamesTheWindowItsTitleBarNamed() {
        XCTAssertFalse(CFEqual(Self.windowA, Self.windowB), "two fixtures, two windows")

        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy(windows: [Self.windowB])

        _ = policy.handle(began(), titleBarUnderPointer: spy.ask)
        XCTAssertEqual(policy.target.map(WindowKey.init), WindowKey(Self.windowB),
                       "the window is captured on the frame that takes ownership")
        _ = policy.handle(changed(dx: 200), titleBarUnderPointer: spy.ask)
        XCTAssertEqual(policy.handle(ended, titleBarUnderPointer: spy.ask).commit,
                       .snap(WindowZoneMath.rightHalf))
        XCTAssertEqual(policy.target.map(WindowKey.init), WindowKey(Self.windowB),
                       "and is still that window when the caller reads it to commit")
    }

    /// Focus moving mid-gesture cannot drag the target with it. The resolver would
    /// answer window B from the second question onward — and is never asked
    /// again, which is the mechanism.
    func testAFocusChangeMidGestureDoesNotMoveTheTarget() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy(windows: [Self.windowA, Self.windowB])

        _ = policy.handle(began(), titleBarUnderPointer: spy.ask)
        for _ in 0..<5 { _ = policy.handle(changed(dx: 60), titleBarUnderPointer: spy.ask) }
        _ = policy.handle(ended, titleBarUnderPointer: spy.ask)

        XCTAssertEqual(spy.calls, 1)
        XCTAssertEqual(policy.target.map(WindowKey.init), WindowKey(Self.windowA))
    }

    /// A gesture Pear does not own names no window at all, so there is nothing
    /// downstream for a stale target to be mistaken for.
    func testAGestureThatIsNotOursNamesNoWindow() {
        var policy = WindowGesturePolicy()
        let spy = TitleBarSpy(windows: [Self.windowA, nil])

        _ = policy.handle(began(), titleBarUnderPointer: spy.ask)
        _ = policy.handle(ended, titleBarUnderPointer: spy.ask)
        XCTAssertNotNil(policy.target)

        _ = policy.handle(began(), titleBarUnderPointer: spy.ask)
        XCTAssertNil(policy.target, "this one started over ordinary content")
    }

    /// Preview and commit must mean the same window — a preview drawn over one
    /// window while another moves is its own bug. Asserted at the tap, which is
    /// where both calls are made, from one stored target.
    func testThePreviewAndTheCommitNameTheSameWindow() {
        let mover = RecordingMover()
        let tap = WindowGestureTap(
            mover: mover, windows: makeHitResolver(window: Self.windowB, calls: {}))
        tap.start()

        XCTAssertTrue(tap.handle(began(), at: barPoint))
        XCTAssertTrue(tap.handle(changed(dx: 200), at: barPoint))
        XCTAssertTrue(tap.handle(ended, at: barPoint))

        XCTAssertEqual(mover.commits, [.snap(WindowZoneMath.rightHalf)])
        XCTAssertEqual(mover.previews, [.snap(WindowZoneMath.rightHalf), nil])
        let named = mover.previewCalls.map(\.window) + mover.commitCalls.map(\.window)
        XCTAssertEqual(named.count, 3, "two previews and the commit")
        XCTAssertTrue(named.allSatisfy { $0.map(WindowKey.init) == WindowKey(Self.windowB) },
                      "every one of them names the window the gesture began on")
    }

    /// The other half of the same contract, and the reason the window is an
    /// optional rather than required: the ⌃⌥ chords and the Fn ring have no
    /// pointer aimed at anything, so they name no window and the mover falls back
    /// to the frontmost focused one, exactly as they always have. Driven against
    /// an injected mover — no Accessibility, no ring, no real window.
    func testTheChordsAndTheRingNameNoWindowSoTheyKeepActingOnTheFocusedOne() {
        let mover = RecordingMover()
        let tool = WindowsTool(mover: mover)

        tool.snapRequested(.center)
        tool.ringHighlight(.leading)
        tool.ringClosed(commit: true)

        XCTAssertFalse(mover.commitCalls.isEmpty, "the chord and the ring both committed")
        XCTAssertFalse(mover.previewCalls.isEmpty, "and the ring previewed")
        XCTAssertTrue(mover.commitCalls.allSatisfy { $0.window == nil })
        XCTAssertTrue(mover.previewCalls.allSatisfy { $0.window == nil })
    }

    /// The gestures are a tool of their own now, with one switch — the registry's
    /// — and no second preference to find. Off by default: enabling it arms a tap
    /// that sees every scroll on the machine.
    func testTheGesturesAreTheirOwnDefaultOffTool() {
        let tool = WindowGesturesTool()
        XCTAssertEqual(tool.id, "windowgestures")
        XCTAssertFalse(tool.defaultEnabled)
        XCTAssertNil(tool.hotkey, "there is nothing to fire: it is either watching or not")
        XCTAssertFalse(tool.survivesExpiry)
        XCTAssertFalse(tool.summary.isEmpty, "it stands on its own in the help sheet")
    }
}
