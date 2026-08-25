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
/// | motion | action |
/// | --- | --- |
/// | swipe left / right | left half / right half |
/// | swipe up / down | maximise / minimise |
/// | swipe into a corner | that quarter |
/// | pinch out / pinch in | maximise / restore |
/// | **deep** pinch in | **close** |
/// | **deep** pinch in *plus* a long swipe down | **quit the app** |
///
/// ## Why it decides on `ended`, not mid-gesture
///
/// The verdict is computed once, when the fingers lift, from the whole
/// accumulated motion — the way a title-bar drag should behave (preview while
/// you move, commit when you let go), and `pending` exposes that live preview.
/// It is also what makes the destructive tier safe: if the recogniser fired the
/// instant a threshold was crossed, a deep pinch would fire `restore` on its way
/// down and could never reach `close`, and any "further travel means something
/// worse" scheme would turn an over-shot benign gesture into a destructive one.
/// Judging the finished motion means the gesture you performed is the gesture
/// that is read, and a gesture that stops short simply downgrades to the milder
/// action or to nothing.
///
/// ## Why close and quit cannot happen by accident
///
/// Both live on the **pinch** channel, never on the swipe channel, and that is
/// deliberate. Scroll deltas are pointer-accelerated, so a fast flick can
/// manufacture several hundred points of travel out of a two-centimetre finger
/// movement — "a longer swipe" is therefore *not* a trustworthy way to gate
/// something irreversible. Magnification is not accelerated: it tracks the
/// fractional change in finger separation, so it is bounded by the user's own
/// hand. `pinchClose` (0.6) is four times `pinch` (0.15) and needs the fingers
/// squeezed to under half their starting separation — a determined full
/// squeeze, not an overshoot of the light one that means `restore`.
///
/// `quitApp` then needs that same full squeeze **and** a clearly downward swipe
/// of `destructiveTravel` (240 pt, four times a snap) in the same gesture:
/// crush the window and throw it away. Coming up short on either half degrades
/// to `close`, and coming up short on the squeeze degrades to `restore` — every
/// failure mode of the destructive gestures lands on a milder action, never a
/// worse one.
struct WindowGestureRecognizer {
    /// The one threshold table. Every number here is in device-independent
    /// points, except the two magnifications, which are the unitless fractional
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
        /// Cumulative magnification for maximise (out) or restore (in). A light,
        /// deliberate squeeze or spread.
        static let pinch: CGFloat = 0.15
        /// Cumulative pinch-in for `close`: fingers squeezed to under half their
        /// starting separation.
        static let pinchClose: CGFloat = 0.6
        /// Downward travel the *second* half of `quitApp` needs, on top of a
        /// full squeeze. Four times a snap.
        static let destructiveTravel: CGFloat = 240
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
        if magnification <= -Threshold.pinchClose {
            let flungDown = dy >= Threshold.destructiveTravel && abs(dx) <= dy * Threshold.axisBand
            return flungDown ? .quitApp : .close
        }
        if magnification >= Threshold.pinch { return .snap(WindowZoneMath.maximize) }
        if magnification <= -Threshold.pinch { return .restore }
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
            // Up maximises, down minimises. +y is down.
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
