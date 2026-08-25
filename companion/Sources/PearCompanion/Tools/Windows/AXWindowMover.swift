import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Coordinate space

/// The one place AppKit's y-up geometry becomes the y-down geometry the rest of
/// window management speaks — `WindowZoneMath`, `kAXPosition`, CoreGraphics.
///
/// Pure and `NSScreen`-free on purpose: the display arrangement arrives as plain
/// rects, so the transform that only misbehaves on a multi-display desk can be
/// tested at exact pixel values on a single-display build machine.
enum WindowSpace {
    /// AppKit's global space is anchored to the **primary** display's
    /// bottom-left with y growing upward. The Accessibility API and CoreGraphics
    /// are anchored to that *same* display's **top**-left with y growing
    /// downward. x agrees, both dimensions agree; only y flips:
    ///
    ///     y_down = primaryHeight - y_up_max
    ///
    /// An AppKit rect is anchored at its bottom-left and an AX rect at its
    /// top-left, so the conversion reads the *far* edge: a rect's `maxY` in one
    /// space is its `minY` in the other. That is what makes this function its
    /// own inverse, and the reason there is exactly one of it instead of a
    /// `toAppKit`/`toAX` pair that can drift apart. It is called from two places
    /// in this file and nowhere else — `visibleFrame` on the way in, the preview
    /// overlay on the way out.
    ///
    /// Only the *primary* display's height appears, never the height of the
    /// display the window happens to be on. Both spaces are pinned to that one
    /// corner, so a display sitting above the primary lands on **negative**
    /// y-down coordinates and one below it on y-down coordinates past
    /// `primaryHeight`. Pivoting on "the current screen's height" instead is
    /// correct on a single-display Mac and wrong on every other desk, which is
    /// why it is the classic bug in this corner of the API.
    static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The height the flip pivots on: that of the display AppKit anchors its
    /// global space to, i.e. the one whose frame origin is (0, 0). Found by
    /// looking for that origin rather than by trusting array order, because a
    /// wrong pivot does not fail loudly — it silently offsets every window on
    /// the desk by the difference between two display heights.
    static func primaryHeight(of frames: [CGRect]) -> CGFloat {
        (frames.first { $0.origin == .zero } ?? frames.first)?.height ?? 0
    }

    /// The display holding the most of `frame`: greatest intersection area, so a
    /// window straddling two displays snaps within whichever one holds more of
    /// it — not the display with keyboard focus, and not always the main one.
    /// `frame` and `frames` must already be in the same space.
    ///
    /// Nil when the window overlaps no display at all, which the caller resolves
    /// rather than this function guessing. An exact tie keeps the earlier
    /// display, so a window split precisely down the middle lands somewhere
    /// stable instead of somewhere that depends on enumeration order.
    static func indexOfScreen(holding frame: CGRect, in frames: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, candidate) in frames.enumerated() {
            let overlap = candidate.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            guard area > 0, best.map({ area > $0.area }) ?? true else { continue }
            best = (index, area)
        }
        return best?.index
    }

    /// The y-down visible frame a window should be snapped inside, given the
    /// AppKit display arrangement verbatim — `(NSScreen.frame,
    /// NSScreen.visibleFrame)` pairs, y-up — and the window's own y-down frame.
    ///
    /// Flip-then-choose lives entirely in this one call so no caller ever holds
    /// a half-converted rect: pick the pivot, flip the displays into the
    /// window's space, choose by overlap, flip the winner's visible area back
    /// out. `fallback` is the display index to use when the window overlaps
    /// nothing at all.
    static func visibleFrame(
        holding windowFrame: CGRect, in screens: [(frame: CGRect, visible: CGRect)],
        fallback: Int
    ) -> CGRect? {
        let pivot = primaryHeight(of: screens.map(\.frame))
        let downFrames = screens.map { flip($0.frame, primaryHeight: pivot) }
        let index = indexOfScreen(holding: windowFrame, in: downFrames) ?? fallback
        guard screens.indices.contains(index) else { return nil }
        return flip(screens[index].visible, primaryHeight: pivot)
    }
}

// MARK: - Restore memory

/// Dictionary-key identity for an accessibility element.
///
/// Two `AXUIElement`s naming the same window are distinct objects — `===` is
/// false — so the reference itself cannot be the key. `CFEqual`/`CFHash` are the
/// element's real identity, and both are local calls: no messaging into the
/// target app, which is what makes them safe to use on a hot path.
struct WindowKey: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    static func == (lhs: WindowKey, rhs: WindowKey) -> Bool { CFEqual(lhs.element, rhs.element) }

    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// Where each window was before Pear first moved it, so `.restore` can put it
/// back.
///
/// The remembered frame is the one from before the *first* move of a run, not
/// the last: chaining left-half → right-half → restore lands on the frame the
/// window had before any of it, which is the only version of restore that feels
/// like undo. A `.restore` consumes the memory, so the next snap records fresh.
///
/// Bounded by count with the oldest entry evicted, and deliberately **not** by
/// probing each remembered window for liveness — that would be one synchronous
/// Accessibility round-trip per entry on every snap, so a single beachballing
/// app could stall the gesture for seconds. A window that has since closed
/// therefore keeps its slot until newer windows push it out, which costs one
/// `CGRect` and one element reference and never more than `capacity` of them.
struct RestoreMemory {
    static let capacity = 64

    private var frames: [WindowKey: CGRect] = [:]
    private var order: [WindowKey] = []

    var count: Int { frames.count }

    func frame(for key: WindowKey) -> CGRect? { frames[key] }

    /// Records `frame` only when this window has nothing remembered yet.
    mutating func rememberFirst(_ frame: CGRect, for key: WindowKey) {
        guard frames[key] == nil else { return }
        if order.count >= Self.capacity { frames.removeValue(forKey: order.removeFirst()) }
        frames[key] = frame
        order.append(key)
    }

    mutating func forget(_ key: WindowKey) {
        guard frames.removeValue(forKey: key) != nil else { return }
        order.removeAll { $0 == key }
    }
}

// MARK: - Mover

/// Moves the frontmost window through the Accessibility API.
///
/// Every geometric decision is borrowed: `WindowZoneMath` picks the target frame
/// and `WindowSpace` picks the display and the coordinate space. What is left
/// here is the awkward part — asking a foreign app to accept a frame, and
/// accepting that sometimes it will not.
///
/// Accessibility permission is never requested from here. Without it every read
/// below returns nil, so an untrusted process is a silent no-op rather than a
/// wrong move; prompting belongs to the tool that owns the user-facing entry
/// point (see `KeyCluTool`), because `preview` is driven continuously and would
/// otherwise ask once per ring highlight.
@MainActor
final class AXWindowMover: WindowMover {
    /// `kAXFullScreenAttribute` is not exported to Swift, so the attribute name
    /// is spelled out — the same workaround `KeyCluTool` uses for the trust
    /// prompt key.
    private static let fullScreenAttribute = "AXFullScreen"

    private var restoreMemory = RestoreMemory()
    private let overlay = ZonePreviewOverlay()

    /// A window plus the two frames a `WindowAction` resolves against, both
    /// y-down. Only ever built for a window Pear has established it can move.
    private struct Target {
        let window: AXUIElement
        let current: CGRect
        let visible: CGRect
        /// Owning app, carried so `.quitApp` does not have to re-resolve the
        /// frontmost application and risk picking a different one.
        let pid: pid_t
    }

    /// Resolved once when a preview session begins and reused until it ends.
    /// Resolving costs half a dozen synchronous Accessibility reads and the ring
    /// calls `preview` continuously, which against a slow app is enough to make
    /// the ring stutter.
    ///
    /// `previewResolved` exists because "no movable window here" and "not looked
    /// yet" are different states: without it, a ring opened over a full-screen
    /// window would re-ask the Accessibility API on every highlight and get the
    /// same no for its trouble. `commit` ignores both — the real move always
    /// resolves fresh, since `.center` and the frame worth remembering have to
    /// be measured against where the window is now.
    private var previewResolved = false
    private var previewTarget: Target?

    // MARK: Preview

    func preview(_ action: WindowAction?) {
        guard let action else {
            endPreviewSession()
            return
        }
        if !previewResolved {
            previewResolved = true
            previewTarget = resolveTarget()
        }
        guard let target = previewTarget, let goal = frame(for: action, on: target) else {
            overlay.hide()
            return
        }
        let pivot = WindowSpace.primaryHeight(of: NSScreen.screens.map(\.frame))
        overlay.show(WindowSpace.flip(goal, primaryHeight: pivot))
    }

    private func endPreviewSession() {
        previewResolved = false
        previewTarget = nil
        overlay.hide()
    }

    // MARK: Commit

    func commit(_ action: WindowAction) {
        endPreviewSession()
        guard let target = resolveTarget() else { return }

        // The three that change a window's existence rather than its frame.
        // They have no goal frame, so they are handled before the geometry path
        // and never touch the restore memory: there is nothing to restore to.
        switch action {
        case .minimize:
            set(true, kAXMinimizedAttribute, on: target.window)
            return
        case .close:
            press(kAXCloseButtonAttribute, on: target.window)
            return
        case .quitApp:
            // Terminate, not force-terminate: this asks the app to quit, so it
            // still gets to prompt about unsaved work rather than losing it.
            NSRunningApplication(processIdentifier: target.pid)?.terminate()
            return
        case .snap, .center, .restore:
            break
        }

        guard let goal = frame(for: action, on: target) else { return }
        let key = WindowKey(target.window)
        switch action {
        case .snap, .center: restoreMemory.rememberFirst(target.current, for: key)
        case .restore: restoreMemory.forget(key)
        case .minimize, .close, .quitApp: break // returned above
        }
        apply(goal, to: target.window)
    }

    /// Sets a boolean AX attribute, e.g. minimising a window.
    private func set(_ value: Bool, _ attribute: String, on window: AXUIElement) {
        _ = AXUIElementSetAttributeValue(window, attribute as CFString, value as CFBoolean)
    }

    /// Presses one of a window's title-bar buttons through AX. Nil for a window
    /// that has no such button (a panel with no close box) — nothing happens,
    /// which is the right answer.
    private func press(_ buttonAttribute: String, on window: AXUIElement) {
        guard let button = AXRead.element(window, buttonAttribute) else { return }
        _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    private func frame(for action: WindowAction, on target: Target) -> CGRect? {
        WindowZoneMath.frame(
            for: action, in: target.visible, current: target.current,
            lastFrame: restoreMemory.frame(for: WindowKey(target.window)))
    }

    // MARK: Finding the window

    /// The frontmost app's focused window, with the frames a snap resolves
    /// against, or nil if there is nothing here Pear should touch.
    ///
    /// Pear's own windows are skipped by pid: the ring and the preview belong to
    /// this process, and the whole point is to move whatever sits behind them.
    private func resolveTarget() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXRead.capTimeout(application)
        guard let window = AXRead.element(application, kAXFocusedWindowAttribute) else { return nil }
        AXRead.capTimeout(window)

        guard isSettable(window), let current = frame(of: window),
            let visible = visibleFrame(holding: current)
        else { return nil }
        return Target(
            window: window, current: current, visible: visible,
            pid: app.processIdentifier)
    }

    /// Whether this is a window to move at all, rather than one to leave alone:
    /// an app-owned full-screen window (the window server will not give that
    /// frame up), or one reporting its position or size as not settable — a
    /// fixed-size dialog, a system alert.
    ///
    /// `AXUIElementIsAttributeSettable` is the system's own answer to "can this
    /// be moved / resized", so there is no role or subrole guessing here, and a
    /// window that says no is never pushed against or retried.
    private func isSettable(_ window: AXUIElement) -> Bool {
        if AXRead.bool(window, Self.fullScreenAttribute) == true { return false }
        return settable(window, kAXPositionAttribute) && settable(window, kAXSizeAttribute)
    }

    private func settable(_ window: AXUIElement, _ attribute: String) -> Bool {
        var flag: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window, attribute as CFString, &flag) == .success
        else { return false }
        return flag.boolValue
    }

    /// The display to snap within. The active display is the fallback for a
    /// window that overlaps no display at all — dragged off the desk, or left
    /// behind on a display that has since gone away — because such a window
    /// still has to land somewhere the user can reach.
    private func visibleFrame(holding current: CGRect) -> CGRect? {
        let screens = NSScreen.screens
        let active = NSScreen.main.flatMap { screens.firstIndex(of: $0) } ?? 0
        return WindowSpace.visibleFrame(
            holding: current, in: screens.map { (frame: $0.frame, visible: $0.visibleFrame) },
            fallback: active)
    }

    // MARK: Applying the frame

    /// Which attribute one write step touches.
    private enum Step { case position, size }

    /// Apps do not simply accept a frame. Many clamp a **resize** against the
    /// position they are currently at — a window still sitting on the old,
    /// smaller display refuses the taller height — and many clamp a **move**
    /// against the size they currently have, because a window wider than the
    /// target zone cannot reach the left edge without its right edge leaving the
    /// screen. Either clamp on its own turns the obvious single
    /// position-then-size pass into a visibly wrong frame.
    ///
    /// So the first pass is position → size → position. The opening move gets
    /// the window onto the target display so the resize is measured against the
    /// right screen; the resize frees the origin from the old width; the closing
    /// move lands the origin exactly, now that nothing forces a clamp. Then the
    /// frame is read back, and only if it is still off does a second pass run in
    /// the opposite order, size → position, which catches the apps that clamped
    /// the other way round.
    ///
    /// It stops there, by design. A second mismatch means the app genuinely will
    /// not take this frame — Terminal quantises to whole character cells, plenty
    /// of windows have a minimum size — and a mover that keeps pushing is a
    /// mover that fights the app forever.
    private func apply(_ goal: CGRect, to window: AXUIElement) {
        write(goal, to: window, steps: [.position, .size, .position])
        guard let landed = frame(of: window), !Self.matches(landed, goal) else { return }
        write(goal, to: window, steps: [.size, .position])
    }

    private func write(_ goal: CGRect, to window: AXUIElement, steps: [Step]) {
        for step in steps {
            switch step {
            case .position: setPosition(goal.origin, on: window)
            case .size: setSize(goal.size, on: window)
            }
        }
    }

    /// Whether the app took the frame. `WindowZoneMath` hands back integral
    /// frames and AX reports points, so half a point is float-noise slack rather
    /// than a fudge factor: a genuine one-point miss shows up as a hairline of
    /// desktop between two snapped windows and has to earn the second pass.
    private static func matches(_ landed: CGRect, _ goal: CGRect) -> Bool {
        abs(landed.minX - goal.minX) < 0.5 && abs(landed.minY - goal.minY) < 0.5
            && abs(landed.width - goal.width) < 0.5 && abs(landed.height - goal.height) < 0.5
    }

    // MARK: The boxed attributes

    /// `kAXPosition` and `kAXSize` are the boxed attributes: they take an
    /// `AXValue`, never a bare `CGPoint`/`CGSize`, and a raw struct is rejected
    /// without complaint.
    ///
    /// Spelled out per type rather than generically. Taking `&value` on an
    /// unconstrained `T` warns — correctly, since a `T` holding an object
    /// reference must not be handed to `AXValueCreate` as raw bytes — and the
    /// only two types that are ever boxed here are these.
    private func setPosition(_ point: CGPoint, on window: AXUIElement) {
        var point = point
        guard let boxed = AXValueCreate(.cgPoint, &point) else { return }
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, boxed)
    }

    private func setSize(_ size: CGSize, on window: AXUIElement) {
        var size = size
        guard let boxed = AXValueCreate(.cgSize, &size) else { return }
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, boxed)
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let origin = position(of: window), let size = size(of: window) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// The read side of the same box. `AXRead`'s typed getters cover everything
    /// `as?` can bridge, which an `AXValue` is not, so the unboxing lives here —
    /// but the read itself still goes through `AXRead`, keeping the
    /// messaging-timeout cap and the nil-on-any-failure contract in one place.
    private func position(of window: AXUIElement) -> CGPoint? {
        guard let boxed = axValue(window, kAXPositionAttribute) else { return nil }
        var out = CGPoint.zero
        guard AXValueGetValue(boxed, .cgPoint, &out) else { return nil }
        return out
    }

    private func size(of window: AXUIElement) -> CGSize? {
        guard let boxed = axValue(window, kAXSizeAttribute) else { return nil }
        var out = CGSize.zero
        guard AXValueGetValue(boxed, .cgSize, &out) else { return nil }
        return out
    }

    private func axValue(_ window: AXUIElement, _ attribute: String) -> AXValue? {
        guard let raw = AXRead.value(window, attribute),
            CFGetTypeID(raw as CFTypeRef) == AXValueGetTypeID()
        else { return nil }
        return (raw as! AXValue)
    }
}

// MARK: - Preview overlay

/// The translucent rectangle showing where a window would land.
///
/// Plain AppKit with explicit frames, **not** SwiftUI: hosting an
/// `NSHostingView` with a material inside a small borderless `NSPanel` can enter
/// an unbreakable constraint-invalidation loop and crash on macOS 26 (see
/// `AGENTS.md`; `ColorToast` is the same shape for the same reason). There is no
/// `layout()` override here either, which covers the other half of that rule —
/// resizing a window from inside a layout pass is its own crash — the panel is
/// resized only from `show`, driven by the ring.
///
/// One panel is built on first use and reused for the life of the app. The ring
/// calls `show` continuously while it is open, so a panel per call would mean a
/// window-server round trip per highlight.
@MainActor
private final class ZonePreviewOverlay {
    /// Enough frost to read as a surface, little enough to see the desktop and
    /// the neighbouring windows through it — the preview's whole job is showing
    /// what the target rect covers.
    private static let washAlpha: CGFloat = 0.22
    private static let cornerRadius: CGFloat = 10
    private static let borderWidth: CGFloat = 2

    private var panel: NSPanel?
    private var wash: NSView?
    private var tint: Color?

    /// `frame` is AppKit-space, y-up: the caller owns the conversion.
    func show(_ frame: NSRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        recolor(panel)
        // Redrawn on the spot rather than deferred: moving between zones resizes
        // the panel, and a deferred redraw shows the old content stretched into
        // the new frame for a beat. Guarded on the frame having actually changed,
        // because this runs on every ring highlight.
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Ordered out, never closed: the panel is the reused one.
    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Above ordinary windows so it reads as an overlay on top of the window
        // it describes. Shown with `orderFrontRegardless` and never
        // `makeKeyAndOrderFront`: a preview that took focus would deactivate the
        // very app whose window is about to move.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No shadow: a snapped zone is flush with the screen edges, where a drop
        // shadow reads as a misaligned window rather than as depth.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let card = NSVisualEffectView()
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = Self.cornerRadius
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = Self.borderWidth
        panel.contentView = card

        // The accent wash is its own layer-backed view rather than a background
        // colour on the effect view, which would fight the material. Autoresized
        // instead of constrained, so growing the panel needs no layout pass.
        let wash = NSView(frame: card.bounds)
        wash.wantsLayer = true
        wash.autoresizingMask = [.width, .height]
        card.addSubview(wash)
        self.wash = wash

        return panel
    }

    /// The tint follows the app's accent, re-read on each `show` so a colour the
    /// user just picked is live — but written only when it actually changed.
    /// `show` runs on every ring highlight, and a `CGColor` write per event is
    /// the AppKit version of re-rendering on every keystroke.
    private func recolor(_ panel: NSPanel) {
        let accent = Theme.accent
        guard tint != accent else { return }
        tint = accent
        let color = NSColor(accent)
        panel.contentView?.layer?.borderColor = color.cgColor
        wash?.layer?.backgroundColor = color.withAlphaComponent(Self.washAlpha).cgColor
    }
}
