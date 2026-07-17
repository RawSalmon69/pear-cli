// Adapted from DockDoor (GPL-3.0), https://github.com/ejbills/DockDoor,
// commit 78b0862f — original: DockDoor/Extensions/AXUIElement.swift
// (allWindows / windowsByBruteForce), Utilities/DockObserver.swift
// (ApplicationInfo), and Utilities/Window Management/{WindowUtil,WindowInfo}.swift.
//
// DockDoor's WindowInfo holds AXUIElement / NSRunningApplication / SCWindow and
// is passed across Task boundaries, which does not compile under Swift 6 strict
// concurrency. This port keeps the reference-bearing window model (`DockWindow`)
// strictly on the main actor and crosses task boundaries only with the thin
// Sendable `DockApp` snapshot — DockDoor's own `ApplicationInfo: Sendable`
// pattern, generalized.
//
// Coverage widening (was: single-pid `kAXWindowsAttribute` only) mirrors
// DockDoor's `AXUIElement.allWindows`, minus its private-API `windowsByBruteForce`
// (which relies on `_AXUIElementCreateWithRemoteToken` / `_AXUIElementGetWindow`
// — banned here). The public-API analogue:
//   • multi-instance apps: union AX windows across EVERY running process that
//     shares the hovered icon's bundle id, not just the one pid the hover
//     resolved (DockDoor's WindowOwnerResolver display-app grouping),
//   • minimized windows: kept even when AX reports no usable frame (they have
//     no live SCK frame — the tile falls back to icon + minimized badge),
//   • fullscreen windows: a native-fullscreen window sits on its own Space, so
//     a cross-Space AX geometry read can come back empty; it is kept anyway
//     (via the "AXFullScreen" window attribute) instead of being dropped by the
//     usable-size gate. Public-API limits, documented not worked around: SCK
//     capture and the CGWindowList fallback below both see the CURRENT Space
//     only, so a fullscreen window on an UNFOCUSED Space shows as an icon tile
//     with no thumbnail, and if AX itself returns no window for an off-Space
//     app there is no public way to recover it,
//   • zero-AX apps: when the AX union is empty, fall back to the public
//     `CGWindowListCopyWindowInfo` (DockDoor's "AX + CGS fallback" idea, public
//     APIs only). CG-only windows have no AX handle, so clicking one activates
//     the owning app rather than raising that exact window,
//   • floating-window apps (2.6.3): the subrole allow-list (`shownSubroles`) now
//     admits `kAXFloatingWindowSubrole` / `kAXSystemFloatingWindowSubrole`, so
//     apps whose only windows are floating/utility windows get a preview with
//     real click-to-raise. Before, they were dropped by the allow-list and — if
//     the window sat on a non-zero CG layer — missed by the fallback too (the
//     fallback only runs when the AX union is empty AND only keeps layer-0
//     windows), i.e. no preview at all.
//   • never-activated apps (the activation-state gap): a background app's AX
//     window list can read empty until its AX server wakes, Chromium/Electron
//     build the tree lazily until an assistive client opts in, and cross-Space
//     geometry reads can fail — all three made the first hover find nothing
//     until the app was clicked once. Covered by (1) the "AXManualAccessibility"
//     poke in `appendAXWindows`, (2) keeping nil-size (read-failed) windows in
//     `shouldShow`, and (3) the hover controller's retry-while-hovering loop
//     (upstream DockDoor/alt-tab-macos retry `.cannotComplete` the same way).
// Click-to-raise uses only the public kAXRaiseAction + NSRunningApplication.activate
// (DockDoor's private SkyLight _SLPSSetFrontProcessWithOptions is skipped).
//
// Honest public-API limits that remain (not worked around; no private API can
// fix them from here):
//   • windows owned by a DIFFERENTLY-BUNDLED helper process. The pid union
//     (`pids(for:)`) covers same-bundle-id siblings only; if the Dock tile's app
//     and the window's owner have different bundle ids (some agent/XPC-hosted
//     UIs), neither the AX pass nor the pid-filtered CG fallback sees the window.
//   • an app that exposes NOTHING to AX whose windows are also off the current
//     Space or on a non-zero CG layer: the CG fallback is on-screen + layer-0
//     only, so there is nothing left to recover.
//   • off-Space windows in general: both SCK capture and the on-screen CG list
//     see the CURRENT Space only, so a window on an unfocused Space shows (at
//     best) as an icon tile with no thumbnail, and if AX also returns nothing
//     for it there is no public way to list it.

import AppKit
import ApplicationServices
import CoreGraphics

/// Thin Sendable snapshot of a running app. This is the only app data that
/// crosses an isolation boundary (e.g. into the thumbnail-capture task); the
/// live `NSRunningApplication` is re-hydrated from the pid on the far side.
struct DockApp: Sendable, Equatable {
    let pid: pid_t
    let bundleIdentifier: String?
    let name: String

    init(pid: pid_t, bundleIdentifier: String?, name: String) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }

    init(_ app: NSRunningApplication) {
        pid = app.processIdentifier
        bundleIdentifier = app.bundleIdentifier
        name = app.localizedName ?? ""
    }

    /// Re-hydrate the live app instance on whichever actor needs it.
    func hydrate() -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
    }
}

/// One window of the hovered app: the AX handle used to raise it, plus the
/// metadata the preview tile shows. Holds a non-Sendable `AXUIElement`, so it
/// lives only on the main actor and never crosses a task boundary.
@MainActor
struct DockWindow: Identifiable {
    let id: Int
    /// nil for a CGWindowList-fallback window (an app that exposed no AX
    /// windows): there is no public way to raise that exact window, so `raise`
    /// degrades to activating the owning app.
    let axElement: AXUIElement?
    let title: String
    /// Window frame in AX space (top-left origin, y-down), global points.
    let frame: CGRect
    let isMinimized: Bool

    /// Raise this window using public APIs only: activate the owning app, then
    /// perform the AX raise when we hold a window handle. Silent on failure —
    /// never crashes, never retries.
    func raise(app: DockApp) {
        app.hydrate()?.activate()
        guard let axElement else { return }
        AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(axElement, kAXMainWindowAttribute as CFString, kCFBooleanTrue)
    }
}

/// One row of the ⌥-tab switcher: a window plus the app it belongs to (needed
/// for the tile's icon and to activate the app when the window is chosen).
@MainActor
struct DockSwitcherEntry: Identifiable {
    let id: Int
    let app: DockApp
    let window: DockWindow
}

/// Cache-free AX window enumeration for one app, on the main actor.
@MainActor
enum DockWindows {
    /// Top-level windows we show. The four AX window subroles that represent a
    /// real, user-facing window: standard, dialog, and the two floating-window
    /// subroles (utility / tool / inspector / palette windows some apps use as
    /// their primary surface — e.g. Font Book's font window, media tools). Only
    /// the floating pair was widened here (2.6.3): a floating-window-only app was
    /// dropped by the allow-list and, when its window sat on a non-standard CG
    /// layer, missed by the fallback too, so it got no preview at all. Sheets
    /// (`AXSheet`), popovers, and unknown transient surfaces are still excluded,
    /// so no tooltip / popover noise; a nil subrole (read failed) is tolerated by
    /// `shouldShow`, not filtered.
    private static let shownSubroles: Set<String> = [
        kAXStandardWindowSubrole as String,
        kAXDialogSubrole as String,
        kAXFloatingWindowSubrole as String,
        kAXSystemFloatingWindowSubrole as String,
    ]

    /// AX window attribute for the native-fullscreen state. There is no public
    /// SDK constant for it (only `kAXFullScreenButtonAttribute`, the green
    /// button element), so the stable literal is read through the fully public
    /// `AXUIElementCopyAttributeValue` — the same pattern this codebase already
    /// uses for `"AXTrustedCheckOptionPrompt"`. No private AX functions involved.
    private static let axFullScreenAttribute = "AXFullScreen"

    /// Hard wall-clock ceiling for one enumeration pass. Every AX read here is
    /// synchronous on the main actor, so without a budget an app with several
    /// unresponsive same-bundle-id helper pids could stack per-call timeouts
    /// into a multi-second main-thread stall on a single hover. When the budget
    /// runs out mid-pass, whatever was gathered so far is returned — the hover
    /// controller's retry loop picks up the rest on a later attempt.
    static let enumerationBudget: Duration = .milliseconds(400)

    /// Pids already sent the AXManualAccessibility opt-in this session. The
    /// poke is only needed once per process — repeating it on every retry
    /// attempt just burns another capped AX call on an app that ignores it.
    private static var pokedPIDs = Set<pid_t>()

    /// The hovered app's windows, newest AX order. Returns `[]` on any failure
    /// (app not answering, no windows, AX denied) so the caller degrades to
    /// hiding the panel rather than crashing.
    static func enumerate(app: DockApp) -> [DockWindow] {
        let deadline = ContinuousClock.now + enumerationBudget
        var result: [DockWindow] = []

        // Multi-instance apps show one Dock icon for several processes sharing a
        // bundle id; enumerate every one, not just the pid the hover resolved.
        for pid in pids(for: app) {
            guard ContinuousClock.now < deadline else { break }
            appendAXWindows(pid: pid, appName: app.name, deadline: deadline, into: &result)
        }

        // Zero-AX apps (some Electron/Java/Adobe surfaces expose no AX window
        // list): fall back to the public on-screen window list.
        if result.isEmpty {
            appendCGFallbackWindows(app: app, into: &result)
        }

        return result
    }

    // MARK: - Switcher enumeration (all / active-app windows)

    /// The window list the ⌥-tab switcher cycles through, in a stable order:
    /// the frontmost app's windows first, then the other regular apps'. Reuses
    /// the same widened `enumerate(app:)`, so multi-instance and zero-AX apps
    /// are covered here too.
    static func switcherEntries(scope: DockSwitcherScope) -> [DockSwitcherEntry] {
        var entries: [DockSwitcherEntry] = []
        for app in switcherApps(scope: scope) {
            for window in enumerate(app: app) {
                entries.append(DockSwitcherEntry(id: entries.count, app: app, window: window))
            }
        }
        return entries
    }

    /// Apps to enumerate for the switcher, frontmost first, deduped by bundle id
    /// (a multi-instance app's sibling pids are already unioned by `enumerate`).
    private static func switcherApps(scope: DockSwitcherScope) -> [DockApp] {
        let frontmost = NSWorkspace.shared.frontmostApplication
        switch scope {
        case .activeApp:
            return frontmost.map { [DockApp($0)] } ?? []
        case .allWindows:
            let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            let front = regular.filter { $0.processIdentifier == frontmost?.processIdentifier }
            let rest = regular.filter { $0.processIdentifier != frontmost?.processIdentifier }

            var seen = Set<String>()
            var apps: [DockApp] = []
            for app in front + rest {
                let key = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
                guard seen.insert(key).inserted else { continue }
                apps.append(DockApp(app))
            }
            return apps
        }
    }

    /// Every pid that shares the hovered app's Dock icon: the resolved pid plus
    /// any sibling process with the same bundle id. Deduped, resolved pid first.
    static func pids(for app: DockApp) -> [pid_t] {
        var pids = [app.pid]
        if let bundleID = app.bundleIdentifier {
            for sibling in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                where sibling.processIdentifier != app.pid && sibling.processIdentifier > 0
            {
                pids.append(sibling.processIdentifier)
            }
        }
        return pids
    }

    // MARK: - AX enumeration

    private static func appendAXWindows(
        pid: pid_t, appName: String, deadline: ContinuousClock.Instant, into result: inout [DockWindow]
    ) {
        let appElement = AXUIElementCreateApplication(pid)
        DockAX.capTimeout(appElement)

        guard let axWindows = DockAX.elements(appElement, kAXWindowsAttribute), !axWindows.isEmpty else {
            // Activation-state gap, prong 1: Chromium/Electron apps build their
            // AX tree lazily, so a never-activated app's window list reads empty
            // (or fails) until the user clicks it once — "hover shows nothing
            // until I click the app first." Electron's documented opt-in for
            // assistive clients is setting the app-level "AXManualAccessibility"
            // attribute (public AXUIElementSetAttributeValue + stable literal,
            // the "AXFullScreen" pattern above). Non-Electron apps return an
            // error, deliberately ignored. Once per pid per session: the tree
            // builds asynchronously and the hover controller's
            // retry-while-hovering picks the windows up on a later attempt, so
            // repeating the poke each retry just burned another capped AX call.
            if pokedPIDs.insert(pid).inserted {
                AXUIElementSetAttributeValue(
                    appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            return
        }

        for axWindow in axWindows {
            // ~6 capped reads per window; stop mid-list when the pass budget is
            // spent rather than stalling through a long window list.
            guard ContinuousClock.now < deadline else { return }
            DockAX.capTimeout(axWindow) // per-element

            let subrole = DockAX.string(axWindow, kAXSubroleAttribute)
            let minimized = DockAX.bool(axWindow, kAXMinimizedAttribute) ?? false
            let fullScreen = DockAX.bool(axWindow, axFullScreenAttribute) ?? false
            let size = DockAX.size(axWindow, kAXSizeAttribute)
            guard shouldShow(subrole: subrole, minimized: minimized, fullScreen: fullScreen, size: size) else {
                continue
            }

            let position = DockAX.point(axWindow, kAXPositionAttribute) ?? .zero
            let title = DockAX.string(axWindow, kAXTitleAttribute) ?? appName

            result.append(DockWindow(
                id: result.count,
                axElement: axWindow,
                title: title.isEmpty ? appName : title,
                frame: CGRect(origin: position, size: size ?? .zero),
                isMinimized: minimized
            ))
        }
    }

    /// Whether an enumerated AX window earns a preview tile. Pure, so the
    /// subrole / size / minimized / fullscreen policy is unit-testable without a
    /// live app.
    ///
    /// A normal on-desktop window must report a real size. Minimized and
    /// native-fullscreen windows are kept even when the size read comes back
    /// empty: a fullscreen window lives on its own Space, where a cross-Space AX
    /// geometry read can return nothing, yet it is still a real window worth a
    /// tile (falling back to icon + title, like a minimized one). Fullscreen
    /// bypasses the size gate, never the subrole allow-list.
    ///
    /// A nil size (the READ failed) is also kept: a background app's windows on
    /// another Space can fail the geometry read until the app is activated —
    /// the same activation-state gap as fullscreen, and previously the reason a
    /// hover showed nothing until the app was clicked once. Junk windows report
    /// a SUCCESSFUL degenerate size and still fall to the `> 1` gate.
    static func shouldShow(subrole: String?, minimized: Bool, fullScreen: Bool, size: CGSize?) -> Bool {
        if let subrole, !shownSubroles.contains(subrole) { return false }
        if minimized || fullScreen { return true }
        guard let size else { return true }
        return size.width > 1 && size.height > 1
    }

    // MARK: - CGWindowList fallback (public API)

    private static func appendCGFallbackWindows(app: DockApp, into result: inout [DockWindow]) {
        let pidSet = Set(pids(for: app))
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        for fallback in parseFallback(info, pids: pidSet) {
            result.append(DockWindow(
                id: result.count,
                axElement: nil,
                title: fallback.title.isEmpty ? app.name : fallback.title,
                frame: fallback.frame,
                isMinimized: false
            ))
        }
    }

    /// One on-screen window recovered from the public window list.
    struct CGFallbackWindow: Equatable {
        let title: String
        /// Frame in CG global space (top-left origin, y-down) — the same space
        /// AX and SCK report, so thumbnail matching still works.
        let frame: CGRect
    }

    /// Pure filter over `CGWindowListCopyWindowInfo` output: normal-layer
    /// (layer 0) windows owned by one of `pids`, with a usable frame. Extracted
    /// so the pid/layer/bounds logic is unit-testable without a live window
    /// server.
    static func parseFallback(_ infoList: [[String: Any]], pids: Set<pid_t>) -> [CGFallbackWindow] {
        var windows: [CGFallbackWindow] = []
        for entry in infoList {
            guard let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pids.contains(ownerPID) else { continue }
            // Layer 0 is the normal window layer; menus, the Dock, and shadows
            // live on other layers and must not appear as previews.
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = cgRect(from: boundsDict),
                  frame.width > 1, frame.height > 1 else { continue }
            let title = (entry[kCGWindowName as String] as? String) ?? ""
            windows.append(CGFallbackWindow(title: title, frame: frame))
        }
        return windows
    }

    /// A `kCGWindowBounds` dictionary (`{X, Y, Width, Height}`, the shape the
    /// window server and `CGRect(dictionaryRepresentation:)` both use) → CGRect.
    private static func cgRect(from dict: [String: Any]) -> CGRect? {
        guard let x = (dict["X"] as? NSNumber)?.doubleValue,
              let y = (dict["Y"] as? NSNumber)?.doubleValue,
              let w = (dict["Width"] as? NSNumber)?.doubleValue,
              let h = (dict["Height"] as? NSNumber)?.doubleValue else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
