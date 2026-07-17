import AppKit
import CoreGraphics

// MARK: - Injectable seams

/// Locks the physical keyboard for the duration of Clean Mode. The real
/// implementation wraps a session `KeySwallowTap`; tests inject a fake so
/// `swift test` never creates a real event tap.
@MainActor
protocol CleanModeKeyboardLocking: AnyObject {
    /// Starts swallowing keystrokes. Returns false when the tap can't be created
    /// (TCC denied, sandbox) — the caller must then leave the keyboard fully
    /// live. A lock failure fails toward MORE user control, never less.
    func engage() -> Bool
    /// Stops swallowing. Safe to call when not engaged.
    func release()
}

/// Covers every screen with an opaque black overlay carrying the Done button
/// and hint. The real implementation builds pure-AppKit windows; tests inject
/// a fake so `swift test` never opens real windows.
@MainActor
protocol CleanModeScreenBlanking: AnyObject {
    /// Puts a black overlay on every screen. `onDone` fires when any overlay's
    /// Done button is clicked. The mouse stays live, so Done is always reachable.
    func cover(onDone: @escaping () -> Void)
    /// Re-covers after a screen-configuration change (a display added/removed),
    /// so a newly attached screen never shows through un-blanked.
    func recover()
    /// Removes every overlay.
    func uncover()
}

// MARK: - Controller

/// The Clean Mode state machine. Entering blanks every screen and optionally
/// locks the keyboard; every exit path (Done, `stop()`, live-disable,
/// termination) funnels through the single idempotent `exit()` → `teardown()`.
/// Nothing survives exit.
///
/// There is deliberately NO auto-timeout (owner: exit only on Done). Safety
/// still holds without it: the mouse is never tapped, so the Done button on
/// every screen is always reachable, and the keyboard tap is a session
/// `CGEventTap`, which the OS destroys the instant this process ends — a lock
/// can never outlive Pear.
@MainActor
final class CleanModeController {
    enum State: Equatable {
        case idle
        /// `keyboardLocked` reflects reality: true only when the tap was
        /// actually created. It is false when locking was off in settings OR
        /// when tap creation failed — in both cases the keyboard is live.
        case active(keyboardLocked: Bool)
    }

    private(set) var state: State = .idle
    var isActive: Bool { if case .active = state { return true } else { return false } }

    /// Whether ANY Clean Mode session is active — other input features
    /// (the radial ring) consult this so they never act behind the blackout.
    /// Static because the consumers have no path to the tool's controller.
    private(set) static var isAnyActive = false

    private let keyboard: CleanModeKeyboardLocking
    private let blanker: CleanModeScreenBlanking
    private let defaults: UserDefaults

    private var screenObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    init(
        keyboard: CleanModeKeyboardLocking,
        blanker: CleanModeScreenBlanking,
        defaults: UserDefaults = .standard
    ) {
        self.keyboard = keyboard
        self.blanker = blanker
        self.defaults = defaults
    }

    /// Convenience init wiring the real (production) services.
    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            keyboard: CleanModeKeyboardLock(),
            blanker: CleanModeScreenBlanker(),
            defaults: defaults
        )
    }

    // MARK: - Enter / exit

    /// Enters Clean Mode. A no-op if already active, so a second tile click or
    /// hotkey can't stack overlays or taps.
    func enter() {
        guard case .idle = state else { return }

        // 1. Screens first — the guaranteed escape hatch (Done) goes up before
        //    anything touches the keyboard.
        blanker.cover(onDone: { [weak self] in self?.exit() })

        // 2. Keyboard: only if the setting is on AND the tap can be created.
        //    Either way the state records the truth.
        var keyboardLocked = false
        if CleanModeSettings.lockKeyboard(defaults) {
            keyboardLocked = keyboard.engage()
        }

        // 3. Re-cover on display changes; force-exit on app termination.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.blanker.recover() }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.exit() }
        }

        state = .active(keyboardLocked: keyboardLocked)
        Self.isAnyActive = true
    }

    /// The single exit path. Idempotent: a no-op unless currently active, so a
    /// double click or `stop()` while idle resolves to one clean teardown.
    /// Every caller (Done, `stop()`, live-disable, termination) routes here.
    func exit() {
        guard isActive else { return }
        state = .idle // flip first so any re-entrant callback sees idle
        Self.isAnyActive = false
        teardown()
    }

    /// Releases every resource acquired on enter. Called only from `exit()`.
    /// Each step is independently safe to run when its resource is absent, so
    /// teardown itself is idempotent.
    private func teardown() {
        keyboard.release()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        blanker.uncover()
    }

    // MARK: - Pure helpers (unit-tested without a GUI)

    /// The overlay frames for a given screen configuration: one per screen,
    /// dropping any degenerate (zero-area) frame. Used by the real blanker's
    /// `recover()` and unit-tested without real screens.
    static func coverFrames(screens: [CGRect]) -> [CGRect] {
        screens.filter { $0.width > 0 && $0.height > 0 }
    }
}
