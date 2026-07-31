import CoreGraphics

// The whole seam between the four pieces of window management: the geometry
// (pure, here and in WindowZoneMath), the AX mover, the radial ring, and the
// event tap that opens it. Nothing in this file knows about AppKit or the
// Accessibility API, so each piece can be built and tested against these types
// without dragging the other three in.

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

/// Everything the engine can do to the frontmost window.
///
/// Deliberately closed: three cases is the whole vocabulary the ring, the
/// chords, and the mover have to agree on, so a new gesture is a new binding to
/// an existing case rather than a new case every layer must learn.
enum WindowAction: Equatable, Sendable {
    case snap(WindowZone)
    case center           // keep the current size, centre it
    /// Back to the frame the window had before the *first* snap of a run, so
    /// left-half then right-half then restore lands where the user started
    /// rather than one step back. Undo, not a step backwards.
    case restore
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
@MainActor protocol WindowMover: AnyObject {
    /// Show a translucent preview of where `action` would put the frontmost
    /// window; nil hides it. Called continuously while the ring is open.
    func preview(_ action: WindowAction?)
    /// Apply `action` to the frontmost window, clearing any preview.
    func commit(_ action: WindowAction)
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
