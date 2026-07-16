// Adapted from Loop (GPL-3.0), https://github.com/MrKai77/Loop, commit 3b632db5
// Original files: Loop/Window Management/Window/Window.swift,
//                 Loop/Window Management/Window Manipulation/WindowEngine.swift
//
// The animated snap now uses Loop's own `WindowTransformAnimation` (vendored in
// Vendor/), an `NSAnimation` subclass ticking at the display refresh rate with a
// cubic ease-out and mid-flight re-anchoring. `AXWindowHandle` below is the
// window handle it drives; `shouldAnchorDuringAnimation` / `anchoredFrame` are
// vendored verbatim from Loop's `WindowEngine` for that re-anchoring. The AX
// move/resize path mirrors Loop's `Window.setFrame` and `WindowEngine.performResize`:
//   • read the frontmost app's focused window via
//     AXUIElementCreateApplication + kAXFocusedWindowAttribute,
//   • temporarily disable the app's AXEnhancedUserInterface while resizing
//     (accessibility-enhanced apps — Electron/Chromium, some Catalyst apps —
//     otherwise animate and report the wrong final frame),
//   • honor kAXSizeAttribute settability (fixed-size windows only move),
//   • set size → position → size so a shrink near a screen edge lands where we
//     asked even when the old size would have clamped the position.
// Loop also flips between AppKit's bottom-left space and AX's top-left space;
// we do that once, here, using the primary screen's height as the pivot.
//
// Everything runs on the main actor: AXUIElement is not Sendable and window
// ops are a handful of fast IPC calls, so there is no reason to hop actors.

import AppKit
import ApplicationServices
import SwiftUI // Edge.Set, used by the re-anchoring helpers

@MainActor
enum WindowEngine {
    /// Whether Accessibility is granted. Actions no-op when false; the popover
    /// surfaces the onboarding card instead.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Snap the frontmost app's focused window into `zone`. Silent no-op (a
    /// beep at most) on any failure — never crashes, never retries in a loop.
    static func apply(_ zone: WindowZone) {
        guard isTrusted else { return }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            NSSound.beep()
            return
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Default AX messaging timeout is ~6 s PER CALL; a beachballing target
        // app would freeze our main thread across the ~8 calls below. Cap it.
        AXUIElementSetMessagingTimeout(appElement, 0.5)

        guard let window = focusedWindow(of: appElement),
              let current = frame(of: window)
        else {
            NSSound.beep()
            return
        }

        // Locate the screen the window occupies (most-overlap), in AppKit space.
        let pivot = primaryMaxY()
        let windowInAppKit = current.flippedY(maxY: pivot)
        guard let screen = screenContaining(windowInAppKit) else {
            NSSound.beep()
            return
        }
        let visible = screen.visibleFrame

        // Resolve the target in AppKit space, then flip to AX space to apply.
        let targetAppKit: NSRect =
            zone.resizes
            ? zone.frame(in: visible)
            : WindowZone.centered(current.size, in: visible)
        let targetAX = targetAppKit.flippedY(maxY: pivot)
        // The screen's visible bounds in AX space give the animation the frame
        // to keep the window inside and re-anchor against (Loop's `bounds`).
        let boundsAX = visible.flippedY(maxY: pivot)

        setFrameAnimated(window, to: targetAX, bounds: boundsAX, resize: zone.resizes, app: appElement)

        // ponytail: a "cycle" (repeated ⌃⌥← walks half → left-third → …) would
        // hook in here by remembering the last zone applied per window.
    }

    /// Toggle native macOS fullscreen on the frontmost app's focused window —
    /// the green-button behavior. Not fullscreen → enter (macOS animates it
    /// into its own Space); already fullscreen → exit (macOS restores the
    /// pre-fullscreen frame and Space it came from — no frame bookkeeping here).
    /// Silent no-op on any failure, and a graceful no-op for windows that don't
    /// expose AXFullScreen at all (the set simply fails).
    static func toggleFullscreen() {
        guard isTrusted else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            NSSound.beep()
            return
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)

        guard let window = focusedWindow(of: appElement) else {
            NSSound.beep()
            return
        }
        // `boolAttribute` reads "AXFullScreen", reporting a missing attribute as
        // false (not fullscreen). The decision then enters, and macOS no-ops the
        // set for windows that can't fullscreen.
        setBool(window, kAXFullScreen, nextFullscreenState(from: boolAttribute(window, kAXFullScreen)))
    }

    /// The "AXFullScreen" value to write next, given the current one. A window
    /// already fullscreen (`true`) exits; one that isn't (`false`) or that never
    /// reports the attribute (`nil`) enters. Pure so the decision is unit-
    /// testable — the AX read/write around it needs a live window and isn't.
    static func nextFullscreenState(from current: Bool?) -> Bool {
        current != true
    }

    // MARK: - Snap target (read-only context for the radial ring's preview)

    /// The focused window's frame and screen, both in AppKit space. The
    /// radial trigger reads this once at activation so the zone preview lands
    /// on the same screen (and, for `.center`, at the same size) that
    /// `apply(_:)` will resolve on release. `nil` whenever `apply` would beep.
    struct SnapTarget {
        let windowFrame: NSRect
        let screen: NSScreen
    }

    static func snapTarget() -> SnapTarget? {
        guard isTrusted, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)

        guard let window = focusedWindow(of: appElement),
              let current = frame(of: window)
        else {
            return nil
        }
        let windowInAppKit = current.flippedY(maxY: primaryMaxY())
        guard let screen = screenContaining(windowInAppKit) else { return nil }
        return SnapTarget(windowFrame: windowInAppKit, screen: screen)
    }

    // MARK: - AX reads

    private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(app, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.5) // per-element, see above
        return window
    }

    private static func frame(of window: AXUIElement) -> NSRect? {
        guard let position = axPoint(window, kAXPositionAttribute),
              let size = axSize(window, kAXSizeAttribute)
        else {
            return nil
        }
        return NSRect(origin: position, size: size)
    }

    // MARK: - Animated write (Loop's WindowTransformAnimation, vendored)

    /// The most recent snap animation. One at a time: a new snap cancels this
    /// one first (synchronously, so the enhanced-UI disable/restore pairs can
    /// never interleave). Not cleared on completion — `cancel()` on an already
    /// finished animation is a guarded no-op. Replaces Loop's per-`CGWindowID`
    /// dedup dict (which needed the private `_AXUIElementGetWindow`).
    private static var currentAnimation: WindowTransformAnimation?

    /// Animate the window from its current AX frame to `rect` using Loop's
    /// `WindowTransformAnimation`. Falls back to the direct `setFrame` when
    /// Reduce Motion is on, the animation toggle is off, or the speed is
    /// Instant (`WindowSettings.snapDuration` returns nil). Enhanced UI is
    /// disabled for the duration and restored on completion.
    private static func setFrameAnimated(
        _ window: AXUIElement,
        to rect: NSRect,
        bounds: NSRect,
        resize: Bool,
        app: AXUIElement
    ) {
        // KEEP: Reduce Motion (Loop has no such check) short-circuits to the
        // direct set. So does the settings toggle / Instant speed.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let duration = WindowSettings.snapDuration()
        else {
            setFrame(window, to: rect, resize: resize, app: app)
            return
        }

        let willResize = resize && isSettable(window, kAXSizeAttribute)

        // New snap cancels the in-flight one first. cancel() restores that
        // animation's enhanced-UI flag synchronously, before we re-disable it.
        currentAnimation?.cancel()

        let enhanced = boolAttribute(app, kAXEnhancedUserInterface)
        if enhanced { setBool(app, kAXEnhancedUserInterface, false) }

        let handle = AXWindowHandle(window)
        let animation = WindowTransformAnimation(
            rect,
            window: handle,
            bounds: bounds,
            shouldSetSize: willResize,
            duration: duration
        ) { _ in
            // Nonisolated completion (called on the main run loop): restore the
            // app's enhanced-UI flag via the raw AX write, no actor hop.
            if enhanced { setEnhancedUserInterface(app, true) }
        }
        currentAnimation = animation
        animation.start()
    }

    // MARK: - Re-anchoring (vendored verbatim from Loop's WindowEngine)

    /// The frame to place a window at when the app clamped its size below what
    /// we requested: pin the accepted size to whichever bounds edges the target
    /// touched, then push it fully inside `bounds`. Pure math — `nonisolated`
    /// so the (nonisolated) snap animation can call it each tick.
    nonisolated static func anchoredFrame(
        for actualSize: CGSize,
        within requestedFrame: CGRect,
        targetEdges: Edge.Set,
        bounds: CGRect
    ) -> CGRect {
        var frame = CGRect(origin: requestedFrame.origin, size: actualSize)

        if targetEdges.contains(.leading), targetEdges.contains(.trailing) {
            frame.origin.x = requestedFrame.midX - actualSize.width / 2
        } else if targetEdges.contains(.leading) {
            frame.origin.x = requestedFrame.minX
        } else if targetEdges.contains(.trailing) {
            frame.origin.x = requestedFrame.maxX - actualSize.width
        } else {
            frame.origin.x = requestedFrame.midX - actualSize.width / 2
        }

        if targetEdges.contains(.top), targetEdges.contains(.bottom) {
            frame.origin.y = requestedFrame.midY - actualSize.height / 2
        } else if targetEdges.contains(.top) {
            frame.origin.y = requestedFrame.minY
        } else if targetEdges.contains(.bottom) {
            frame.origin.y = requestedFrame.maxY - actualSize.height
        } else {
            frame.origin.y = requestedFrame.midY - actualSize.height / 2
        }

        return frame.pushInside(bounds)
    }

    /// Whether to re-anchor mid-animation: only when the app ended up *smaller*
    /// than requested (fixed aspect ratio / fixed axis). If it stayed larger
    /// (minimum size), preserving the requested motion avoids visible jitter.
    nonisolated static func shouldAnchorDuringAnimation(
        actualSize: CGSize,
        requestedSize: CGSize,
        tolerance: CGFloat = 2
    ) -> Bool {
        guard !actualSize.approximatelyEqual(to: requestedSize, tolerance: tolerance) else {
            return false
        }

        return actualSize.width <= requestedSize.width + tolerance &&
            actualSize.height <= requestedSize.height + tolerance
    }

    // MARK: - AX write (Loop's disable-enhanced-UI + size/position/size order)

    private static func setFrame(
        _ window: AXUIElement,
        to rect: NSRect,
        resize: Bool,
        app: AXUIElement
    ) {
        let willResize = resize && isSettable(window, kAXSizeAttribute)

        // Enhanced UI must be toggled on the *application* element, not the
        // window. Disable it for the duration of the resize, then restore.
        let enhanced = boolAttribute(app, kAXEnhancedUserInterface)
        if enhanced { setBool(app, kAXEnhancedUserInterface, false) }
        defer { if enhanced { setBool(app, kAXEnhancedUserInterface, true) } }

        // The un-animated fallback (Reduce Motion / animation off / Instant):
        // size → position → size lands a shrink at a screen edge where asked.
        if willResize { setSize(window, rect.size) }
        setPosition(window, rect.origin)
        if willResize { setSize(window, rect.size) }
    }

    @discardableResult
    private static func setPosition(_ window: AXUIElement, _ point: CGPoint) -> Bool {
        var value = point
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axValue)
            == .success
    }

    @discardableResult
    private static func setSize(_ window: AXUIElement, _ size: CGSize) -> Bool {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axValue)
            == .success
    }

    private static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) {
        let flag: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        AXUIElementSetAttributeValue(element, attribute as CFString, flag)
    }

    // MARK: - AX primitives

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return error == .success ? value : nil
    }

    private static func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == CFBooleanGetTypeID()
        else {
            return false
        }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        // Default to settable on error so a probe failure never blocks a resize.
        return error == .success ? settable.boolValue : true
    }

    // MARK: - Screen resolution

    private static func primaryMaxY() -> CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    /// The screen the window (in AppKit space) sits on: fully-containing screen,
    /// else the one with the largest intersection area. Adapts Loop's
    /// `ScreenUtility.screenContaining`.
    private static func screenContaining(_ frame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        if screens.count <= 1 { return screens.first }

        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in screens {
            if screen.frame.contains(frame) { return screen }
            let overlap = screen.frame.intersection(frame)
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best ?? screens.first
    }
}

/// The AX window handle Loop's `WindowTransformAnimation` drives: reads the
/// live frame and writes position/size straight through the AX C APIs (which
/// are nonisolated global functions). `frame` returns `.zero` if the window
/// stops answering mid-animation (the animation treats that tick as a no-op).
/// Self-contained and nonisolated so the nonisolated animation can drive it on
/// the main run loop without an actor hop.
final class AXWindowHandle {
    private let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    var frame: CGRect {
        guard let origin = axValue(kAXPositionAttribute, .cgPoint, CGPoint.self),
              let size = axValue(kAXSizeAttribute, .cgSize, CGSize.self)
        else {
            return .zero
        }
        return CGRect(origin: origin, size: size)
    }

    func setPosition(_ point: CGPoint) {
        var value = point
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue)
    }

    func setSize(_ size: CGSize) {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axValue)
    }

    private func axValue<T>(_ attribute: String, _ type: AXValueType, _: T.Type) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID()
        else {
            return nil
        }
        let out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        guard AXValueGetValue(raw as! AXValue, type, out) else { return nil }
        return out.pointee
    }
}

/// Raw AX write of the app-level enhanced-UI flag. Free function (nonisolated)
/// so the snap animation's completion can restore it without an actor hop.
private func setEnhancedUserInterface(_ app: AXUIElement, _ value: Bool) {
    let flag: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
    AXUIElementSetAttributeValue(app, kAXEnhancedUserInterface as CFString, flag)
}

/// Bridge between AppKit's bottom-left, y-up coordinates and AX's top-left,
/// y-down coordinates. The transform is a reflection about the primary
/// screen's top edge, so it is its own inverse. Adapted from Loop's
/// `CGRect.flipY(maxY:)`.
private extension NSRect {
    func flippedY(maxY: CGFloat) -> NSRect {
        NSRect(x: minX, y: maxY - self.maxY, width: width, height: height)
    }
}

/// `AXEnhancedUserInterface` has no `kAX*` constant in the SDK; Loop uses the
/// same raw attribute string.
private let kAXEnhancedUserInterface = "AXEnhancedUserInterface"

/// `AXFullScreen` likewise has no `kAX*` constant; it's the undocumented
/// attribute macOS's green fullscreen button toggles.
private let kAXFullScreen = "AXFullScreen"
