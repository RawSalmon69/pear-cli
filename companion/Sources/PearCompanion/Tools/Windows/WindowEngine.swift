// Adapted from Loop (GPL-3.0), https://github.com/MrKai77/Loop
//
// The animated snap adapts Loop's `WindowTransformAnimation` (an eased
// interpolation of the AX frame from source to target); see
// `setFrameAnimated` for how we trade Loop's display link for a short
// fixed-step loop. The AX move/resize path mirrors Loop's `Window.setFrame`
// and `WindowEngine.performResize`:
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

        setFrameAnimated(window, from: current, to: targetAX, resize: zone.resizes, app: appElement)

        // ponytail: a "cycle" (repeated ⌃⌥← walks half → left-third → …) would
        // hook in here by remembering the last zone applied per window.
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

    // MARK: - Animated write (adapted from Loop's WindowTransformAnimation)

    /// The in-flight snap animation. One at a time: a new snap cancels the
    /// old task, and the new task awaits the old one so the enhanced-UI
    /// disable/restore pairs can never interleave.
    private static var animationTask: Task<Void, Never>?

    /// Steps the window from `current` to `rect` (both AX space) over ~0.2 s
    /// with a cubic ease-out, then lands exactly on `rect` via the same
    /// size → position → size ordering as the direct path. Loop drives its
    /// version off a display link; every AX set here is synchronous IPC with
    /// a 0.5 s messaging timeout, so we keep the step count low — ~9 sets
    /// over 0.2 s reads as the same motion without risking seconds of blocked
    /// main thread on a hung target app. Any failed set aborts the animation
    /// (the app is rejecting or timing out; don't stack up timeouts).
    private static func setFrameAnimated(
        _ window: AXUIElement,
        from current: NSRect,
        to rect: NSRect,
        resize: Bool,
        app: AXUIElement
    ) {
        // ponytail: Reduce Motion short-circuits to the direct set. A
        // user-facing "animate snaps" toggle was not requested; add one here
        // if it ever is.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setFrame(window, to: rect, resize: resize, app: app)
            return
        }

        let previous = animationTask
        previous?.cancel()
        animationTask = Task { @MainActor in
            // Let the previous animation unwind (its deferred enhanced-UI
            // restore included) before this one touches the same flags.
            await previous?.value
            guard !Task.isCancelled else { return }

            let willResize = resize && isSettable(window, kAXSizeAttribute)
            let enhanced = boolAttribute(app, kAXEnhancedUserInterface)
            if enhanced { setBool(app, kAXEnhancedUserInterface, false) }
            defer { if enhanced { setBool(app, kAXEnhancedUserInterface, true) } }

            let steps = 9
            let duration = 0.2
            for step in 1 ..< steps {
                let t = Double(step) / Double(steps)
                let eased = 1 - pow(1 - t, 3) // cubic ease-out
                let frame = NSRect(
                    x: current.minX + (rect.minX - current.minX) * eased,
                    y: current.minY + (rect.minY - current.minY) * eased,
                    width: current.width + (rect.width - current.width) * eased,
                    height: current.height + (rect.height - current.height) * eased
                )
                if willResize {
                    guard setSize(window, frame.size) else { return }
                }
                guard setPosition(window, frame.origin) else { return }
                try? await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }

            // Exact final placement (size → position → size; see setFrame).
            if willResize {
                guard setSize(window, rect.size) else { return }
            }
            guard setPosition(window, rect.origin) else { return }
            if willResize { _ = setSize(window, rect.size) }
        }
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

        // ponytail: an animated move (Loop's WindowTransformAnimation, stepping
        // the frame over a few display links) would replace these direct sets.
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
