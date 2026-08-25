import AppKit
import ApplicationServices

// MARK: - What is under the pointer

/// The pointer is on this window's title bar.
///
/// Both rects are **y-down** — CoreGraphics/Accessibility space, which is the
/// space `WindowSpace` and `WindowZoneMath` already speak, so a gesture can hand
/// either of them straight to the geometry without a flip.
///
/// `@unchecked` only because the SDK leaves `AXUIElement` unannotated. The
/// element is an immutable CoreFoundation handle — a *name* for a window, not
/// state — and every read through it in this file is `@MainActor`.
struct TitleBarHit: Equatable, @unchecked Sendable {
    let window: AXUIElement
    let windowFrame: CGRect
    let titleBar: CGRect

    /// `AXUIElement` has no `==` of its own, and two references naming the same
    /// window are distinct objects. `CFEqual` is the element's real identity and
    /// it is a local call — no messaging into the target app — which is the same
    /// reason `WindowKey` in `AXWindowMover` keys on it.
    static func == (lhs: TitleBarHit, rhs: TitleBarHit) -> Bool {
        CFEqual(lhs.window, rhs.window) && lhs.windowFrame == rhs.windowFrame
            && lhs.titleBar == rhs.titleBar
    }
}

// MARK: - The resolver

/// Answers "is the pointer on a title bar?" for the window-gesture event tap.
///
/// The honest answer costs a synchronous Accessibility round-trip into a foreign
/// process, and the tap asks **once per scroll event, in every app**. Paying
/// that per event would stutter scrolling system-wide, so the cache is not an
/// optimisation here, it is the feature: a pointer resting inside a title bar
/// costs zero AX calls, and a pointer resting over ordinary content costs zero
/// too, because a miss is remembered as precisely as a hit.
///
/// Three rules, in this order, and nothing else:
///
/// 1. **One cache slot, two shapes.** Either the last title bar found, or the
///    last region known to hold no title bar. Never both: they would be two
///    beliefs about the same desk that can contradict each other the moment one
///    window overlaps another's title bar, and the cheap check would then hand
///    back the covered window.
/// 2. **A miss carries geometry.** "There is a window here but you are below its
///    title bar" hands back the whole rest of that window, so dragging across a
///    document is one lookup for the entire document, not one per event. Only a
///    genuinely blank answer — no window, no permission, no reply — falls back
///    to remembering a small square around the point.
/// 3. **A floor between lookups.** Rules 1 and 2 cover a still pointer, which is
///    what a trackpad scroll actually is. The floor is what bounds the cost when
///    the pointer is *moving* through ground nothing can describe, and it is the
///    only rule that holds regardless of how the pointer behaves.
///
/// The whole thing is inert without Accessibility permission: every read returns
/// nil, so every probe is `.nothing` and `hit` is always nil. It does not prompt
/// — the tool's entry point owns that decision.
@MainActor
final class WindowUnderPointer {
    /// What one honest look under the pointer found. The seam that makes the
    /// cache testable: driving the real Accessibility API needs a live session,
    /// a display and permission, none of which a build machine has.
    enum Probe: Sendable {
        /// The point is on this window's title bar.
        case titleBar(TitleBarHit)
        /// A window is here and the point is inside it, but below the title bar.
        /// The rect is that window minus its title bar — every point in it is a
        /// guaranteed miss, which is what makes scrolling a document free.
        case body(CGRect)
        /// Nothing to work with: no window under the point, no Accessibility
        /// permission, or no answer before the messaging timeout.
        case nothing
    }

    typealias Lookup = @MainActor (CGPoint) -> Probe
    typealias TimeSource = @MainActor () -> CFAbsoluteTime

    // MARK: Tuning

    /// The shortest gap between two real lookups. A still pointer never reaches
    /// this — rules 1 and 2 answer it — so the floor only bites while the
    /// pointer is moving across ground the cache cannot describe, or while
    /// Accessibility is refusing to answer at all. 100ms caps that at ten probes
    /// a second; a gesture that has to wait one tenth of a second to arm in that
    /// state is invisible next to a trackpad that stutters.
    static let minimumLookupInterval: CFTimeInterval = 0.1

    /// How long a cache entry survives without being asked about. Scroll events
    /// arrive every few milliseconds, so nothing expires mid-gesture; between
    /// gestures everything does. This is the backstop for the one way a window
    /// moves that fires no notification anybody can hook: the user dragging it
    /// by hand. `invalidate()` covers the cases that do notify; this covers the
    /// rest, and bounds how wrong a stale hit can be to half a second.
    static let cacheLifetime: CFTimeInterval = 0.5

    /// Half-extent of the square remembered around a blank answer. Small on
    /// purpose: it is standing in for geometry nobody could measure, so it must
    /// not swallow a real title bar a few points away.
    static let blindMissRadius: CGFloat = 8

    /// Heights a title bar can plausibly have. A measurement outside this says
    /// the app put the anchor somewhere that is not a title bar, so it is
    /// discarded in favour of the fallback rather than trusted.
    static let plausibleHeights: ClosedRange<CGFloat> = 16...64

    /// The height of a standard title bar on *this* macOS, asked of AppKit
    /// rather than hardcoded: `NSWindow` knows exactly how much taller a titled
    /// window's frame is than its content, and that number has moved between
    /// releases (22 → 28). Used only when a window exposes no anchor to measure.
    static let systemTitleBarHeight: CGFloat = {
        let content = CGRect(x: 0, y: 0, width: 100, height: 100)
        return NSWindow.frameRect(forContentRect: content, styleMask: [.titled]).height
            - content.height
    }()

    // MARK: State

    private enum Cache {
        case hit(TitleBarHit)
        case miss(CGRect)
    }

    private let lookup: Lookup
    private let clock: TimeSource
    private var cache: Cache?
    private var lastQuery: CFAbsoluteTime = -.infinity
    private var lastLookup: CFAbsoluteTime = -.infinity

    init(lookup: Lookup? = nil, clock: TimeSource? = nil) {
        self.lookup = lookup ?? WindowUnderPointer.look(at:)
        self.clock = clock ?? CFAbsoluteTimeGetCurrent
    }

    // MARK: Asking

    /// The title bar under `point` (y-down, i.e. `CGEvent.location`), or nil.
    /// Cheap enough to call per scroll event.
    func hit(at point: CGPoint) -> TitleBarHit? {
        let now = clock()
        if now - lastQuery > Self.cacheLifetime { cache = nil }
        lastQuery = now

        switch cache {
        case .hit(let hit) where hit.titleBar.contains(point): return hit
        case .miss(let region) where region.contains(point): return nil
        default: break
        }

        guard now - lastLookup >= Self.minimumLookupInterval else { return nil }
        lastLookup = now

        switch lookup(point) {
        case .titleBar(let hit):
            cache = .hit(hit)
            return hit
        case .body(let region):
            cache = .miss(region)
            return nil
        case .nothing:
            cache = .miss(
                CGRect(origin: point, size: .zero)
                    .insetBy(dx: -Self.blindMissRadius, dy: -Self.blindMissRadius))
            return nil
        }
    }

    /// Drop everything cached — the desk changed. Called on display
    /// reconfiguration, app activation, and after Pear moves a window itself.
    /// Cheap by construction: two assignments, no AX, no allocation.
    func invalidate() {
        cache = nil
        lastLookup = -.infinity
    }

    // MARK: - The title-bar rectangle (pure)

    /// The title bar of a window whose title-bar `anchor` — an element known to
    /// sit centred in the bar — has the given frame. Everything y-down.
    ///
    /// macOS gives no "title bar frame" attribute, so it is measured: the anchor
    /// is vertically centred in the bar, so the bar is twice the distance from
    /// the window's top edge to the anchor's centre. That holds for a plain
    /// titled window, a tab bar and a unified toolbar alike, because in each of
    /// them the traffic lights sit centred in whatever strip is draggable.
    ///
    /// `fallbackHeight` covers a window that exposes no anchor at all. It errs
    /// **small** deliberately: a title bar guessed too short only means the
    /// gesture does not fire near its bottom edge, while one guessed too tall
    /// eats scrolling in the top of a document, and those two mistakes are not
    /// equally bad.
    static func titleBar(of window: CGRect, anchor: CGRect?, fallbackHeight: CGFloat) -> CGRect {
        let measured = anchor.map { 2 * ($0.midY - window.minY) }
        let height = measured.flatMap { plausibleHeights.contains($0) ? $0 : nil } ?? fallbackHeight
        return CGRect(
            x: window.minX, y: window.minY,
            width: window.width, height: min(max(height, 0), window.height))
    }

    /// The part of `window` that is not title bar — the rect a `.body` probe
    /// hands back, and the reason scrolling a document is free.
    static func body(of window: CGRect, below titleBar: CGRect) -> CGRect {
        CGRect(
            x: window.minX, y: titleBar.maxY,
            width: window.width, height: max(window.maxY - titleBar.maxY, 0))
    }

    // MARK: - The live lookup

    /// The system-wide element every hit test goes through, built once and
    /// timeout-capped once. Creating it is local and cheap, but the cap has to
    /// be set on the element that is actually messaged, and this is it.
    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXRead.capTimeout(element)
        return element
    }()

    /// How far up the AX tree to look for the owning window. Real hierarchies
    /// are shallow; the cap is there so a cyclic or hostile tree cannot spin.
    private static let maximumWalk = 12

    /// One honest look: hit-test the point, walk up to the window, measure.
    /// Every step returns nil rather than throwing or waiting, so an app that
    /// will not answer costs one capped timeout and reports `.nothing`.
    static func look(at point: CGPoint) -> Probe {
        var element: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(
                systemWide, Float(point.x), Float(point.y), &element) == .success,
            let element
        else { return .nothing }

        // Pear's own windows are skipped by pid, exactly as `AXWindowMover`
        // does: the ring, the previews and the panel belong to this process and
        // the whole point is to act on whatever sits behind them.
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
            pid != ProcessInfo.processInfo.processIdentifier,
            let window = window(containing: element),
            let frame = frame(of: window),
            frame.contains(point)
        else { return .nothing }

        let anchor = AXRead.element(window, kAXCloseButtonAttribute).flatMap(frame(of:))
        let bar = titleBar(of: frame, anchor: anchor, fallbackHeight: systemTitleBarHeight)
        guard bar.contains(point) else { return .body(body(of: frame, below: bar)) }
        return .titleBar(TitleBarHit(window: window, windowFrame: frame, titleBar: bar))
    }

    /// The window owning `element`. Most elements name theirs directly through
    /// `kAXWindow`, so the parent walk is the fallback for the ones that do not.
    private static func window(containing element: AXUIElement) -> AXUIElement? {
        var cursor = element
        for _ in 0..<maximumWalk {
            AXRead.capTimeout(cursor)
            if AXRead.string(cursor, kAXRoleAttribute) == kAXWindowRole { return cursor }
            if let window = AXRead.element(cursor, kAXWindowAttribute) {
                AXRead.capTimeout(window)
                return window
            }
            guard let parent = AXRead.element(cursor, kAXParentAttribute) else { return nil }
            cursor = parent
        }
        return nil
    }

    // MARK: The boxed attributes

    /// `kAXPosition` and `kAXSize` come back boxed in an `AXValue`, which is the
    /// one thing `AXRead`'s `as?`-based getters cannot bridge — so the unboxing
    /// lives here while the read itself still goes through `AXRead`, keeping the
    /// messaging-timeout cap and the nil-on-any-failure contract in one place.
    /// Spelled out per type rather than generically: taking `&value` on an
    /// unconstrained `T` warns, correctly.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = position(of: element), let size = size(of: element) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func position(of element: AXUIElement) -> CGPoint? {
        guard let boxed = axValue(element, kAXPositionAttribute) else { return nil }
        var out = CGPoint.zero
        guard AXValueGetValue(boxed, .cgPoint, &out) else { return nil }
        return out
    }

    private static func size(of element: AXUIElement) -> CGSize? {
        guard let boxed = axValue(element, kAXSizeAttribute) else { return nil }
        var out = CGSize.zero
        guard AXValueGetValue(boxed, .cgSize, &out) else { return nil }
        return out
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let raw = AXRead.value(element, attribute),
            CFGetTypeID(raw as CFTypeRef) == AXValueGetTypeID()
        else { return nil }
        return (raw as! AXValue)
    }
}
