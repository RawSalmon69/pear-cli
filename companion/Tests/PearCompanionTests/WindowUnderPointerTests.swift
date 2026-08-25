import ApplicationServices
import CoreGraphics
import XCTest

@testable import PearCompanion

/// A recording stand-in for the Accessibility hit test, and a clock that only
/// moves when a test moves it.
///
/// The real lookup needs a live session, an attached display and Accessibility
/// permission, and driving it would fight the developer's own windows. What
/// actually has to be right here is the cache — how many times the expensive
/// call is made, and when — so the expensive call is injected and counted, and
/// time is a variable rather than a wait.
@MainActor
private final class ProbeSpy {
    private(set) var calls = 0
    private(set) var points: [CGPoint] = []
    var answer: @MainActor (CGPoint) -> WindowUnderPointer.Probe = { _ in .nothing }

    func look(at point: CGPoint) -> WindowUnderPointer.Probe {
        calls += 1
        points.append(point)
        return answer(point)
    }
}

@MainActor
private final class TestClock {
    var now: CFAbsoluteTime = 1_000
    func advance(_ seconds: CFTimeInterval) { now += seconds }
}

@MainActor
final class WindowUnderPointerTests: XCTestCase {
    /// A stand-in window element. Creating one is a local call — it never
    /// messages another process — and nothing in these tests reads through it.
    private let element = AXUIElementCreateSystemWide()

    /// An 800×600 window at (100, 200) with a 28pt bar, y-down throughout.
    private let windowFrame = CGRect(x: 100, y: 200, width: 800, height: 600)
    private var titleBarRect: CGRect { CGRect(x: 100, y: 200, width: 800, height: 28) }
    private var bodyRect: CGRect { CGRect(x: 100, y: 228, width: 800, height: 572) }

    private var hit: TitleBarHit {
        TitleBarHit(window: element, windowFrame: windowFrame, titleBar: titleBarRect)
    }

    private let spy = ProbeSpy()
    private let clock = TestClock()

    private func makeResolver() -> WindowUnderPointer {
        WindowUnderPointer(lookup: { [spy] in spy.look(at: $0) }, clock: { [clock] in clock.now })
    }

    // MARK: - The cache: hits

    /// The common case during a gesture: the pointer is resting inside a title
    /// bar and every scroll event asks again. It must cost nothing.
    func testAPointInsideTheCachedTitleBarCostsNoLookup() {
        spy.answer = { [hit] _ in .titleBar(hit) }
        let resolver = makeResolver()

        XCTAssertEqual(resolver.hit(at: CGPoint(x: 200, y: 210)), hit)
        XCTAssertEqual(spy.calls, 1)

        for x in stride(from: 110.0, to: 890.0, by: 7) {
            XCTAssertEqual(resolver.hit(at: CGPoint(x: x, y: 214)), hit)
        }
        XCTAssertEqual(spy.calls, 1, "a pointer inside the cached title bar must never ask again")
    }

    func testAPointOutsideTheCachedTitleBarCostsAtMostOneLookup() {
        spy.answer = { [hit, bodyRect] point in
            titleBarRectContains(point) ? .titleBar(hit) : .body(bodyRect)
        }
        let resolver = makeResolver()

        XCTAssertNotNil(resolver.hit(at: CGPoint(x: 200, y: 210)))
        XCTAssertEqual(spy.calls, 1)

        clock.advance(0.2)
        XCTAssertNil(resolver.hit(at: CGPoint(x: 200, y: 400)))
        XCTAssertEqual(spy.calls, 2, "leaving the cached title bar costs exactly one lookup")
    }

    // MARK: - The cache: misses

    /// Dragging the pointer across a document must not fire a lookup per event.
    /// A `.body` probe hands back the whole window below its title bar, so the
    /// entire document is one remembered region.
    func testScrollingOverContentDoesNotLookUpPerEvent() {
        spy.answer = { [bodyRect] _ in .body(bodyRect) }
        let resolver = makeResolver()

        for y in stride(from: 240.0, to: 780.0, by: 3) {
            for x in stride(from: 110.0, to: 890.0, by: 37) {
                XCTAssertNil(resolver.hit(at: CGPoint(x: x, y: y)))
            }
        }
        XCTAssertEqual(spy.calls, 1, "one lookup for the whole document")
    }

    /// A blank answer carries no geometry, so a small square around the point
    /// stands in for it — enough that a still pointer over the desktop, or a
    /// build with Accessibility denied, does not probe on every event.
    func testABlankAnswerIsAlsoRemembered() {
        spy.answer = { _ in .nothing }
        let resolver = makeResolver()

        for _ in 0..<50 {
            XCTAssertNil(resolver.hit(at: CGPoint(x: 400, y: 400)))
        }
        XCTAssertEqual(spy.calls, 1)

        // Just outside the remembered square, and past the lookup floor.
        clock.advance(0.2)
        let clear = CGPoint(x: 400, y: 400 + WindowUnderPointer.blindMissRadius + 1)
        XCTAssertNil(resolver.hit(at: clear))
        XCTAssertEqual(spy.calls, 2)
    }

    /// Accessibility denied is exactly the blank answer: nil out, no stale hit,
    /// no prompt, the scroll passes through untouched.
    func testANilLookupYieldsNilRatherThanAStaleHit() {
        spy.answer = { [hit] _ in .titleBar(hit) }
        let resolver = makeResolver()
        XCTAssertEqual(resolver.hit(at: CGPoint(x: 200, y: 210)), hit)

        spy.answer = { _ in .nothing }
        resolver.invalidate()
        XCTAssertNil(resolver.hit(at: CGPoint(x: 200, y: 210)))
        XCTAssertEqual(spy.calls, 2)
    }

    /// One cache slot, not two: a miss replaces the remembered title bar rather
    /// than sitting beside it. Otherwise a window covering another's title bar
    /// would keep answering for the window underneath.
    func testAMissReplacesTheCachedHit() {
        spy.answer = { [hit] _ in .titleBar(hit) }
        let resolver = makeResolver()
        XCTAssertNotNil(resolver.hit(at: CGPoint(x: 200, y: 210)))

        // Another window's body now covers the same region.
        let covering = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        spy.answer = { _ in .body(covering) }
        clock.advance(0.2)
        XCTAssertNil(resolver.hit(at: CGPoint(x: 200, y: 400)))

        // The old title bar must not answer from inside the covering window.
        XCTAssertNil(resolver.hit(at: CGPoint(x: 200, y: 210)))
        XCTAssertEqual(spy.calls, 2)
    }

    // MARK: - Invalidation

    func testInvalidateForcesAFreshLookup() {
        spy.answer = { [hit] _ in .titleBar(hit) }
        let resolver = makeResolver()
        let point = CGPoint(x: 200, y: 210)

        XCTAssertNotNil(resolver.hit(at: point))
        XCTAssertNotNil(resolver.hit(at: point))
        XCTAssertEqual(spy.calls, 1)

        resolver.invalidate()
        XCTAssertNotNil(resolver.hit(at: point))
        XCTAssertEqual(spy.calls, 2, "invalidate must force the next query to look again")
    }

    /// `invalidate` also clears the floor between lookups, or the desk changing
    /// would be ignored for up to a tenth of a second.
    func testInvalidateBeatsTheLookupFloor() {
        spy.answer = { _ in .nothing }
        let resolver = makeResolver()

        XCTAssertNil(resolver.hit(at: CGPoint(x: 400, y: 400)))
        XCTAssertEqual(spy.calls, 1)

        resolver.invalidate()
        XCTAssertNil(resolver.hit(at: CGPoint(x: 400, y: 400)))
        XCTAssertEqual(spy.calls, 2)
    }

    // MARK: - The floor and the lifetime

    /// A pointer moving through ground nothing can describe still cannot make
    /// more than one lookup per `minimumLookupInterval`.
    func testLookupsAreRateLimited() {
        spy.answer = { _ in .nothing }
        let resolver = makeResolver()

        // 40 points, each well clear of the last remembered square, 10ms apart.
        for step in 0..<40 {
            clock.advance(0.01)
            _ = resolver.hit(at: CGPoint(x: 100 + Double(step) * 50, y: 400))
        }
        XCTAssertEqual(spy.calls, 4, "400ms of motion is at most four probes")
    }

    /// A cache entry only survives while it is being asked about. A gesture
    /// queries every few milliseconds so nothing expires mid-gesture; a window
    /// dragged by hand between gestures never answers from the old rect.
    func testTheCacheExpiresOnceTheGestureStops() {
        spy.answer = { [hit] _ in .titleBar(hit) }
        let resolver = makeResolver()
        let point = CGPoint(x: 200, y: 210)

        XCTAssertNotNil(resolver.hit(at: point))
        for _ in 0..<20 {
            clock.advance(0.016)
            XCTAssertNotNil(resolver.hit(at: point))
        }
        XCTAssertEqual(spy.calls, 1, "a continuous stream keeps the cache alive")

        clock.advance(WindowUnderPointer.cacheLifetime + 0.01)
        XCTAssertNotNil(resolver.hit(at: point))
        XCTAssertEqual(spy.calls, 2, "an idle gap drops it")
    }

    // MARK: - Deriving the title-bar rectangle

    /// The anchor sits centred in the bar, so the bar is twice the drop from the
    /// window's top edge to the anchor's centre: a close button at y 208…220 in
    /// a window starting at y 200 means a 28pt bar.
    func testTheBarIsMeasuredFromTheAnchorsCentre() {
        let anchor = CGRect(x: 112, y: 208, width: 12, height: 12)
        let bar = WindowUnderPointer.titleBar(of: windowFrame, anchor: anchor, fallbackHeight: 99)
        XCTAssertEqual(bar, titleBarRect)
    }

    /// A unified toolbar is taller and its traffic lights sit lower; the same
    /// measurement follows it without a special case.
    func testATallerToolbarIsMeasuredJustAsWell() {
        let anchor = CGRect(x: 112, y: 220, width: 12, height: 12)
        let bar = WindowUnderPointer.titleBar(of: windowFrame, anchor: anchor, fallbackHeight: 28)
        XCTAssertEqual(bar.height, 52)
    }

    func testTheBarSpansTheWindowsFullWidth() {
        let anchor = CGRect(x: 112, y: 208, width: 12, height: 12)
        let bar = WindowUnderPointer.titleBar(of: windowFrame, anchor: anchor, fallbackHeight: 28)
        XCTAssertEqual(bar.minX, windowFrame.minX)
        XCTAssertEqual(bar.width, windowFrame.width)
        XCTAssertEqual(bar.minY, windowFrame.minY)
    }

    func testNoAnchorFallsBackToTheGivenHeight() {
        let bar = WindowUnderPointer.titleBar(of: windowFrame, anchor: nil, fallbackHeight: 28)
        XCTAssertEqual(bar, titleBarRect)
    }

    /// An anchor that measures out to something no title bar could be is an app
    /// putting that element somewhere else entirely. Trusting it would either
    /// eat a document or describe a sliver, so it is discarded.
    func testAnImplausibleMeasurementIsDiscarded() {
        let farTooTall = CGRect(x: 112, y: 500, width: 12, height: 12)
        XCTAssertEqual(
            WindowUnderPointer.titleBar(of: windowFrame, anchor: farTooTall, fallbackHeight: 28)
                .height, 28)

        let farTooShort = CGRect(x: 112, y: 201, width: 2, height: 2)
        XCTAssertEqual(
            WindowUnderPointer.titleBar(of: windowFrame, anchor: farTooShort, fallbackHeight: 28)
                .height, 28)
    }

    /// A window shorter than a title bar cannot have a title bar taller than
    /// itself, and a `.body` under it must not have negative height.
    func testABarNeverOutgrowsItsWindow() {
        let sliver = CGRect(x: 0, y: 0, width: 400, height: 10)
        let bar = WindowUnderPointer.titleBar(of: sliver, anchor: nil, fallbackHeight: 28)
        XCTAssertEqual(bar.height, 10)
        XCTAssertEqual(WindowUnderPointer.body(of: sliver, below: bar).height, 0)
    }

    func testTheBodyIsTheWindowBelowTheBar() {
        XCTAssertEqual(WindowUnderPointer.body(of: windowFrame, below: titleBarRect), bodyRect)
    }

    /// The fallback is asked of AppKit rather than hardcoded, so it tracks the
    /// OS; it still has to be a title bar and not, say, zero.
    func testTheSystemFallbackIsPlausible() {
        XCTAssertTrue(
            WindowUnderPointer.plausibleHeights.contains(WindowUnderPointer.systemTitleBarHeight),
            "\(WindowUnderPointer.systemTitleBarHeight)")
    }
}

/// The fixture's title bar, as a free function so closures can use it without
/// capturing the test case.
@MainActor private func titleBarRectContains(_ point: CGPoint) -> Bool {
    CGRect(x: 100, y: 200, width: 800, height: 28).contains(point)
}
