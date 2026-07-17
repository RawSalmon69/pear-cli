import CoreGraphics

/// Which way a completed swipe pages through the notes.
enum SwipeDirection {
    case next, previous
}

/// The gesture phase of one scroll frame, mapped from `NSEvent` by the window
/// controller so this type stays free of AppKit and unit-testable.
enum SwipePhase {
    /// First frame of a two-finger scroll (fingers touched down).
    case began
    /// A mid-gesture frame while the fingers are still down.
    case changed
    /// The fingers lifted — the physical swipe is over.
    case ended
    /// Inertia after the fingers lifted; never starts a new swipe.
    case momentum
}

/// Turns a stream of horizontal scroll frames into at most one `SwipeDirection`
/// per physical swipe. Pure value type: feed it deltas + a phase, and it
/// accumulates horizontal-dominant travel during `.began`/`.changed`, emits
/// once when the threshold is crossed, and re-arms on the next `.began`.
struct SwipeAccumulator {
    /// Points of horizontal travel before a swipe registers. Precise trackpad
    /// deltas sum to ~50–150 over a full two-finger flick, so this fires once
    /// well before the fingers lift without tripping on a stray sideways nudge.
    static let threshold: CGFloat = 50

    private var accumulated: CGFloat = 0
    /// Gates to one emission per gesture — cleared on `.began`/`.ended`.
    private var emitted = false

    /// Feeds one scroll frame. Returns a direction exactly once per physical
    /// swipe, on the frame that crosses the threshold; `nil` otherwise.
    mutating func feed(deltaX: CGFloat, deltaY: CGFloat, phase: SwipePhase) -> SwipeDirection? {
        switch phase {
        case .momentum:
            // Inertia frames are never a new swipe — ignore them outright so a
            // flick that already fired can't double-fire as it coasts.
            return nil
        case .began:
            accumulated = 0
            emitted = false
        case .ended:
            accumulated = 0
            emitted = false
            return nil
        case .changed:
            break
        }

        // Horizontal-dominant only: a vertical-leaning frame belongs to the
        // editor's own scrolling, so it neither accumulates nor emits.
        guard abs(deltaX) > abs(deltaY) else { return nil }

        accumulated += deltaX
        guard !emitted, abs(accumulated) >= Self.threshold else { return nil }
        emitted = true
        // Content-left travel (negative dx under natural scrolling) pages
        // forward, matching a left-to-flip-forward reading direction.
        return accumulated < 0 ? .next : .previous
    }
}
