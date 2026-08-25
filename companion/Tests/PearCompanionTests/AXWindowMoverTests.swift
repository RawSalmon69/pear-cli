import ApplicationServices
import CoreGraphics
import SwiftUI
import XCTest
@testable import PearCompanion

/// The coordinate transform and the screen choice, against fabricated display
/// arrangements. No display is attached to a build machine and none is needed:
/// `WindowSpace` takes the arrangement as plain rects precisely so the geometry
/// that only misbehaves on a multi-display desk is testable at exact pixels.
final class WindowSpaceTests: XCTestCase {
    /// A 1440×900 laptop as the **primary** — AppKit anchors its global space to
    /// this display's bottom-left — with a 25pt menu bar.
    private let primary = (
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visible: CGRect(x: 0, y: 0, width: 1440, height: 875))

    /// A 1920×1080 display stacked directly **above** the primary. Above means a
    /// higher AppKit y, because AppKit's y grows upward, so its frame sits at
    /// y = 900 — and in y-down space it lands on *negative* y. This is the
    /// arrangement that breaks code which flips against the wrong height.
    private let above = (
        frame: CGRect(x: 0, y: 900, width: 1920, height: 1080),
        visible: CGRect(x: 0, y: 900, width: 1920, height: 1055))

    /// The same display **below** the primary: its bottom edge is a full 1080
    /// under the origin, so AppKit y is negative and y-down space puts it past
    /// the primary's height. The mirror image of the case above, and the other
    /// half of what a single-display machine never exercises.
    private let below = (
        frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
        visible: CGRect(x: 0, y: -1080, width: 1920, height: 1055))

    /// Every flip on this desk pivots on the primary's height.
    private let pivot: CGFloat = 900

    // MARK: - The transform

    func testFlipIsItsOwnInverse() {
        let rects = [
            primary.frame, primary.visible, above.frame, above.visible,
            below.frame, below.visible,
            CGRect(x: -37.5, y: 12.25, width: 640.75, height: 480.5),
        ]
        for rect in rects {
            for pivot in [CGFloat(0), 900, 1080, 2234.5] {
                let there = WindowSpace.flip(rect, primaryHeight: pivot)
                XCTAssertEqual(
                    WindowSpace.flip(there, primaryHeight: pivot), rect, "\(rect) @ \(pivot)")
            }
        }
    }

    func testFlipTouchesOnlyTheYOrigin() {
        let rect = CGRect(x: -120, y: 340, width: 800, height: 600)
        let flipped = WindowSpace.flip(rect, primaryHeight: pivot)
        XCTAssertEqual(flipped.minX, rect.minX)
        XCTAssertEqual(flipped.size, rect.size)
    }

    func testThePrimaryDisplayIsUnchangedByTheFlip() {
        // Both spaces are anchored to this display's own corners, so its full
        // frame is the one rect that reads the same in either.
        XCTAssertEqual(WindowSpace.flip(primary.frame, primaryHeight: pivot), primary.frame)
    }

    func testTheMenuBarInsetMovesToTheTopInYDownSpace() {
        // AppKit trims the menu bar off visibleFrame's *height*, leaving its
        // origin at the bottom. In y-down space that same inset has to appear at
        // the top, as a y of 25.
        XCTAssertEqual(
            WindowSpace.flip(primary.visible, primaryHeight: pivot),
            CGRect(x: 0, y: 25, width: 1440, height: 875))
    }

    func testADisplayAbovethePrimaryFlipsToNegativeY() {
        let flipped = WindowSpace.flip(above.frame, primaryHeight: pivot)
        XCTAssertEqual(flipped, CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        // It occupies y-down -1080...0: directly above the primary, which starts
        // at 0. Pivoting on this display's *own* height instead — the natural
        // mistake, and correct-looking on a single-display Mac — would put it at
        // y = -900 and overlap the primary by 180 points.
        XCTAssertEqual(flipped.maxY, 0)
        XCTAssertNotEqual(flipped, CGRect(x: 0, y: -900, width: 1920, height: 1080))
    }

    func testADisplayAbovethePrimaryKeepsItsMenuBarAtItsOwnTop() {
        XCTAssertEqual(
            WindowSpace.flip(above.visible, primaryHeight: pivot),
            CGRect(x: 0, y: -1055, width: 1920, height: 1055))
    }

    func testADisplayBelowThePrimaryFlipsPastThePrimaryHeight() {
        let flipped = WindowSpace.flip(below.frame, primaryHeight: pivot)
        XCTAssertEqual(flipped, CGRect(x: 0, y: 900, width: 1920, height: 1080))
        XCTAssertEqual(flipped.minY, primary.frame.height)
        // Its menu bar is the 25 points immediately under the primary.
        XCTAssertEqual(
            WindowSpace.flip(below.visible, primaryHeight: pivot),
            CGRect(x: 0, y: 925, width: 1920, height: 1055))
    }

    // MARK: - The pivot

    func testThePivotIsTheDisplayAtTheOriginNotTheFirstListed() {
        XCTAssertEqual(WindowSpace.primaryHeight(of: [above.frame, primary.frame]), 900)
        XCTAssertEqual(WindowSpace.primaryHeight(of: [primary.frame, above.frame]), 900)
        XCTAssertEqual(WindowSpace.primaryHeight(of: [below.frame, primary.frame]), 900)
    }

    func testThePivotFallsBackToTheFirstDisplayWhenNoneSitsAtTheOrigin() {
        XCTAssertEqual(WindowSpace.primaryHeight(of: [above.frame]), 1080)
    }

    func testThePivotOfAnEmptyArrangementIsZero() {
        XCTAssertEqual(WindowSpace.primaryHeight(of: []), 0)
    }

    // MARK: - Screen choice

    /// The two displays in y-down space, primary first: 0...900 is the primary,
    /// -1080...0 is the display above it.
    private var stackedDown: [CGRect] {
        [primary.frame, above.frame].map { WindowSpace.flip($0, primaryHeight: pivot) }
    }

    func testAWindowGoesToTheDisplayItSitsOn() {
        XCTAssertEqual(
            WindowSpace.indexOfScreen(
                holding: CGRect(x: 100, y: -900, width: 800, height: 600), in: stackedDown), 1)
        XCTAssertEqual(
            WindowSpace.indexOfScreen(
                holding: CGRect(x: 100, y: 100, width: 400, height: 300), in: stackedDown), 0)
    }

    func testAStraddlingWindowGoesToWhicheverDisplayHoldsMoreOfIt() {
        // 400 of its 500 points of height are above the y = 0 boundary.
        XCTAssertEqual(
            WindowSpace.indexOfScreen(
                holding: CGRect(x: 0, y: -400, width: 1000, height: 500), in: stackedDown), 1)
        // And now only 100 of them are.
        XCTAssertEqual(
            WindowSpace.indexOfScreen(
                holding: CGRect(x: 0, y: -100, width: 1000, height: 500), in: stackedDown), 0)
    }

    func testAnExactTieGoesToTheEarlierDisplay() {
        // 250 points on each side of the boundary: the answer has to be stable
        // rather than a function of enumeration order.
        XCTAssertEqual(
            WindowSpace.indexOfScreen(
                holding: CGRect(x: 0, y: -250, width: 1000, height: 500), in: stackedDown), 0)
    }

    func testAWindowOnNoDisplayChoosesNothing() {
        XCTAssertNil(
            WindowSpace.indexOfScreen(
                holding: CGRect(x: 5000, y: 5000, width: 100, height: 100), in: stackedDown))
    }

    func testAWindowWithNoAreaChoosesNothing() {
        // A zero-width window technically intersects, but nothing is "more of
        // it" than anything else, so there is no display to prefer.
        XCTAssertNil(
            WindowSpace.indexOfScreen(
                holding: CGRect(x: 100, y: 100, width: 0, height: 300), in: stackedDown))
    }

    func testChoosingFromNoDisplaysAtAll() {
        XCTAssertNil(
            WindowSpace.indexOfScreen(holding: primary.frame, in: []))
    }

    // MARK: - Flip and choose together

    func testTheVisibleFrameOfTheDisplayAWindowIsOn() {
        XCTAssertEqual(
            WindowSpace.visibleFrame(
                holding: CGRect(x: 100, y: -900, width: 800, height: 600),
                in: [primary, above], fallback: 0),
            CGRect(x: 0, y: -1055, width: 1920, height: 1055))
        XCTAssertEqual(
            WindowSpace.visibleFrame(
                holding: CGRect(x: 100, y: 100, width: 400, height: 300),
                in: [primary, above], fallback: 0),
            CGRect(x: 0, y: 25, width: 1440, height: 875))
    }

    func testAWindowOnNoDisplayFallsBackToTheGivenOne() {
        let stranded = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        XCTAssertEqual(
            WindowSpace.visibleFrame(holding: stranded, in: [primary, above], fallback: 1),
            CGRect(x: 0, y: -1055, width: 1920, height: 1055))
        XCTAssertEqual(
            WindowSpace.visibleFrame(holding: stranded, in: [primary, above], fallback: 0),
            CGRect(x: 0, y: 25, width: 1440, height: 875))
    }

    func testNoVisibleFrameWithoutDisplays() {
        XCTAssertNil(WindowSpace.visibleFrame(holding: primary.frame, in: [], fallback: 0))
    }

    func testAnOutOfRangeFallbackYieldsNothingRatherThanCrashing() {
        XCTAssertNil(
            WindowSpace.visibleFrame(
                holding: CGRect(x: 5000, y: 5000, width: 100, height: 100),
                in: [primary, above], fallback: 7))
    }

    // MARK: - The whole path, end to end

    /// The test that catches a wrong flip: a window on the display *above* the
    /// primary, snapped to the left half, has to stay up there. Get the pivot
    /// wrong and the target frame slides down onto the primary — which is
    /// invisible on a one-display machine and the first thing a two-display user
    /// reports.
    func testSnappingAWindowOnTheDisplayAbovethePrimaryStaysOnThatDisplay() throws {
        let window = CGRect(x: 100, y: -900, width: 800, height: 600)
        let visible = try XCTUnwrap(
            WindowSpace.visibleFrame(holding: window, in: [primary, above], fallback: 0))
        let snapped = try XCTUnwrap(
            WindowZoneMath.frame(
                for: .snap(WindowZoneMath.leftHalf), in: visible, current: window, lastFrame: nil))

        XCTAssertEqual(snapped, CGRect(x: 0, y: -1055, width: 960, height: 1055))

        let aboveDown = WindowSpace.flip(above.frame, primaryHeight: pivot)
        let primaryDown = WindowSpace.flip(primary.frame, primaryHeight: pivot)
        XCTAssertTrue(aboveDown.contains(snapped), "\(snapped) left \(aboveDown)")
        XCTAssertLessThanOrEqual(snapped.maxY, primaryDown.minY, "leaked onto the primary")

        // And back out to AppKit space, where the panel that previews it lives.
        let appKit = WindowSpace.flip(snapped, primaryHeight: pivot)
        XCTAssertEqual(appKit, CGRect(x: 0, y: 900, width: 960, height: 1055))
        XCTAssertTrue(above.frame.contains(appKit), "\(appKit) left \(above.frame)")
    }

    /// The mirror case: a display below the primary, where y-down coordinates run
    /// past the pivot instead of under zero.
    func testSnappingAWindowOnTheDisplayBelowThePrimaryStaysOnThatDisplay() throws {
        let window = CGRect(x: 100, y: 1200, width: 800, height: 600)
        let visible = try XCTUnwrap(
            WindowSpace.visibleFrame(holding: window, in: [primary, below], fallback: 0))
        XCTAssertEqual(visible, CGRect(x: 0, y: 925, width: 1920, height: 1055))

        let snapped = try XCTUnwrap(
            WindowZoneMath.frame(
                for: .snap(WindowZoneMath.rightHalf), in: visible, current: window, lastFrame: nil))
        XCTAssertEqual(snapped, CGRect(x: 960, y: 925, width: 960, height: 1055))

        let belowDown = WindowSpace.flip(below.frame, primaryHeight: pivot)
        XCTAssertTrue(belowDown.contains(snapped), "\(snapped) left \(belowDown)")
        XCTAssertGreaterThanOrEqual(snapped.minY, primary.frame.height, "leaked onto the primary")

        let appKit = WindowSpace.flip(snapped, primaryHeight: pivot)
        XCTAssertEqual(appKit, CGRect(x: 960, y: -1080, width: 960, height: 1055))
        XCTAssertTrue(below.frame.contains(appKit), "\(appKit) left \(below.frame)")
    }

    /// Complementary zones still have to tile after a round trip through both
    /// spaces, on the display that is not the primary.
    func testHalvesStillTileOnTheDisplayAbovethePrimary() throws {
        let window = CGRect(x: 100, y: -900, width: 800, height: 600)
        let visible = try XCTUnwrap(
            WindowSpace.visibleFrame(holding: window, in: [primary, above], fallback: 0))
        let left = try XCTUnwrap(
            WindowZoneMath.frame(
                for: .snap(WindowZoneMath.leftHalf), in: visible, current: window, lastFrame: nil))
        let right = try XCTUnwrap(
            WindowZoneMath.frame(
                for: .snap(WindowZoneMath.rightHalf), in: visible, current: window, lastFrame: nil))

        let leftUp = WindowSpace.flip(left, primaryHeight: pivot)
        let rightUp = WindowSpace.flip(right, primaryHeight: pivot)
        XCTAssertEqual(leftUp.maxX, rightUp.minX, "a seam appeared between the halves")
        XCTAssertEqual(leftUp.minY, rightUp.minY)
        XCTAssertEqual(leftUp.height, rightUp.height)
        XCTAssertEqual(leftUp.width + rightUp.width, above.visible.width)
    }
}

/// Per-window restore bookkeeping.
///
/// The keys are real `AXUIElement`s: `AXUIElementCreateApplication` hands back a
/// handle for any pid without permission and without messaging anything, and the
/// memory only ever uses a key *as* a key — it never reads through it. So the
/// identity semantics under test here are the ones that ship.
final class RestoreMemoryTests: XCTestCase {
    private func key(_ pid: pid_t) -> WindowKey { WindowKey(AXUIElementCreateApplication(pid)) }

    private let frameA = CGRect(x: 10, y: 20, width: 300, height: 200)
    private let frameB = CGRect(x: 400, y: 500, width: 640, height: 480)

    // MARK: - Key identity

    func testTwoElementsNamingTheSameTargetAreOneKey() {
        // The reference itself cannot be the key — these are distinct objects —
        // which is exactly why WindowKey compares with CFEqual.
        XCTAssertFalse(
            AXUIElementCreateApplication(501) === AXUIElementCreateApplication(501))
        XCTAssertEqual(key(501), key(501))
        XCTAssertEqual(key(501).hashValue, key(501).hashValue)
        XCTAssertNotEqual(key(501), key(502))
    }

    func testDistinctWindowsDoNotShareOneMemory() {
        var memory = RestoreMemory()
        memory.rememberFirst(frameA, for: key(1))
        memory.rememberFirst(frameB, for: key(2))
        XCTAssertEqual(memory.frame(for: key(1)), frameA)
        XCTAssertEqual(memory.frame(for: key(2)), frameB)
    }

    func testAWindowWithNothingRememberedHasNoFrame() {
        let memory = RestoreMemory()
        XCTAssertNil(memory.frame(for: key(1)))
    }

    // MARK: - First frame wins

    func testTheFrameFromBeforeTheFirstMoveIsTheOneKept() {
        // Restore is an undo of the whole run of snapping, so a second and third
        // snap must not overwrite the frame the window started from.
        var memory = RestoreMemory()
        memory.rememberFirst(frameA, for: key(1))
        memory.rememberFirst(frameB, for: key(1))
        memory.rememberFirst(CGRect(x: 1, y: 1, width: 2, height: 2), for: key(1))
        XCTAssertEqual(memory.frame(for: key(1)), frameA)
        XCTAssertEqual(memory.count, 1)
    }

    func testForgettingLetsTheNextMoveRecordAfresh() {
        var memory = RestoreMemory()
        memory.rememberFirst(frameA, for: key(1))
        memory.forget(key(1))
        XCTAssertNil(memory.frame(for: key(1)))
        memory.rememberFirst(frameB, for: key(1))
        XCTAssertEqual(memory.frame(for: key(1)), frameB)
    }

    func testForgettingAWindowThatWasNeverMovedIsHarmless() {
        var memory = RestoreMemory()
        memory.rememberFirst(frameA, for: key(1))
        memory.forget(key(99))
        XCTAssertEqual(memory.frame(for: key(1)), frameA)
        XCTAssertEqual(memory.count, 1)
    }

    // MARK: - Bounded

    func testTheMemoryNeverGrowsPastItsCapacity() {
        var memory = RestoreMemory()
        for pid in 1...(RestoreMemory.capacity + 40) {
            memory.rememberFirst(frameA, for: key(pid_t(pid)))
        }
        XCTAssertEqual(memory.count, RestoreMemory.capacity)
    }

    func testTheOldestWindowIsTheOneEvicted() {
        var memory = RestoreMemory()
        for pid in 1...RestoreMemory.capacity {
            memory.rememberFirst(frameA, for: key(pid_t(pid)))
        }
        XCTAssertEqual(memory.count, RestoreMemory.capacity)

        let newcomer = pid_t(RestoreMemory.capacity + 1)
        memory.rememberFirst(frameB, for: key(newcomer))
        XCTAssertNil(memory.frame(for: key(1)), "the oldest entry should have gone")
        XCTAssertEqual(memory.frame(for: key(2)), frameA, "the second oldest should have stayed")
        XCTAssertEqual(memory.frame(for: key(newcomer)), frameB)
        XCTAssertEqual(memory.count, RestoreMemory.capacity)
    }

    func testForgettingFreesTheSlotItHeld() {
        // Eviction order is tracked alongside the dictionary; a forget that left
        // a stale entry in that order would evict the wrong window later.
        var memory = RestoreMemory()
        for pid in 1...RestoreMemory.capacity {
            memory.rememberFirst(frameA, for: key(pid_t(pid)))
        }
        memory.forget(key(1))
        memory.rememberFirst(frameB, for: key(pid_t(RestoreMemory.capacity + 1)))
        XCTAssertEqual(memory.frame(for: key(2)), frameA, "eviction skipped past the freed slot")
        XCTAssertEqual(memory.count, RestoreMemory.capacity)
    }
}

/// What the gesture preview says, and how alarming it looks.
///
/// The overlay itself is deliberately absent: showing it would put a panel on a
/// display, and interactive overlay smoke is the owner's job (`AGENTS.md`).
/// Everything that decides *what* it shows is a plain value, and that is what is
/// pinned here — the words per action, the escalation from a snap to a quit, and
/// the one-slot cache that keeps a held gesture from re-measuring text at
/// scroll-event rate.
@MainActor
final class WindowPreviewTests: XCTestCase {
    /// Every action the engine has, snaps included — the vocabulary
    /// `WindowAction` closes over. The switches in `WindowPreviewTone` and
    /// `AXWindowMover.previewRect` are exhaustive, so a new case fails the
    /// *build* rather than slipping past this list; the count is asserted anyway,
    /// so a case added and left out of the list is still noticed.
    private let actions: [WindowAction] =
        WindowZoneMath.zones.map(WindowAction.snap)
        + [.center, .restore, .minimize, .close, .quitApp]

    // MARK: - The words

    func testEveryActionSaysSomething() {
        // The whole point of the caption: before it existed, minimise, close and
        // quit drew nothing whatsoever.
        for action in actions {
            XCTAssertFalse(
                WindowPreviewStyle(action).label.isEmpty, "\(action) previews with no label")
        }
        XCTAssertEqual(actions.count, WindowZoneMath.zones.count + 5)
    }

    func testTheWordsComeFromTheRingsOwnTable() {
        // One table, so a gesture and the ring cannot word the same action
        // differently — and a new action gets its word in `RingLabel` or nowhere.
        for action in actions {
            XCTAssertEqual(
                WindowPreviewStyle(action).label, RingLabel.text(for: action), "\(action)")
        }
    }

    func testASnapIsCaptionedWithItsZoneName() {
        XCTAssertEqual(WindowPreviewStyle(.snap(WindowZoneMath.leftHalf)).label, "Left Half")
        XCTAssertEqual(WindowPreviewStyle(.snap(WindowZoneMath.topRightQuarter)).label, "Top Right")
        XCTAssertEqual(WindowPreviewStyle(.minimize).label, "Minimize")
        XCTAssertEqual(WindowPreviewStyle(.close).label, "Close")
        XCTAssertEqual(WindowPreviewStyle(.quitApp).label, "Quit App")
    }

    // MARK: - Tone

    func testADestructiveActionNeverLooksLikeASnap() {
        for zone in WindowZoneMath.zones {
            XCTAssertEqual(WindowPreviewTone(.snap(zone)), .benign, zone.id)
        }
        XCTAssertEqual(WindowPreviewTone(.center), .benign)
        XCTAssertEqual(WindowPreviewTone(.restore), .benign)
        // Minimising is one Dock click from undone, so it is not a warning.
        XCTAssertEqual(WindowPreviewTone(.minimize), .benign)

        XCTAssertNotEqual(WindowPreviewTone(.close), .benign)
        XCTAssertNotEqual(WindowPreviewTone(.quitApp), .benign)
    }

    func testQuittingReadsAsMoreSeriousThanClosing() {
        XCTAssertNotEqual(WindowPreviewTone(.quitApp), WindowPreviewTone(.close))

        // Colour is the obvious half and cannot carry it alone: the accent is
        // user-chosen and one of the presets is amber. Weight escalates with it.
        let steps: [WindowPreviewTone] = [.benign, .caution, .danger]
        for (quieter, louder) in zip(steps, steps.dropFirst()) {
            XCTAssertLessThan(quieter.washAlpha, louder.washAlpha, "\(quieter) vs \(louder)")
            XCTAssertLessThan(quieter.borderWidth, louder.borderWidth, "\(quieter) vs \(louder)")
        }
    }

    func testAWarningKeepsItsColourWhateverTheAccentIs() {
        let previous = ThemeStore.shared.custom
        defer { ThemeStore.shared.custom = previous }

        // The accent set to the caution amber itself: the worst case, where
        // colour stops distinguishing a snap from a close and only the heavier
        // wash and border do.
        ThemeStore.shared.custom = Theme.warn
        XCTAssertEqual(WindowPreviewTone.benign.tint, Theme.warn, "benign follows the accent")
        XCTAssertEqual(WindowPreviewTone.caution.tint, Theme.warn)
        XCTAssertEqual(WindowPreviewTone.danger.tint, Theme.danger)
        XCTAssertNotEqual(WindowPreviewTone.danger.tint, WindowPreviewTone.caution.tint)
    }

    // MARK: - Redraw only on a change

    func testAnUnchangedActionIsNotRedrawn() {
        // `preview` is called once per scroll event. A gesture held on one zone
        // used to be free and has to stay free: one accepted look for the whole
        // run, however many frames it takes.
        var cache = WindowPreviewLookCache()
        let look = WindowPreviewLook(WindowPreviewStyle(.snap(WindowZoneMath.leftHalf)))
        var redraws = 0
        for _ in 0..<200 where cache.accept(look) { redraws += 1 }
        XCTAssertEqual(redraws, 1)
    }

    func testADifferentActionIsRedrawnEvenWhenItLooksSimilar() {
        var cache = WindowPreviewLookCache()
        // Two benign snaps: same tone, same colours, different words. The caption
        // is the only difference, and skipping it would leave the previous zone's
        // name on screen.
        let left = WindowPreviewLook(WindowPreviewStyle(.snap(WindowZoneMath.leftHalf)))
        let right = WindowPreviewLook(WindowPreviewStyle(.snap(WindowZoneMath.rightHalf)))
        XCTAssertTrue(cache.accept(left))
        XCTAssertTrue(cache.accept(right))
        XCTAssertTrue(cache.accept(WindowPreviewLook(WindowPreviewStyle(.close))))
        XCTAssertFalse(cache.accept(WindowPreviewLook(WindowPreviewStyle(.close))))
        // One slot, so coming back is a change like any other.
        XCTAssertTrue(cache.accept(left))
    }

    func testANewAccentRedrawsMidGesture() {
        let previous = ThemeStore.shared.custom
        defer { ThemeStore.shared.custom = previous }

        var cache = WindowPreviewLookCache()
        let style = WindowPreviewStyle(.snap(WindowZoneMath.maximize))
        ThemeStore.shared.custom = Color(red: 0.1, green: 0.2, blue: 0.3)
        XCTAssertTrue(cache.accept(WindowPreviewLook(style)))
        XCTAssertFalse(cache.accept(WindowPreviewLook(style)))

        // Same action, new accent: the look has to differ, or a colour the user
        // just picked would never reach a preview already on screen.
        ThemeStore.shared.custom = Color(red: 0.9, green: 0.8, blue: 0.7)
        XCTAssertTrue(cache.accept(WindowPreviewLook(style)))
    }

    func testAWarningIsNotRedrawnWhenTheAccentChanges() {
        let previous = ThemeStore.shared.custom
        defer { ThemeStore.shared.custom = previous }

        var cache = WindowPreviewLookCache()
        let style = WindowPreviewStyle(.quitApp)
        ThemeStore.shared.custom = Color(red: 0.1, green: 0.2, blue: 0.3)
        XCTAssertTrue(cache.accept(WindowPreviewLook(style)))
        ThemeStore.shared.custom = Color(red: 0.9, green: 0.8, blue: 0.7)
        XCTAssertFalse(cache.accept(WindowPreviewLook(style)), "a fixed tint should not redraw")
    }
}
