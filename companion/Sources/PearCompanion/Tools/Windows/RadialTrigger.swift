// Adapted from Loop (GPL-3.0), https://github.com/MrKai77/Loop
//
// The hold-to-summon flow adapts Loop's trigger pipeline:
//   • `KeybindTrigger`: watch flagsChanged for the trigger key — open on
//     press, apply-and-close on release, Escape force-closes.
//   • `TriggerDelayTimer`: arm only after a short delay so plain taps of the
//     modifier never flash the ring.
//   • `MouseInteractionObserver`: while open, map the cursor's offset from
//     the press point into a direction (outer band), the center action
//     (middle band), or no selection (cursor still at the press point);
//     a left click near the center picks the center-special action.
// Loop consumes events through a CGEvent tap; we deliberately use read-only
// NSEvent monitors instead — same Accessibility permission the engine
// already needs, no tap — so key events also reach the frontmost app.
// That is acceptable for feedback-only UI and keeps the always-on cost to a
// single flagsChanged observer: the mouse/key monitors exist only between
// trigger-down and release.

import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Trigger key choice

/// Which held key summons the radial ring. Persisted in UserDefaults;
/// `current(from:)` takes the store so the resolution logic is testable.
enum RadialTriggerKey: String, CaseIterable, Identifiable {
    case fnGlobe
    case rightCommand
    case rightOption
    case controlOption

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fnGlobe: "Fn / Globe"
        case .rightCommand: "Right ⌘"
        case .rightOption: "Right ⌥"
        case .controlOption: "⌃ + ⌥"
        }
    }

    static let defaultsKey = "windows.radialTriggerKey"

    /// Loop defaults to the Fn/Globe key; so do we.
    static func current(from defaults: UserDefaults = .standard) -> RadialTriggerKey {
        defaults.string(forKey: defaultsKey).flatMap(RadialTriggerKey.init) ?? .fnGlobe
    }

    /// Whether `flags` holds this trigger. Right-side detection uses the
    /// device-dependent bits carried by real events (NX_DEVICERCMDKEYMASK /
    /// NX_DEVICERALTKEYMASK); pure over the flags value.
    func isHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .fnGlobe:
            flags.contains(.function)
        case .rightCommand:
            flags.contains(.command) && flags.rawValue & 0x0010 != 0
        case .rightOption:
            flags.contains(.option) && flags.rawValue & 0x0040 != 0
        case .controlOption:
            flags.contains(.control) && flags.contains(.option)
        }
    }

    /// Side-agnostic variant for the stuck-session watchdog, which reads
    /// `NSEvent.modifierFlags` (no device-dependent bits there).
    func isHeldIgnoringSide(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .fnGlobe: flags.contains(.function)
        case .rightCommand: flags.contains(.command)
        case .rightOption: flags.contains(.option)
        case .controlOption: flags.contains(.control) && flags.contains(.option)
        }
    }
}

// MARK: - Trigger

/// Hold the trigger key → ring at the cursor + preview on the target screen;
/// aim with the mouse or arrows; release to snap; Escape cancels. Owned by
/// WindowsTool for the process lifetime.
@MainActor
final class RadialTrigger {
    /// Hold this long before the ring appears, so taps don't trigger
    /// (Loop's trigger delay). Reads the live "windows.triggerDelay" pref at
    /// use time; defaults to 100 ms, the prior fixed value.
    private static var holdDelay: Duration {
        .seconds(WindowSettings.triggerDelay())
    }
    /// Inside this radius the cursor hasn't meaningfully moved: no selection
    /// (Loop's 10 pt no-action distance).
    private static let noSelectionRadius: CGFloat = 10
    /// Between the radii: `.center`. Beyond: directional sectors
    /// (Loop's 50 pt directional distance, minus its ring thickness).
    private static let deadzoneRadius: CGFloat = 40

    private let ring = RadialRingController()
    private let preview = ZonePreviewController()

    /// Always-on flagsChanged monitors (installed once in `start()`).
    private var flagsMonitors: [Any] = []
    /// Mouse/key monitors that exist only while the trigger is held.
    private var trackingMonitors: [Any] = []
    /// Consumes ring-handled keys while the session is open, so arrows and
    /// Escape don't leak into the frontmost app. nil = tap unavailable,
    /// running on the read-only fallback monitors.
    private var keyTap: KeySwallowTap?
    private var holdTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var lastFlags: NSEvent.ModifierFlags = []
    private var session: Session?

    /// State for one hold. Reference type so handlers mutate in place.
    private final class Session {
        let origin: NSPoint
        let target: WindowEngine.SnapTarget?
        var selection: WindowZone?
        var lastAngle: Double?
        var sweep: Double = 0
        /// Where a maximize latch was set; selection holds until the cursor
        /// crosses to the other side of the deadzone edge.
        var latch: Latch?

        enum Latch { case insideDeadzone, outsideDeadzone }

        init(origin: NSPoint, target: WindowEngine.SnapTarget?) {
            self.origin = origin
            self.target = target
        }
    }

    // MARK: Lifecycle

    /// Installs the one always-on observer pair. Without Accessibility the
    /// global monitor simply never delivers events (macOS withholds them),
    /// and `activate()` re-checks trust anyway — the tool degrades to
    /// exactly its pre-ring behavior.
    func start() {
        guard flagsMonitors.isEmpty else { return }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.flagsChanged(event)
        }) {
            flagsMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.flagsChanged(event)
            return event
        }) {
            flagsMonitors.append(monitor)
        }
    }

    /// Teardown mirror of `start()`: cancel a pending hold, close any open
    /// session, and drop the always-on flags monitors so a later `start()`
    /// (guarded on `flagsMonitors.isEmpty`) can re-install them on re-enable.
    func stop() {
        holdTask?.cancel()
        holdTask = nil
        teardown()
        for monitor in flagsMonitors { NSEvent.removeMonitor(monitor) }
        flagsMonitors = []
    }

    // MARK: Trigger edge detection

    private func flagsChanged(_ event: NSEvent) {
        let key = RadialTriggerKey.current()
        lastFlags = event.modifierFlags

        if key.isHeld(event.modifierFlags) {
            guard session == nil, holdTask == nil else { return }
            // Some keyboards raise .function on arrow/nav keys (see Loop's
            // `isFnSpecialKey`); only the Fn key itself may arm the ring.
            if key == .fnGlobe, event.keyCode != UInt16(kVK_Function) { return }
            holdTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.holdDelay)
                guard let self, !Task.isCancelled else { return }
                self.holdTask = nil
                // Still held after the delay? Then it's a hold, not a tap.
                guard key.isHeld(self.lastFlags) else { return }
                self.activate()
            }
        } else {
            holdTask?.cancel()
            holdTask = nil
            if session != nil { commit() }
        }
    }

    // MARK: Session

    private func activate() {
        guard session == nil, WindowEngine.isTrusted else { return }

        let origin = NSEvent.mouseLocation
        session = Session(origin: origin, target: WindowEngine.snapTarget())

        ring.show(at: origin)
        if let target = session?.target {
            preview.show(on: target.screen)
        }
        installTrackingMonitors()
        startWatchdog()
    }

    /// Release → snap to the previewed zone (if any) via the shared engine.
    private func commit() {
        guard let session else { return }
        let selection = session.selection
        teardown()
        if let selection { WindowEngine.apply(selection) }
    }

    /// Escape → close without applying.
    private func cancel() {
        teardown()
    }

    private func teardown() {
        for monitor in trackingMonitors { NSEvent.removeMonitor(monitor) }
        trackingMonitors = []
        keyTap?.invalidate()
        keyTap = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        ring.hide()
        preview.hide()
        session = nil
    }

    /// Global monitors go silent during secure input and some system UI, so
    /// a release can be missed. Poll the live modifier state while a session
    /// is open and commit if the trigger is provably up (Loop solves the
    /// same wedge with its TriggerKeyTimeoutTimer).
    private func startWatchdog() {
        let key = RadialTriggerKey.current()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.session != nil else { return }
                if !key.isHeldIgnoringSide(NSEvent.modifierFlags) {
                    self.commit()
                    return
                }
            }
        }
    }

    // MARK: Tracking (only while the trigger is held — 0% idle cost)

    private func installTrackingMonitors() {
        let mouseMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] _ in
            self?.handleMouseMoved()
        }) {
            trackingMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask, handler: { [weak self] event in
            self?.handleMouseMoved()
            return event
        }) {
            trackingMonitors.append(monitor)
        }

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            self?.handleMouseDown()
        }) {
            trackingMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            self?.handleMouseDown()
            return event
        }) {
            trackingMonitors.append(monitor)
        }

        // Keys: a session-scoped event tap consumes the ring's keys system-wide
        // (arrows/Escape must not leak into the frontmost app). If the tap
        // can't be created, degrade to the read-only monitors — the ring still
        // works, handled keys just pass through underneath.
        keyTap = KeySwallowTap { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        if keyTap == nil {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                _ = self?.handleKeyDown(event)
            }) {
                trackingMonitors.append(monitor)
            }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                (self?.handleKeyDown(event) ?? false) ? nil : event
            }) {
                trackingMonitors.append(monitor)
            }
        }
    }

    private func handleMouseMoved() {
        guard let session else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - session.origin.x
        let dy = mouse.y - session.origin.y
        let magnitude = ((dx * dx) + (dy * dy)).squareRoot()
        let inDeadzone = magnitude <= Self.deadzoneRadius

        // Full-circle sweep → maximize (Loop's namesake gesture).
        if !inDeadzone {
            let angle = atan2(Double(dy), Double(dx)) * 180 / .pi
            if let last = session.lastAngle {
                session.sweep += WindowZone.wrappedAngleDelta(from: last, to: angle)
            }
            session.lastAngle = angle
            if abs(session.sweep) >= 360 {
                session.sweep = 0
                session.latch = .outsideDeadzone
                select(.maximize)
                return
            }
        } else {
            session.lastAngle = nil
            session.sweep = 0
        }

        // A latched maximize holds until the cursor crosses the deadzone
        // edge away from where it latched; then normal selection resumes.
        if let latch = session.latch {
            let stillLatched = (latch == .outsideDeadzone && !inDeadzone)
                || (latch == .insideDeadzone && inDeadzone)
            if stillLatched { return }
            session.latch = nil
        }

        let selection: WindowZone? = magnitude <= Self.noSelectionRadius
            ? nil
            : WindowZone.radialZone(dx: dx, dy: dy, deadzone: Self.deadzoneRadius)
        select(selection)
    }

    /// Center-click → toggle the focused window's native fullscreen (the
    /// green-button behavior: enter, or exit back to the desktop it came from).
    /// Commits immediately and closes the ring, like a released selection —
    /// the maximize / "fake fullscreen" zone stays reachable via ⌃⌥↑, the grid,
    /// and the full-circle sweep.
    private func handleMouseDown() {
        guard let session else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - session.origin.x
        let dy = mouse.y - session.origin.y
        guard ((dx * dx) + (dy * dy)).squareRoot() <= Self.deadzoneRadius else { return }
        teardown()
        WindowEngine.toggleFullscreen()
    }

    /// Returns true when the key was handled (and should be swallowed
    /// locally). Arrows refine the selection; Escape cancels.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard session != nil else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape:
            cancel()
            return true
        case kVK_LeftArrow: return arrowSelect(.left)
        case kVK_RightArrow: return arrowSelect(.right)
        case kVK_UpArrow: return arrowSelect(.up)
        case kVK_DownArrow: return arrowSelect(.down)
        default:
            return false
        }
    }

    private func arrowSelect(_ arrow: RadialArrow) -> Bool {
        guard let session else { return false }
        session.latch = nil
        select(WindowZone.arrowSelection(current: session.selection, arrow: arrow))
        return true
    }

    /// Single choke point: updates the session, the ring highlight, and the
    /// preview frame together.
    private func select(_ zone: WindowZone?) {
        guard let session, session.selection != zone else { return }
        session.selection = zone
        ring.highlight(zone)
        guard let target = session.target else { return }
        preview.update(zone.map { previewRect(for: $0, target: target) })
    }

    /// The would-be frame in global AppKit space — the same resolution
    /// `WindowEngine.apply` performs on release.
    private func previewRect(for zone: WindowZone, target: WindowEngine.SnapTarget) -> NSRect {
        let visible = target.screen.visibleFrame
        return zone.resizes
            ? zone.frame(in: visible)
            : WindowZone.centered(target.windowFrame.size, in: visible)
    }
}
