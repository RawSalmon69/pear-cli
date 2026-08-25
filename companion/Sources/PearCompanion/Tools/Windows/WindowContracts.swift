import ApplicationServices
import CoreGraphics

// The whole seam between the pieces of window management: the geometry (pure,
// here and in WindowZoneMath), the AX mover, the radial ring, the event tap that
// opens it, and the trackpad gestures. Nothing in this file knows about AppKit,
// so each piece can be built and tested against these types without dragging the
// others in. The one Accessibility type that does appear is `AXUIElement`, and
// only as the *name* of the window a caller means — no attribute is read here.

/// Where a window should end up, as a fraction of the target screen's
/// visible frame. y-down, matching CoreGraphics display space.
///
/// Fractions rather than points because a zone has to mean the same thing on a
/// 13" laptop and a 6K display, and the ring offers zones before any screen is
/// picked. The unit rect is resolved against a real `visibleFrame` exactly once,
/// at commit time, by `WindowZoneMath`.
struct WindowZone: Equatable, Sendable, Identifiable {
    let id: String        // stable, persisted in settings
    let name: String      // shown in the ring and in settings
    let unit: CGRect      // origin + size in 0...1 of visibleFrame
}

/// Everything the engine can do to a window.
///
/// Deliberately closed and deliberately small: these seven cases are the whole
/// vocabulary the ring, the chords, the trackpad gestures and the mover have to
/// agree on. Every zone in the catalogue rides inside `snap`, so a new snapping
/// gesture is a new *binding* rather than a new case; a case is added only for
/// something that is not a frame at all — sending the window to the Dock, giving
/// it a Space, closing it, quitting its app. Four layers switch exhaustively
/// over this enum (`WindowZoneMath.frame`, `RingLabel.text`, the
/// `WindowSettings` token pair, `AXWindowMover.commit`), which is the cost of
/// each new case and the reason to keep earning it.
enum WindowAction: Equatable, Sendable {
    case snap(WindowZone)
    case center           // keep the current size, center it
    /// Back to the frame the window had before the *first* snap of a run, so
    /// left-half then right-half then restore lands where the user started
    /// rather than one step back. Undo, not a step backwards.
    case restore
    /// Send the window to the Dock.
    case minimize
    /// **Toggle** macOS full-screen: a normal window goes full-screen, one that
    /// is already full-screen comes back out.
    ///
    /// A toggle rather than a one-way trip because a gesture that full-screens
    /// an already-full-screen window does nothing, and a gesture that does
    /// nothing reads as broken. Distinct from `.snap(maximize)`, which only
    /// grows the frame to the visible area and leaves the menu bar, the Dock and
    /// the window's own title bar in place — that is a frame, this is a Space.
    case fullScreen
    /// Close the window. **Destructive** — a binding for this must require a
    /// deliberate motion, never a twitch, and must never fire from momentum.
    case close
    /// Quit the window's application. **Destructive**, same rule as `close`,
    /// and more so: it can take unsaved work in every other window of that app.
    case quitApp

    /// Whether a mis-fire costs the user something they cannot undo with a
    /// second gesture. Bindings gate these behind a larger threshold.
    ///
    /// `fullScreen` is not on this list: the same gesture that entered
    /// full-screen leaves it again, so a mis-fire costs a second gesture and
    /// nothing else.
    var isDestructive: Bool {
        switch self {
        case .close, .quitApp: return true
        case .snap, .center, .restore, .minimize, .fullScreen: return false
        }
    }
}

/// A slot on the radial ring: eight around, one hub.
///
/// Declared clockwise from the top with the hub last, so `allCases` is already
/// the order the ring draws in and the ring never has to carry its own table.
/// Leading/trailing rather than left/right: the same names work if the ring is
/// ever mirrored for an RTL layout, and they map cleanly onto the zone
/// catalogue's left/right zones on the way out.
enum RingSlot: String, CaseIterable, Identifiable, Sendable {
    case top, topTrailing, trailing, bottomTrailing
    case bottom, bottomLeading, leading, topLeading, hub

    var id: String { rawValue }
}

/// The one thing that touches a real window. Split out so the ring and the
/// event tap can be exercised with a recording double — driving the
/// Accessibility API in a test would need a live session and permission.
///
/// Both calls name the window they mean. `window: nil` means "the frontmost
/// app's focused window", which is the only thing a keyboard chord or the radial
/// ring *can* mean: neither has a pointer aimed at anything. A trackpad gesture
/// does — it began on a particular title bar — and passes that window, because
/// a scroll does not raise the window it is over, so "frontmost" and "the one
/// you are pointing at" are routinely different windows. With `close` and
/// `quitApp` in the vocabulary, guessing wrong there costs the user work in a
/// window they never touched.
///
/// There is deliberately no one-argument spelling of either call: a caller that
/// forgot to say which window it meant would silently act on the focused one,
/// which is the bug this shape exists to make unwritable.
@MainActor protocol WindowMover: AnyObject {
    /// Show a translucent preview of where `action` would put `window`; a nil
    /// action hides it. Called continuously while a gesture or the ring is live,
    /// so it must be cheap on repeat.
    func preview(_ action: WindowAction?, on window: AXUIElement?)
    /// Apply `action` to `window`, clearing any preview.
    func commit(_ action: WindowAction, on window: AXUIElement?)
}

/// What the event tap reports upward. The tap owns no policy — it turns key
/// state into these four calls and lets the receiver decide what a highlight or
/// a cancel means, which keeps the tap (the part that must never block the
/// event stream) as small as it can be.
@MainActor protocol WindowTriggerDelegate: AnyObject {
    func ringOpened()
    func ringHighlight(_ slot: RingSlot?)
    /// commit == false means cancelled (Esc, or released on nothing).
    func ringClosed(commit: Bool)
    /// A direct keyboard chord fired — no ring involved.
    func snapRequested(_ action: WindowAction)
}
