import CoreGraphics

/// One frame of a trackpad gesture, already stripped of AppKit.
///
/// The caller (the event tap) maps `NSEvent` phases onto these five cases and
/// nothing else crosses the seam, so every gesture in the app can be replayed
/// in a test without a trackpad, a window, or an accessibility prompt.
enum GestureInput: Equatable, Sendable {
    /// Fingers touched down: arms the recogniser and clears the last gesture.
    case began
    /// One scroll frame. `dx`/`dy` are **finger travel in points, +x right and
    /// +y down** — screen direction, matching the y-down space `WindowZone`
    /// already uses. The caller owns the conversion from `NSEvent`'s scrolling
    /// deltas (natural scrolling inverts both axes); the recogniser never has
    /// to know which way the user has that switch set.
    case scrolled(dx: CGFloat, dy: CGFloat, isMomentum: Bool)
    /// One magnify frame, as the **per-event increment** `NSEvent.magnification`
    /// delivers it (positive = spreading apart). Per-event rather than
    /// cumulative so the caller forwards the field verbatim and cannot get the
    /// running total wrong; the recogniser sums it. A full trackpad squeeze
    /// sums to roughly -0.6…-1.0, a light one to about -0.2.
    case magnified(by: CGFloat)
    /// Fingers lifted. This is the frame an action is returned on.
    case ended
    /// The gesture was abandoned (Esc, a tap-cancel, a lost tap). Nothing fires.
    case cancelled
}

/// Turns a stream of two-finger scroll and magnify frames over a window's title
/// bar into **at most one** `WindowAction` per physical gesture.
///
/// Pure value type: no `NSEvent`, no AX, no clock, no window. Feed it
/// `GestureInput`s and it either hands back an action or does not.
///
/// ## The gestures
///
/// Shaped after Swish, which is the yardstick the owner measures this against.
///
/// | motion | action |
/// | --- | --- |
/// | swipe left / right | left half / right half |
/// | swipe up | **full screen** (toggle) |
/// | swipe down | minimise |
/// | swipe into a corner | that quarter |
/// | pinch out | maximise |
/// | pinch in, lightly | restore |
/// | pinch in, firmly | **close** |
/// | pinch in, all the way | **quit the app** |
///
/// Up is full-screen and not maximise because those are different things and
/// only one of them is what an up-swipe looks like it should do: maximise grows
/// the frame to the visible area, which reads on screen as the window jumping up
/// and getting bigger with the menu bar and its own title bar still there.
/// Maximise keeps the pinch-out gesture, the ⌃⌥↩ chord and the ring hub.
///
/// ## Why it decides on `ended`, not mid-gesture
///
/// The verdict is computed once, when the fingers lift, from the whole
/// accumulated motion — the way a title-bar drag should behave (preview while
/// you move, commit when you let go), and `pending` exposes that live preview.
/// It is also what makes the destructive tier safe: if the recogniser fired the
/// instant a threshold was crossed, a deep pinch would fire `restore` on its way
/// down and could never reach `close` or `quitApp`. Judging the finished motion
/// means the gesture you performed is the gesture that is read, and a gesture
/// that stops short simply downgrades to the milder action or to nothing.
///
/// ## Why close and quit cannot happen by accident
///
/// Both live on the **pinch** channel, never on the swipe channel, and that is
/// the load-bearing rule. Scroll deltas are pointer-accelerated, so a fast flick
/// can manufacture several hundred points of travel out of a two-centimetre
/// finger movement — "a longer swipe" is therefore *not* a trustworthy way to
/// gate something irreversible, and no swipe of any length in any direction can
/// reach a destructive action.
///
/// The pinch channel is where a magnitude ladder *is* defensible, which is why
/// Swish has one there. `NSEvent.magnification` is not accelerated: it is the
/// fractional change in finger separation, and the convention it is summed
/// under is `scale = 1 + Σmagnification`, so a pinch-in of -1.0 is the fingers
/// meeting. The whole pinch-in channel therefore lives in `(0, 1]` — bounded by
/// the hand, not by a driver curve — and "squeeze further" is a thing the user
/// can feel, unlike "flick harder".
///
/// The three rungs and the gaps between them:
///
/// | Σ pinch-in | action | why there |
/// | --- | --- | --- |
/// | 0.15 | `restore` | a light, deliberate squeeze |
/// | 0.45 | `close` | three times the light one: a firm squeeze |
/// | 0.85 | `quitApp` | fingers all but touching, near the channel's ceiling |
///
/// The close→quit gap is **0.40**, wider than the entire restore→close gap
/// (0.30) and nearly as large as the close threshold itself: overshooting a
/// close by 88% of the squeeze it took still lands on close. Every shortfall
/// degrades downward — not-quite-quit is close, not-quite-close is restore,
/// not-quite-restore is nothing — so no failure mode of a benign gesture is a
/// destructive one.
struct WindowGestureRecognizer {
    /// The one threshold table. Every number here is in device-independent
    /// points, except the three magnifications, which are the unitless fractional
    /// change in finger separation that `NSEvent.magnification` reports.
    enum Threshold {
        /// Travel before a swipe means anything at all. The shipped
        /// `SwipeAccumulator` pages a note at 50 and a full two-finger flick
        /// sums to ~50–150, so 60 sits inside one comfortable flick while
        /// staying well clear of the 10–30 pt of drift a resting hand produces.
        static let swipe: CGFloat = 60
        /// Secondary ÷ dominant axis at or below this reads as a straight axis
        /// swipe — within 21.8° of the axis.
        static let axisBand: CGFloat = 0.4
        /// …and at or above this reads as a diagonal — within 14° of the 45°
        /// line. Between the two bands the gesture is ambiguous and nothing
        /// fires, which is what stops a wobbly 30° swipe from picking a corner
        /// (or a corner-ish one from picking an axis) on a coin flip.
        static let diagonalBand: CGFloat = 0.6
        /// Cumulative magnification for full screen: a light, deliberate spread.
        /// Pinch-*in* has no light rung — Swish's pinch-in means close, so a
        /// gentle accidental squeeze must do **nothing** rather than restore a
        /// window the user was not thinking about. Restore keeps the ⌃⌥⌫ chord
        /// and the ring hub.
        static let pinch: CGFloat = 0.15
        /// Cumulative pinch-in for `close`: three times the light squeeze, i.e.
        /// fingers brought to a bit over half their starting separation. A firm
        /// squeeze, not an overshoot of the light one.
        static let pinchClose: CGFloat = 0.45
        /// Cumulative pinch-in for `quitApp`. 0.85 sat so near the ceiling of
        /// what a hand actually produces (a full squeeze sums to about 0.6–1.0)
        /// that quit risked being unreachable *on purpose* — the same shape of
        /// bug as the pinch that could not arm at all. 0.75 still leaves 0.30
        /// between it and `pinchClose`, two thirds of the close threshold itself,
        /// so an enthusiastic close does not land here.
        static let pinchQuit: CGFloat = 0.75
    }

    /// True between `began` and `ended`/`cancelled`. A gesture is spent the
    /// moment it ends: only a fresh `began` re-arms, so no stream of trailing
    /// frames — momentum, a duplicate `ended`, a stray scroll — can produce a
    /// second action.
    private var isTracking = false
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    private var magnification: CGFloat = 0

    init() {}

    /// What would fire if the fingers lifted right now, for a live preview.
    ///
    /// This is the difference between "not yet" and "never": `nil` while the
    /// motion is too small or too ambiguous to mean anything, and the action
    /// itself once it is decisive. `nil` whenever no gesture is in flight.
    var pending: WindowAction? {
        isTracking ? verdict() : nil
    }

    /// Feeds one frame. Returns an action exactly once per physical gesture, on
    /// the `ended` frame that completes it; `nil` on every other frame.
    mutating func accept(_ input: GestureInput) -> WindowAction? {
        switch input {
        case .began:
            clear()
            isTracking = true
        case let .scrolled(dx, dy, isMomentum):
            // Inertia after the fingers lifted is the window server's doing, not
            // the user's. It neither fires nor accumulates, so a flick that
            // scrolled a page cannot also snap a window, and one that already
            // snapped cannot snap again as it coasts.
            guard !isMomentum, isTracking else { break }
            self.dx += dx
            self.dy += dy
        case let .magnified(amount):
            guard isTracking else { break }
            magnification += amount
        case .ended:
            guard isTracking else { break }
            let action = verdict()
            clear()
            return action
        case .cancelled:
            clear()
        }
        return nil
    }

    private mutating func clear() {
        isTracking = false
        dx = 0
        dy = 0
        magnification = 0
    }

    /// The whole decision, from the accumulated motion.
    ///
    /// Pinch is read before swipe: a squeeze can drag the contact centroid a
    /// little and leak scroll deltas, while a two-finger scroll emits no
    /// magnification at all, so when both channels have something to say the
    /// pinch is the one the user meant.
    private func verdict() -> WindowAction? {
        // The ladder, deepest rung first: reading it the other way round would
        // return `close` for a squeeze that earned `quitApp`.
        if magnification <= -Threshold.pinchQuit { return .quitApp }
        if magnification <= -Threshold.pinchClose { return .close }
        // Pinch out full-screens, per Swish's own documentation ("pinch out to go
        // fullscreen"). Maximise is the up-swipe; the two were once the other way
        // round, which is a swap you cannot feel your way to — it has to be read.
        if magnification >= Threshold.pinch { return .fullScreen }
        return swipeVerdict()
    }

    private func swipeVerdict() -> WindowAction? {
        let ax = abs(dx)
        let ay = abs(dy)
        let dominant = max(ax, ay)
        guard dominant >= Threshold.swipe else { return nil }

        let ratio = min(ax, ay) / dominant
        if ratio <= Threshold.axisBand {
            if ax >= ay {
                return .snap(dx < 0 ? WindowZoneMath.leftHalf : WindowZoneMath.rightHalf)
            }
            // Up maximises, down minimises ("swipe down to minimize"). +y is down.
            return dy < 0 ? .snap(WindowZoneMath.maximize) : .minimize
        }
        // A corner needs a real leg on both axes, not just a favourable ratio.
        guard ratio >= Threshold.diagonalBand, min(ax, ay) >= Threshold.swipe else { return nil }
        switch (dx < 0, dy < 0) {
        case (true, true): return .snap(WindowZoneMath.topLeftQuarter)
        case (false, true): return .snap(WindowZoneMath.topRightQuarter)
        case (true, false): return .snap(WindowZoneMath.bottomLeftQuarter)
        case (false, false): return .snap(WindowZoneMath.bottomRightQuarter)
        }
    }
}
