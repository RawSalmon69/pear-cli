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
//   • zero-AX apps: when the AX union is empty, fall back to the public
//     `CGWindowListCopyWindowInfo` (DockDoor's "AX + CGS fallback" idea, public
//     APIs only). CG-only windows have no AX handle, so clicking one activates
//     the owning app rather than raising that exact window.
// Click-to-raise uses only the public kAXRaiseAction + NSRunningApplication.activate
// (DockDoor's private SkyLight _SLPSSetFrontProcessWithOptions is skipped).

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
    /// Standard, on-a-desktop windows we show. Sheets, popovers, and tooltips
    /// have other subroles and are skipped.
    private static let shownSubroles: Set<String> = [
        kAXStandardWindowSubrole as String,
        kAXDialogSubrole as String,
    ]

    /// The hovered app's windows, newest AX order. Returns `[]` on any failure
    /// (app not answering, no windows, AX denied) so the caller degrades to
    /// hiding the panel rather than crashing.
    static func enumerate(app: DockApp) -> [DockWindow] {
        var result: [DockWindow] = []

        // Multi-instance apps show one Dock icon for several processes sharing a
        // bundle id; enumerate every one, not just the pid the hover resolved.
        for pid in pids(for: app) {
            appendAXWindows(pid: pid, appName: app.name, into: &result)
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

    private static func appendAXWindows(pid: pid_t, appName: String, into result: inout [DockWindow]) {
        let appElement = AXUIElementCreateApplication(pid)
        DockAX.capTimeout(appElement)

        guard let axWindows = DockAX.elements(appElement, kAXWindowsAttribute) else { return }

        for axWindow in axWindows {
            DockAX.capTimeout(axWindow) // per-element

            let subrole = DockAX.string(axWindow, kAXSubroleAttribute)
            if let subrole, !shownSubroles.contains(subrole) { continue }

            let minimized = DockAX.bool(axWindow, kAXMinimizedAttribute) ?? false
            let size = DockAX.size(axWindow, kAXSizeAttribute)
            // A visible window must report a real size; a minimized one often
            // reports none and still earns a placeholder tile.
            let hasUsableSize = (size.map { $0.width > 1 && $0.height > 1 }) ?? false
            if !minimized, !hasUsableSize { continue }

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
