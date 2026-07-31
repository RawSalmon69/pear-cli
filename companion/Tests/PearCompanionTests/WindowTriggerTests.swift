import Carbon.HIToolbox
import CoreGraphics
import XCTest

@testable import PearCompanion

/// Logic-level cover for the window trigger: the Fn-hold state machine, the
/// pointer highlight, the direct chords, and — the part that matters most — the
/// exact set of events it swallows. No event tap, no global monitor, no Carbon
/// hotkey: `start()` refuses to touch the system under `swift test`, and every
/// case drives `handle`/`pointerMoved`/`fireChord` directly, which is the same
/// code the real hooks call.
///
/// The swallow assertions are the point of this file. `handle` returning true
/// means a keystroke never reaches the focused app, so every case that feeds a
/// key asserts on the return value, not just on the delegate.
@MainActor
final class WindowTriggerTests: XCTestCase {
    // MARK: - Doubles

    private final class RecordingDelegate: WindowTriggerDelegate {
        enum Event: Equatable {
            case opened
            case highlight(RingSlot?)
            case closed(commit: Bool)
            case snap(WindowAction)
        }

        var events: [Event] = []

        func ringOpened() { events.append(.opened) }
        func ringHighlight(_ slot: RingSlot?) { events.append(.highlight(slot)) }
        func ringClosed(commit: Bool) { events.append(.closed(commit: commit)) }
        func snapRequested(_ action: WindowAction) { events.append(.snap(action)) }
    }

    private final class NoopKeyboardLock: CleanModeKeyboardLocking {
        func engage() -> Bool { false }
        func release() {}
    }

    private final class NoopScreenBlanker: CleanModeScreenBlanking {
        func cover(onDone: @escaping () -> Void) {}
        func recover() {}
        func uncover() {}
    }

    // MARK: - Fixture

    /// A started trigger plus its recorder. `slotAt` decides what the pointer is
    /// over; the default puts every point on the trailing slot, so a case only
    /// has to move the pointer once to have something highlighted.
    ///
    /// Two things every case here depends on:
    ///
    /// - **Bind the returned delegate.** `WindowTrigger.delegate` is weak, and a
    ///   trigger with a released delegate deliberately goes transparent, so a
    ///   case that discards it tests the failsafe instead of the behaviour.
    /// - **Suppression is pinned off.** In production it reads
    ///   `CleanModeController.isAnyActive`, which is process-wide and which the
    ///   Clean Mode suite leaves set (three of its cases end still active), so a
    ///   ring case reading the live static would fail purely on suite order.
    ///   `testTheRingDoesNotOpenBehindCleanMode` is the one case that uses the
    ///   real static, and it enters and exits Clean Mode itself.
    ///
    /// `UserDefaults.standard` is safe here: nothing on the ring or tap path
    /// reads settings. The chord cases, which do, pass a scratch suite.
    private func armed(
        _ defaults: UserDefaults = .standard,
        slotAt: @escaping (CGPoint) -> RingSlot? = { _ in .trailing }
    ) -> (WindowTrigger, RecordingDelegate) {
        let delegate = RecordingDelegate()
        let trigger = WindowTrigger(
            defaults: defaults, isSuppressed: { false }, slotAt: slotAt)
        trigger.delegate = delegate
        trigger.start()
        return (trigger, delegate)
    }

    private let somewhere = CGPoint(x: 400, y: 300)

    /// Every key a user might press near this feature: the chord keys, Escape,
    /// and two ordinary ones. The arrows are the important entries — macOS sets
    /// the Fn flag on the arrow plane whether or not Fn is held, so they are the
    /// easiest thing here to over-match, which is why the Fn transition is read
    /// from `flagsChanged` and never from a key-down.
    private let nearbyKeys = [
        kVK_Escape, kVK_Return, kVK_ANSI_C, kVK_Delete,
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        kVK_Space, kVK_ANSI_A,
    ]

    // MARK: - Event helpers

    @discardableResult
    private func fn(_ down: Bool, _ trigger: WindowTrigger) -> Bool {
        trigger.handle(type: .flagsChanged, keyCode: 0, flags: down ? .maskSecondaryFn : [])
    }

    @discardableResult
    private func keyDown(
        _ code: Int, fnHeld: Bool = true, _ trigger: WindowTrigger
    ) -> Bool {
        trigger.handle(type: .keyDown, keyCode: code, flags: fnHeld ? .maskSecondaryFn : [])
    }

    // MARK: - Fn hold opens and closes the ring

    func testFnDownOpensTheRingAndFnUpCommitsTheHighlightedSlot() {
        let (trigger, delegate) = armed()

        XCTAssertFalse(fn(true, trigger), "the Fn flags change must never be swallowed")
        XCTAssertTrue(trigger.isRingOpen)
        XCTAssertEqual(delegate.events, [.opened])

        trigger.pointerMoved(to: somewhere)
        XCTAssertFalse(fn(false, trigger), "the Fn flags change must never be swallowed")
        XCTAssertFalse(trigger.isRingOpen)
        XCTAssertEqual(delegate.events, [.opened, .highlight(.trailing), .closed(commit: true)])
    }

    /// A dead-still Fn tap — dictation, emoji, the media keys — must not snap
    /// anything. Nothing is highlighted until the pointer moves, so releasing on
    /// nothing is a cancel, exactly as `WindowTriggerDelegate` specifies.
    func testAnFnTapWithoutMovingThePointerCancels() {
        let (trigger, delegate) = armed()

        fn(true, trigger)
        fn(false, trigger)

        XCTAssertEqual(delegate.events, [.opened, .closed(commit: false)])
    }

    func testASecondFnDownWhileHeldDoesNotReopenTheRing() {
        let (trigger, delegate) = armed()

        fn(true, trigger)
        // Adding a second modifier re-fires flagsChanged with Fn still set.
        XCTAssertFalse(
            trigger.handle(
                type: .flagsChanged, keyCode: 0, flags: [.maskSecondaryFn, .maskShift]))
        XCTAssertEqual(delegate.events, [.opened])
    }

    func testAModifierPressWithoutFnNeitherOpensNorSwallows() {
        let (trigger, delegate) = armed()

        XCTAssertFalse(trigger.handle(type: .flagsChanged, keyCode: 0, flags: .maskShift))
        XCTAssertFalse(trigger.isRingOpen)
        XCTAssertEqual(delegate.events, [])
    }

    // MARK: - Escape cancels

    func testEscapeWhileTheRingIsOpenCancelsAndIsSwallowed() {
        let (trigger, delegate) = armed()

        fn(true, trigger)
        trigger.pointerMoved(to: somewhere)
        XCTAssertTrue(keyDown(kVK_Escape, trigger), "Escape must not reach the focused app")
        XCTAssertFalse(trigger.isRingOpen)
        XCTAssertEqual(delegate.events, [.opened, .highlight(.trailing), .closed(commit: false)])
    }

    /// Fn is still physically held after a cancel, so its eventual release must
    /// not close a second time or commit anything.
    func testReleasingFnAfterAnEscapeCancelIsInert() {
        let (trigger, delegate) = armed()

        fn(true, trigger)
        trigger.pointerMoved(to: somewhere)
        keyDown(kVK_Escape, trigger)
        XCTAssertFalse(fn(false, trigger))

        XCTAssertEqual(delegate.events, [.opened, .highlight(.trailing), .closed(commit: false)])
    }

    // MARK: - Highlight follows the injected hit test

    func testHighlightFollowsTheHitTestAndAnUnchangedSlotIsNotReported() {
        var slot: RingSlot? = .top
        let (trigger, delegate) = armed(slotAt: { _ in slot })

        fn(true, trigger)
        trigger.pointerMoved(to: somewhere)
        trigger.pointerMoved(to: CGPoint(x: 401, y: 300))  // same slot, no new report
        slot = .bottomLeading
        trigger.pointerMoved(to: CGPoint(x: 10, y: 10))
        slot = nil  // pointer left the ring
        trigger.pointerMoved(to: CGPoint(x: 9999, y: 9999))

        XCTAssertEqual(
            delegate.events,
            [.opened, .highlight(.top), .highlight(.bottomLeading), .highlight(nil)])
    }

    /// The pointer leaving the ring before release cancels: the last highlight is
    /// nil, and `WindowTriggerDelegate` calls a release on nothing a cancel.
    func testReleasingWithThePointerOffTheRingCancels() {
        var slot: RingSlot? = .leading
        let (trigger, delegate) = armed(slotAt: { _ in slot })

        fn(true, trigger)
        trigger.pointerMoved(to: somewhere)
        slot = nil
        trigger.pointerMoved(to: CGPoint(x: 9999, y: 9999))
        fn(false, trigger)

        XCTAssertEqual(
            delegate.events,
            [.opened, .highlight(.leading), .highlight(nil), .closed(commit: false)])
    }

    func testPointerMovesAreIgnoredWhileTheRingIsClosed() {
        let (trigger, delegate) = armed()

        trigger.pointerMoved(to: somewhere)
        XCTAssertEqual(delegate.events, [])

        // And after a completed gesture, so a monitor that outlived a close
        // could not keep highlighting.
        fn(true, trigger)
        trigger.pointerMoved(to: somewhere)
        fn(false, trigger)
        delegate.events.removeAll()
        trigger.pointerMoved(to: CGPoint(x: 1, y: 1))
        XCTAssertEqual(delegate.events, [])
    }

    // MARK: - Direct chords

    func testAMatchedChordFiresSnapRequestedAndClaimsTheKey() throws {
        let suite = "WindowTriggerTests-chords"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let (trigger, delegate) = armed(defaults)

        let snapModifiers = controlKey | optionKey
        XCTAssertTrue(trigger.fireChord(keyCode: kVK_LeftArrow, modifiers: snapModifiers))
        XCTAssertTrue(trigger.fireChord(keyCode: kVK_Return, modifiers: snapModifiers))
        XCTAssertTrue(trigger.fireChord(keyCode: kVK_ANSI_C, modifiers: snapModifiers))

        XCTAssertEqual(
            delegate.events,
            [
                .snap(.snap(WindowZoneMath.leftHalf)),
                .snap(.snap(WindowZoneMath.maximize)),
                .snap(.center),
            ])
        // No ring is involved in a chord.
        XCTAssertFalse(trigger.isRingOpen)
    }

    func testAnUnmatchedChordIsNotClaimedAndFiresNothing() throws {
        let suite = "WindowTriggerTests-unmatched"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let (trigger, delegate) = armed(defaults)

        let snapModifiers = controlKey | optionKey
        // Right key, wrong modifiers.
        XCTAssertFalse(trigger.fireChord(keyCode: kVK_LeftArrow, modifiers: controlKey | shiftKey))
        // Right modifiers, unbound key.
        XCTAssertFalse(trigger.fireChord(keyCode: kVK_ANSI_Z, modifiers: snapModifiers))
        // The Screenshot tool's chord stays the Screenshot tool's.
        XCTAssertFalse(trigger.fireChord(keyCode: kVK_ANSI_S, modifiers: controlKey | shiftKey))

        XCTAssertEqual(delegate.events, [])
    }

    /// A rebound chord is honoured without re-registering, because the action is
    /// resolved when the key fires rather than captured at registration.
    func testARebindIsHonouredOnTheNextPress() throws {
        let suite = "WindowTriggerTests-rebind"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let (trigger, delegate) = armed(defaults)

        WindowSettings.setAction(.restore, for: .hub, defaults)  // unrelated write
        WindowSettings.setChord(
            HotKeyChord(keyCode: kVK_ANSI_1, modifiers: controlKey | optionKey, label: "⌃⌥1"),
            for: "left-half", defaults)

        XCTAssertTrue(trigger.fireChord(keyCode: kVK_ANSI_1, modifiers: controlKey | optionKey))
        XCTAssertFalse(trigger.fireChord(keyCode: kVK_LeftArrow, modifiers: controlKey | optionKey))
        XCTAssertEqual(delegate.events, [.snap(.snap(WindowZoneMath.leftHalf))])
    }

    // MARK: - Nothing is swallowed while the ring is closed

    func testNoKeyIsSwallowedWhileTheRingIsClosed() {
        let (trigger, delegate) = armed()

        for code in nearbyKeys {
            XCTAssertFalse(keyDown(code, fnHeld: false, trigger), "keyCode \(code)")
            XCTAssertFalse(keyDown(code, fnHeld: true, trigger), "keyCode \(code) with Fn")
        }
        XCTAssertEqual(delegate.events, [], "a closed ring must not talk to its delegate")
    }

    /// Escape is the only swallow, so every other key must still reach the app
    /// even mid-gesture — including the arrows, which carry the Fn flag natively
    /// and are the easiest thing to over-match.
    func testOnlyEscapeIsSwallowedWhileTheRingIsOpen() {
        let (trigger, delegate) = armed()

        fn(true, trigger)
        XCTAssertEqual(delegate.events, [.opened])
        for code in nearbyKeys where code != kVK_Escape {
            XCTAssertFalse(keyDown(code, trigger), "keyCode \(code)")
            XCTAssertTrue(trigger.isRingOpen, "keyCode \(code) must not close the ring")
        }
        XCTAssertTrue(keyDown(kVK_Escape, trigger))
    }

    func testNonKeyboardEventTypesArePassedThrough() {
        let (trigger, delegate) = armed()

        fn(true, trigger)
        for type in [CGEventType.keyUp, .leftMouseDown, .mouseMoved, .scrollWheel] {
            XCTAssertFalse(trigger.handle(type: type, keyCode: 0, flags: .maskSecondaryFn))
        }
        XCTAssertTrue(trigger.isRingOpen)
        XCTAssertEqual(delegate.events, [.opened])
    }

    // MARK: - Failsafes

    /// The tap can miss an Fn release: macOS switches a slow tap off and back on.
    /// A key-down that does not carry the Fn flag proves the ring is stale, so it
    /// closes and the key passes through — no ring the user cannot see is ever
    /// able to hold Escape.
    func testAStaleRingIsHealedByAKeyWithoutFnAndThatKeyPassesThrough() {
        let (trigger, delegate) = armed()

        fn(true, trigger)
        trigger.pointerMoved(to: somewhere)
        // The Fn-up never arrived; the user presses Escape.
        XCTAssertFalse(keyDown(kVK_Escape, fnHeld: false, trigger))
        XCTAssertFalse(trigger.isRingOpen)
        XCTAssertEqual(delegate.events, [.opened, .highlight(.trailing), .closed(commit: false)])
    }

    func testAnUnarmedTriggerSwallowsNothingAndSaysNothing() {
        let delegate = RecordingDelegate()
        let trigger = WindowTrigger(isSuppressed: { false }, slotAt: { _ in .hub })
        trigger.delegate = delegate

        XCTAssertFalse(fn(true, trigger))
        XCTAssertFalse(trigger.isRingOpen)
        XCTAssertFalse(keyDown(kVK_Escape, trigger))
        trigger.pointerMoved(to: somewhere)
        XCTAssertFalse(trigger.fireChord(keyCode: kVK_LeftArrow, modifiers: controlKey | optionKey))
        XCTAssertEqual(delegate.events, [])
    }

    /// The prompt's hard case: a ring somehow open with nobody listening. Nothing
    /// can be swallowed, because nothing could ever ask for it to be released.
    func testARingWithNoDelegateSwallowsNothing() {
        let (trigger, delegate) = armed()

        fn(true, trigger)
        XCTAssertTrue(trigger.isRingOpen)
        trigger.delegate = nil

        XCTAssertFalse(keyDown(kVK_Escape, trigger), "no listener means no swallow")
        XCTAssertFalse(trigger.isRingOpen, "the orphaned ring state is dropped")
        XCTAssertEqual(delegate.events, [.opened])

        // And it stays inert rather than reopening on the next Fn.
        XCTAssertFalse(fn(true, trigger))
        XCTAssertFalse(trigger.isRingOpen)
    }

    /// Clean Mode blanks every screen and may lock the keyboard, so a ring there
    /// would be invisible. The one case that runs against the **production**
    /// suppression default, so the wiring to `CleanModeController.isAnyActive` is
    /// covered and not just the seam: it drives a real controller (with inert
    /// screen/keyboard fakes, so no window opens and nothing is tapped) and both
    /// enters and exits, which also leaves that static clean behind it.
    func testTheRingDoesNotOpenBehindCleanMode() throws {
        let suite = "WindowTriggerTests-cleanmode"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: CleanModeSettings.Key.lockKeyboard)
        defer { defaults.removePersistentDomain(forName: suite) }

        let clean = CleanModeController(
            keyboard: NoopKeyboardLock(), blanker: NoopScreenBlanker(), defaults: defaults)
        defer { clean.exit() }

        let delegate = RecordingDelegate()
        let trigger = WindowTrigger(slotAt: { _ in .trailing })
        trigger.delegate = delegate
        trigger.start()

        clean.enter()
        XCTAssertTrue(CleanModeController.isAnyActive)
        XCTAssertFalse(fn(true, trigger), "and the Fn press still reaches the system")
        XCTAssertFalse(trigger.isRingOpen)
        XCTAssertEqual(delegate.events, [])

        // A suppressed Fn press must not leave anything half-open either: the
        // release is inert rather than a stray close.
        XCTAssertFalse(fn(false, trigger))
        XCTAssertEqual(delegate.events, [])

        clean.exit()
        fn(true, trigger)
        XCTAssertTrue(trigger.isRingOpen, "the ring works again once Clean Mode is gone")
    }

    // MARK: - stop()

    func testStopClosesAnOpenRingAndLeavesTheTriggerInert() {
        let (trigger, delegate) = armed()

        fn(true, trigger)
        trigger.pointerMoved(to: somewhere)
        trigger.stop()

        XCTAssertFalse(trigger.isArmed)
        XCTAssertFalse(trigger.isRingOpen)
        XCTAssertEqual(
            delegate.events, [.opened, .highlight(.trailing), .closed(commit: false)],
            "a ring torn down by stop() is a cancel, never a snap")

        // Nothing is armed: no event moves the machine and no key is swallowed.
        delegate.events.removeAll()
        XCTAssertFalse(fn(true, trigger))
        XCTAssertFalse(trigger.isRingOpen)
        XCTAssertFalse(keyDown(kVK_Escape, trigger))
        trigger.pointerMoved(to: somewhere)
        XCTAssertFalse(trigger.fireChord(keyCode: kVK_LeftArrow, modifiers: controlKey | optionKey))
        XCTAssertEqual(delegate.events, [])
    }

    func testStopAndStartAreIdempotent() {
        let (trigger, delegate) = armed()

        trigger.stop()
        trigger.stop()
        XCTAssertFalse(trigger.isArmed)
        XCTAssertEqual(delegate.events, [], "stopping an idle trigger says nothing")

        trigger.start()
        trigger.start()
        XCTAssertTrue(trigger.isArmed)
        fn(true, trigger)
        trigger.pointerMoved(to: somewhere)
        fn(false, trigger)
        XCTAssertEqual(
            delegate.events, [.opened, .highlight(.trailing), .closed(commit: true)],
            "one gesture must not be reported twice after a double start")
    }
}
