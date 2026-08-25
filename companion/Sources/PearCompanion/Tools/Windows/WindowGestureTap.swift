import AppKit
import CoreGraphics

// MARK: - One scroll frame

/// One `.scrollWheel` event, reduced to the four things a window gesture needs.
///
/// `dx`/`dy` are **finger travel in points, +x right and +y down** — already out
/// of CoreGraphics' content-scroll convention and into the screen-direction
/// convention `GestureInput.scrolled` documents, so the recogniser never has to
/// know how the user has natural scrolling set.
struct ScrollFrame: Equatable {
    /// The gesture phase, mapped off `kCGScrollWheelEventScrollPhase`.
    ///
    /// `other` is everything that is not one of the four transitions: a mouse
    /// wheel (which carries no phase at all), a `mayBegin` frame from fingers
    /// merely resting on the trackpad, and the inertia tail, which arrives with
    /// no scroll phase once the fingers are up. None of them can start, feed or
    /// end a gesture — which is what makes a mouse wheel structurally unable to
    /// engage this feature.
    enum Phase: Equatable { case began, changed, ended, cancelled, other }

    let phase: Phase
    /// The window server is coasting: `kCGScrollWheelEventMomentumPhase` is
    /// non-zero. Passed to the recogniser verbatim, which is what stops inertia
    /// from being read as travel the user produced.
    let isMomentum: Bool
    let dx: CGFloat
    let dy: CGFloat

    /// `kCGScrollWheelEventScrollIsDirectionInverted`. CoreGraphics does not
    /// export a name for field 137, but it is the field AppKit reads: setting it
    /// on a synthesised event flips `NSEvent.isDirectionInvertedFromDevice`
    /// exactly, measured both ways. Absent — a future SDK dropping it — the
    /// fallback is `true`, which is the macOS default (natural scrolling on) and
    /// therefore the answer that is right for almost every Mac.
    private static let directionInvertedField = CGEventField(rawValue: 137)

    /// Reads one scroll event. Every number here was measured on this SDK rather
    /// than recalled, because a sign error in either axis snaps every window to
    /// the opposite side of the screen:
    ///
    /// - `PointDeltaAxis1` **is** `NSEvent.scrollingDeltaY` and `PointDeltaAxis2`
    ///   **is** `scrollingDeltaX`, same units and same sign (synthesised events
    ///   round-trip 1:1 through `NSEvent(cgEvent:)`).
    /// - Fed to a real `NSScrollView`, `+scrollingDeltaY` moves the clip origin
    ///   *up* the document and `+scrollingDeltaX` moves it *left*, i.e. a
    ///   positive delta on either axis slides the **content down / right** on
    ///   screen.
    /// - Natural scrolling means the content follows the fingers, so with it on
    ///   (`isDirectionInverted`) the deltas already *are* finger travel with +x
    ///   right and +y down. With it off the content moves against the fingers,
    ///   so both axes negate.
    /// - The scroll-phase field is a plain sequence — 1 began, 2 changed, 4
    ///   ended, 8 cancelled, 128 mayBegin — **not** the `NSEvent.Phase` bitmask
    ///   it resembles (there, changed is 4 and ended is 8). Reading it as the
    ///   bitmask would mistake every `changed` frame for an `ended` one.
    static func read(_ event: CGEvent) -> ScrollFrame {
        let phase: Phase
        switch event.getIntegerValueField(.scrollWheelEventScrollPhase) {
        case 1: phase = .began
        case 2: phase = .changed
        case 4: phase = .ended
        case 8: phase = .cancelled
        default: phase = .other
        }
        let inverted =
            directionInvertedField.map { event.getIntegerValueField($0) != 0 } ?? true
        let sign: CGFloat = inverted ? 1 : -1
        return ScrollFrame(
            phase: phase,
            isMomentum: event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0,
            dx: sign * CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)),
            dy: sign * CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)))
    }
}

// MARK: - The policy

/// What one frame of input means: whether to swallow it, what to preview, and
/// what to commit. The whole decision, with no event tap, no Accessibility and
/// no window in sight, so every rule below is driven from tests at exact values.
@MainActor
struct WindowGesturePolicy {
    /// What the caller must do with one frame.
    struct Outcome: Equatable {
        /// True only for an event belonging to a gesture Pear owns. Everything
        /// else — every phase of a gesture that did not begin on a title bar,
        /// every mouse wheel, every inertia frame, every unexpected shape —
        /// is false, and false means the app gets the event untouched.
        var swallow = false
        /// The action the finished gesture earned. Non-nil on at most one frame
        /// per physical gesture.
        var commit: WindowAction?
        /// Whether the live preview changed, and to what.
        var preview: Preview = .unchanged
    }

    /// `unchanged` on the frames that would re-show what is already on screen.
    /// The dedupe is not cosmetic: the preview writes an observable and drives an
    /// AX resolve, and scroll frames arrive every few milliseconds.
    enum Preview: Equatable {
        case unchanged
        case show(WindowAction?)
    }

    private var recognizer = WindowGestureRecognizer()
    /// True from the frame that began a gesture over a title bar until the frame
    /// that ends it. The one bit the swallow rule is made of.
    private(set) var ownsGesture = false
    /// Last value handed to `WindowMover.preview`, for the dedupe.
    private var shownPreview: WindowAction?

    /// Feeds one scroll frame.
    ///
    /// `isOverTitleBar` is consulted on **exactly one** frame — the one that
    /// begins a gesture — and never again for that gesture. Deciding once is
    /// what makes the swallow rule honest in both directions: a pointer that
    /// drifts off the bar mid-swipe cannot abandon a gesture Pear already owns,
    /// and one that drifts *onto* a bar mid-swipe cannot start swallowing
    /// halfway through a scroll the app has already begun acting on.
    // Plain non-escaping `() -> Bool` rather than `@MainActor () -> Bool`: a
    // global-actor function type is implicitly `@Sendable`, which a test's
    // recording spy cannot be. A non-escaping closure inherits this type's
    // isolation anyway, so the real caller still reaches `WindowUnderPointer`.
    mutating func handle(_ frame: ScrollFrame, isOverTitleBar: () -> Bool) -> Outcome {
        switch frame.phase {
        case .began:
            // Momentum is tested before the title bar so an inertia frame never
            // even costs a lookup: the window server coasting is not a gesture
            // anybody just started.
            guard !frame.isMomentum, isOverTitleBar() else {
                ownsGesture = false
                return Outcome()
            }
            ownsGesture = true
            _ = recognizer.accept(.began)
            return feed(.scrolled(dx: frame.dx, dy: frame.dy, isMomentum: frame.isMomentum))

        case .changed:
            guard ownsGesture else { return Outcome() }
            return feed(.scrolled(dx: frame.dx, dy: frame.dy, isMomentum: frame.isMomentum))

        case .ended:
            guard ownsGesture else { return Outcome() }
            // Ownership ends with the fingers. The inertia tail that follows
            // carries no scroll phase, so it lands in `.other` and goes to the
            // app — Pear swallows the gesture, not the coast after it.
            ownsGesture = false
            return feed(.ended)

        case .cancelled:
            guard ownsGesture else { return Outcome() }
            ownsGesture = false
            return feed(.cancelled)

        case .other:
            // A frame with no phase of its own — a mouse wheel, a `mayBegin`
            // from fingers merely resting, or the inertia tail. Never swallowed.
            //
            // Inertia additionally *proves* the fingers have lifted. In a
            // healthy stream `ended` released ownership already and this does
            // nothing; if that frame was lost — the system switches a tap whose
            // callback ran long off and back on — letting go here is what stops
            // the swallow from outliving the gesture that earned it. It cancels
            // rather than commits: a gesture whose end was never seen should do
            // nothing, not something.
            guard frame.isMomentum, ownsGesture else { return Outcome() }
            ownsGesture = false
            var outcome = feed(.cancelled)
            outcome.swallow = false
            return outcome
        }
    }

    /// Feeds one magnify increment, gated on the same ownership bit.
    ///
    /// Never swallows: pinch arrives through a read-only global monitor, which
    /// cannot drop an event however wrong this function gets. Over a title bar
    /// almost nothing zooms, so passing it on costs nothing and removes the
    /// whole risk.
    mutating func magnified(by amount: CGFloat) -> Outcome {
        guard ownsGesture else { return Outcome() }
        var outcome = feed(.magnified(by: amount))
        outcome.swallow = false
        return outcome
    }

    /// Abandons any gesture in flight and hides the preview, for a tap being
    /// torn down mid-swipe.
    mutating func cancel() -> Outcome {
        guard ownsGesture else { return Outcome() }
        ownsGesture = false
        var outcome = feed(.cancelled)
        outcome.swallow = false
        return outcome
    }

    /// One input, plus the preview bookkeeping. `pending` is nil once a gesture
    /// has ended, so the frame that commits is also the frame that hides.
    private mutating func feed(_ input: GestureInput) -> Outcome {
        var outcome = Outcome(swallow: true, commit: recognizer.accept(input))
        let next = recognizer.pending
        if next != shownPreview {
            shownPreview = next
            outcome.preview = .show(next)
        }
        return outcome
    }
}

// MARK: - The tap

/// Joins the three pieces of the trackpad gesture: `WindowUnderPointer` decides
/// whether a gesture is Pear's, `WindowGestureRecognizer` decides what it means,
/// and `WindowMover` previews and applies it.
///
/// Two hooks, deliberately unequal:
///
/// - **Scrolling → one `KeyBlockingTap`** on `.scrollWheel`. A tap is the only
///   thing that can stop the app underneath from also scrolling, so it is the
///   only way a title-bar swipe can mean something other than "scroll". It sees
///   every scroll event on the machine, which is why the swallow rule below is
///   the most important code in this file.
/// - **Pinch → a read-only `NSEvent` global monitor.** `.magnify` never needs to
///   be blocked (almost nothing zooms under a title bar), and a monitor is
///   structurally incapable of blocking one, so the whole class of "Pear ate my
///   pinch" bugs cannot exist.
///
/// Everything the tap does not positively own passes through untouched. There is
/// no path in this file that swallows on a maybe.
///
/// One asymmetry to know about: the title bar under the pointer decides *whether*
/// a gesture is Pear's, but `AXWindowMover` always acts on the frontmost app's
/// focused window. A scroll does not raise the window it is over, so a gesture
/// performed on a *background* window's title bar moves the front window
/// instead. In practice the window you are pointing at is the one you are using;
/// aiming the move at the hit window itself would mean widening the `WindowMover`
/// contract, which is a separate change.
@MainActor
final class WindowGestureTap {
    /// Weak, exactly like `WindowTrigger.delegate`: `WindowsTool` owns the mover,
    /// and a tap whose mover has gone away must fail open rather than hold a
    /// swallow decision it can no longer act on.
    private weak var mover: (any WindowMover)?
    private let windows: WindowUnderPointer
    private var policy = WindowGesturePolicy()

    private var tap: KeyBlockingTap?
    private var magnifyMonitor: Any?
    private var screenObserver: (any NSObjectProtocol)?
    private var activationObserver: (any NSObjectProtocol)?

    /// True between `start()` and `stop()`. Every entry point tests it first, so
    /// an event already in flight when the tap is invalidated passes through
    /// rather than being judged by a torn-down gesture.
    private(set) var isArmed = false

    init(mover: any WindowMover, windows: WindowUnderPointer = WindowUnderPointer()) {
        self.mover = mover
        self.windows = windows
    }

    // MARK: Lifecycle

    /// Arms the tap and the pinch monitor. Idempotent, so a double enable cannot
    /// stack two taps.
    func start() {
        guard !isArmed else { return }
        isArmed = true
        armTap()
        armMagnifyMonitor()
        observeDeskChanges()
    }

    /// The disabled-tool contract: leave input completely untouched. A disabled
    /// tool cannot see a single scroll event.
    func stop() {
        guard isArmed else { return }
        isArmed = false
        tap?.invalidate()
        tap = nil
        if let magnifyMonitor {
            NSEvent.removeMonitor(magnifyMonitor)
            self.magnifyMonitor = nil
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        apply(policy.cancel())
        windows.invalidate()
    }

    // MARK: Policy

    /// One scroll event. Returns true to swallow it — the only kind of answer a
    /// tap can give, and the one this class cannot afford to get wrong.
    ///
    /// Both fail-open guards come before any state is consulted: a torn-down tap
    /// and a released mover both mean "not ours".
    func handle(_ frame: ScrollFrame, at point: CGPoint) -> Bool {
        guard isArmed, mover != nil else { return false }
        return apply(policy.handle(frame) { [windows] in windows.hit(at: point) != nil })
    }

    /// One magnify increment. The return value is only ever false — a monitor
    /// cannot swallow — and exists so the two paths read the same.
    @discardableResult
    func magnified(by amount: CGFloat) -> Bool {
        guard isArmed, mover != nil else { return false }
        return apply(policy.magnified(by: amount))
    }

    /// Applies an outcome in the one order that is safe: commit the move, then
    /// drop the preview it replaced, then forget the cached title bar — the
    /// window just moved, so its rect is stale by definition.
    @discardableResult
    private func apply(_ outcome: WindowGesturePolicy.Outcome) -> Bool {
        if let action = outcome.commit { mover?.commit(action) }
        if case .show(let preview) = outcome.preview { mover?.preview(preview) }
        if outcome.commit != nil { windows.invalidate() }
        return outcome.swallow
    }

    // MARK: System hooks

    /// `.scrollWheel` only. No mouse-button type is ever in the mask, so a click
    /// can never be delayed or dropped by this tap however wrong it gets.
    ///
    /// A tap that cannot be created (Accessibility not granted) leaves scrolling
    /// completely live and the gesture simply unavailable: quiet degradation.
    private func armTap() {
        guard !CleanModeRuntime.isRunningTests else { return }
        let mask: CGEventMask = 1 << CGEventType.scrollWheel.rawValue
        tap = KeyBlockingTap(eventMask: mask) { [weak self] event in
            // The tap's run-loop source is on the main run loop, so this is
            // already the main thread. `assumeIsolated` is what keeps the
            // swallow decision synchronous, and a released tap fails open.
            MainActor.assumeIsolated {
                guard let self else { return false }
                // `CGEvent.location` is already the y-down global space
                // `WindowUnderPointer` speaks. `NSEvent.mouseLocation` is y-up
                // and would mislocate every hit.
                return self.handle(ScrollFrame.read(event), at: event.location)
            }
        }
    }

    private func armMagnifyMonitor() {
        guard !CleanModeRuntime.isRunningTests, magnifyMonitor == nil else { return }
        magnifyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .magnify) {
            [weak self] event in
            MainActor.assumeIsolated { _ = self?.magnified(by: event.magnification) }
        }
    }

    /// The cached title bar is only as good as the desk it was measured on.
    /// `WindowUnderPointer` ages entries out on its own; these two cover the
    /// changes that announce themselves — a display added or rearranged, and
    /// another app coming forward with its windows.
    private func observeDeskChanges() {
        guard !CleanModeRuntime.isRunningTests else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windows.invalidate() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windows.invalidate() }
        }
    }
}
