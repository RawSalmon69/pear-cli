// Adapted from DockDoor (GPL-3.0), https://github.com/ejbills/DockDoor,
// commit 78b0862f — original: DockDoor/Extensions/AXUIElement.swift,
// Utilities/DockObserver.swift (ApplicationInfo), and
// Utilities/Window Management/{WindowUtil,WindowInfo}.swift.
//
// DockDoor's WindowInfo holds AXUIElement / NSRunningApplication / SCWindow and
// is passed across Task boundaries, which does not compile under Swift 6 strict
// concurrency. This port keeps the reference-bearing window model (`DockWindow`)
// strictly on the main actor and crosses task boundaries only with the thin
// Sendable `DockApp` snapshot — DockDoor's own `ApplicationInfo: Sendable`
// pattern, generalized. Window enumeration is a fresh, cache-free AX read
// (DockDoor's warm-cache layer is dropped for v1); click-to-raise uses only the
// public kAXRaiseAction + NSRunningApplication.activate (DockDoor's private
// SkyLight _SLPSSetFrontProcessWithOptions is skipped).

import AppKit
import ApplicationServices

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
    let axElement: AXUIElement
    let title: String
    /// Window frame in AX space (top-left origin, y-down), global points.
    let frame: CGRect
    let isMinimized: Bool

    /// Raise this window using public APIs only: activate the owning app, then
    /// perform the AX raise. Silent on failure — never crashes, never retries.
    func raise(app: DockApp) {
        app.hydrate()?.activate()
        AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(axElement, kAXMainWindowAttribute as CFString, kCFBooleanTrue)
    }
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
        let appElement = AXUIElementCreateApplication(app.pid)
        DockAX.capTimeout(appElement)

        guard let axWindows = DockAX.elements(appElement, kAXWindowsAttribute) else { return [] }

        var result: [DockWindow] = []
        for axWindow in axWindows {
            DockAX.capTimeout(axWindow) // per-element

            let subrole = DockAX.string(axWindow, kAXSubroleAttribute)
            if let subrole, !shownSubroles.contains(subrole) { continue }

            guard let size = DockAX.size(axWindow, kAXSizeAttribute), size.width > 1, size.height > 1 else { continue }
            let position = DockAX.point(axWindow, kAXPositionAttribute) ?? .zero
            let minimized = DockAX.bool(axWindow, kAXMinimizedAttribute) ?? false
            let title = DockAX.string(axWindow, kAXTitleAttribute) ?? app.name

            result.append(DockWindow(
                id: result.count,
                axElement: axWindow,
                title: title.isEmpty ? app.name : title,
                frame: CGRect(origin: position, size: size),
                isMinimized: minimized
            ))
        }
        return result
    }
}
