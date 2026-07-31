import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Turns physical input into the four `WindowTriggerDelegate` calls: an Fn hold
/// that opens the radial ring with the pointer picking a slot, and the direct
/// chords that snap with no ring involved.
///
/// Three mechanisms, each doing the least it can:
///
/// - **Direct chords → Carbon hotkeys** (`HotKeyManager.shared`). The OS consumes
///   a registered hotkey before the focused app sees it, so the chords need no
///   event tap at all and keep working when Accessibility permission is denied.
/// - **Fn and Escape → one session event tap** (`KeyBlockingTap`). Fn is a flags
///   change, which a Carbon hotkey cannot express, and cancelling on Escape has
///   to stop the focused app acting on the same press.
/// - **The pointer → a global `NSEvent` monitor**, installed only while the ring
///   is open. A monitor is read-only by construction, so pointer tracking can
///   never swallow a click however wrong this class gets, and it costs nothing
///   the rest of the time — which an always-armed mouse tap would not.
///
/// The tap swallows exactly one event: an Escape key-down while the ring is open
/// *and* the Escape itself still carries the Fn flag. Everything else passes
/// straight through, the Fn flags change included — so media keys, emoji,
/// dictation and the F-key row are untouched, and a plain Fn tap behaves exactly
/// as it did before this class existed.
@MainActor
final class WindowTrigger {
    weak var delegate: (any WindowTriggerDelegate)?

    /// Which ring slot sits under a point in **AppKit screen coordinates** —
    /// `NSEvent.mouseLocation` space, y-up, origin at the bottom-left of the main
    /// display, the same space an `NSWindow.frame` is in. Nil means the point is
    /// on no slot, which on release reads as a cancel.
    ///
    /// Injected so this class never learns the ring's geometry: the ring owns its
    /// own layout, and the state machine here stays testable with a closure that
    /// returns whatever a case needs.
    private let slotAt: (CGPoint) -> RingSlot?

    /// Whether something else owns the screen right now, in which case the ring
    /// must not open. In production that is Clean Mode's blackout, which covers
    /// every display and may hold the keyboard: a slot picked behind it would be
    /// invisible. Injected rather than read inline because
    /// `CleanModeController.isAnyActive` is process-wide state this class does not
    /// own, and a guard that cannot be exercised both ways is a guard nobody
    /// knows still works.
    private let isSuppressed: () -> Bool
    private let defaults: UserDefaults

    /// True between `start()` and `stop()`. Every handler tests it first, so an
    /// event already in flight when the tap is invalidated passes through rather
    /// than being judged by a torn-down trigger.
    private(set) var isArmed = false
    private(set) var isRingOpen = false

    /// Last slot handed to `ringHighlight`, so an unchanged slot is not
    /// re-reported: `@Observable` does not compare before notifying, and the
    /// pointer stream arrives at screen-refresh rate.
    private var highlighted: RingSlot?

    private var tap: KeyBlockingTap?
    private var pointerMonitor: Any?
    private var chordTokens: [HotKeyManager.Token] = []

    init(
        defaults: UserDefaults = .standard,
        isSuppressed: @escaping () -> Bool = { CleanModeController.isAnyActive },
        slotAt: @escaping (CGPoint) -> RingSlot?
    ) {
        self.defaults = defaults
        self.isSuppressed = isSuppressed
        self.slotAt = slotAt
    }

    // MARK: - Lifecycle

    /// Registers the chords and arms the tap. Idempotent, so a double enable
    /// cannot stack two taps or two sets of hotkeys.
    func start() {
        guard !isArmed else { return }
        isArmed = true
        registerChords()
        armTap()
    }

    /// The disabled-tool contract: leave input completely untouched. Disarms
    /// first so anything re-entrant sees a dead trigger, cancels a ring that is
    /// still up, then releases every hook. Idempotent.
    func stop() {
        guard isArmed else { return }
        isArmed = false
        closeRing(commit: false)
        tap?.invalidate()
        tap = nil
        stopPointerTracking()
        for token in chordTokens { HotKeyManager.shared.unregister(token) }
        chordTokens.removeAll()
    }

    // MARK: - Tap policy

    /// The tap's entire policy, and the only place this class decides to swallow
    /// anything. Returns true to swallow. Split out from the tap so the state
    /// machine can be driven from tests without creating a real event tap.
    ///
    /// Deliberately not `@discardableResult`: dropping a swallow decision on the
    /// floor is the one mistake this class cannot afford.
    func handle(type: CGEventType, keyCode: Int, flags: CGEventFlags) -> Bool {
        // Fail open before any state is consulted: not armed, nothing to say.
        guard isArmed else { return false }
        // A ring with no delegate could never be closed by its owner, so it must
        // not be able to hold a swallow open. Drop the state and stay invisible.
        guard delegate != nil else {
            closeRing(commit: false)
            return false
        }

        switch type {
        case .flagsChanged:
            // Fn down opens, Fn up closes. The event itself is never swallowed.
            if flags.contains(.maskSecondaryFn) {
                openRing()
            } else {
                closeRing(commit: highlighted != nil)
            }
            return false

        case .keyDown:
            guard isRingOpen else { return false }
            // A ring is only real while Fn is physically held, and macOS sets the
            // Fn flag on every event while it is. A key-down without it means the
            // release was missed — the system switches a slow tap off and back on
            // — so the ring is stale: close it and pass the key through. This is
            // what makes it impossible for a ring nobody can see to swallow an
            // Escape. (Arrow and F-keys carry the flag natively, but Escape does
            // not, so the one key that matters here always heals a stale ring.)
            guard flags.contains(.maskSecondaryFn) else {
                closeRing(commit: false)
                return false
            }
            guard keyCode == kVK_Escape else { return false }
            closeRing(commit: false)
            return true

        default:
            return false
        }
    }

    /// Reports the slot under `point` (AppKit screen coordinates), deduped.
    /// Driven by the global monitor in production and directly from tests.
    func pointerMoved(to point: CGPoint) {
        guard isArmed, isRingOpen else { return }
        let slot = slotAt(point)
        guard slot != highlighted else { return }
        highlighted = slot
        delegate?.ringHighlight(slot)
    }

    /// Runs the action bound to a chord, if one claims it. The return value is
    /// what a swallow decision would be — true means a binding owns this key —
    /// but nothing has to act on it: Carbon consumes a registered hotkey before
    /// the focused app is offered it, which is the whole reason the chords are on
    /// `HotKeyManager` rather than on the tap.
    @discardableResult
    func fireChord(keyCode: Int, modifiers: Int) -> Bool {
        guard isArmed, let delegate,
              let action = WindowSettings.action(keyCode: keyCode, modifiers: modifiers, defaults)
        else { return false }
        delegate.snapRequested(action)
        return true
    }

    // MARK: - Ring state

    private func openRing() {
        guard !isRingOpen, !isSuppressed() else { return }
        isRingOpen = true
        // Nothing is picked until the pointer moves, so a dead-still Fn tap
        // releases on nothing and cancels. That is what keeps the tap the user
        // presses for dictation from snapping whatever sits under the cursor.
        highlighted = nil
        delegate?.ringOpened()
        startPointerTracking()
    }

    /// The single ring-close path — Fn up, Escape, a stale ring, or `stop()`.
    /// Idempotent, and safe with no delegate attached.
    private func closeRing(commit: Bool) {
        guard isRingOpen else { return }
        isRingOpen = false
        highlighted = nil
        stopPointerTracking()
        delegate?.ringClosed(commit: commit)
    }

    // MARK: - System hooks

    /// One Carbon hotkey per effective binding. The action is resolved again when
    /// the key fires, so rebinding the *action* under an unchanged chord needs no
    /// re-registration; changing the chord itself needs a `stop()`/`start()`,
    /// which is one call each and idempotent.
    private func registerChords() {
        guard !isRunningTests else { return }
        for binding in WindowSettings.chords(defaults) {
            let keyCode = binding.chord.keyCode
            let modifiers = binding.chord.modifiers
            let token = HotKeyManager.shared.register(keyCode: keyCode, modifiers: modifiers) {
                [weak self] in self?.fireChord(keyCode: keyCode, modifiers: modifiers)
            }
            chordTokens.append(token)
        }
    }

    /// `flagsChanged` for the Fn transitions and `keyDown` for Escape. No mouse
    /// type is ever in the mask, so the pointer stays live — the same guaranteed
    /// escape hatch Clean Mode's lock relies on.
    ///
    /// A tap that cannot be created (Accessibility not granted) leaves the chords
    /// running and the ring simply unavailable: quiet degradation, not a dead
    /// tool.
    private func armTap() {
        guard !isRunningTests else { return }
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        tap = KeyBlockingTap(eventMask: mask) { [weak self] event in
            // The tap's run-loop source is on the main run loop, so the callback
            // is already on the main thread. `assumeIsolated` is what keeps the
            // swallow decision synchronous — the only kind a tap can make — and a
            // released trigger resolves to pass-through.
            MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(
                    type: event.type,
                    keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                    flags: event.flags)
            }
        }
    }

    /// Read-only pointer stream, live only while the ring is. A global monitor
    /// cannot alter or drop an event, so this can never cost the user a click.
    private func startPointerTracking() {
        guard !isRunningTests, pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved(to: NSEvent.mouseLocation) }
        }
    }

    private func stopPointerTracking() {
        guard let pointerMonitor else { return }
        NSEvent.removeMonitor(pointerMonitor)
        self.pointerMonitor = nil
    }

    /// Belt and suspenders. The tests drive `handle`/`pointerMoved`/`fireChord`
    /// directly and never need a real hook, but a stray `start()` in a test must
    /// not tap, monitor or claim a chord on the developer's live session — the
    /// same guard, and the same reasoning, as `CleanModeRuntime`.
    private var isRunningTests: Bool { CleanModeRuntime.isRunningTests }
}
