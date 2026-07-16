// Adapted from DockDoor (GPL-3.0), https://github.com/ejbills/DockDoor,
// commit 78b0862f — original: DockDoor/Utilities/DockObserver.swift.
//
// This ports ONLY DockDoor's hover DETECTION: an AXObserver on the Dock
// process's AXList subscribed to kAXSelectedChildrenChangedNotification, which
// macOS fires as the highlighted (hovered) icon changes. DockDoor's DockObserver
// also installs an always-on CGEventTap for dock-click / scroll gestures
// (setupEventTap) — that entire path is deliberately NOT ported, so this feature
// has ZERO CGEvent taps. Dock-restart recovery is event-driven (NSWorkspace app
// launch) plus a lazy re-subscribe on the next hover, instead of DockDoor's 5 s
// health-check Timer — nothing polls while idle.

import AppKit
import ApplicationServices

/// The app under the hovered Dock icon, plus that icon's screen rect in AX
/// space (top-left origin, y-down, global points).
struct DockHoverTarget {
    let app: DockApp
    let iconRectAX: CGRect
}

/// C callback for AXObserverAddNotification. Delivered on the run loop the
/// observer's source was added to — the main run loop — so `assumeIsolated` is
/// sound. Only the Sendable `refcon` pointer is captured; the DockObserver is
/// rehydrated inside the main-actor closure.
private func dockSelectionChangedCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    // Carry the observer across the isolation boundary as an integer bit
    // pattern (Sendable, copied by value — no aliasing), then rebuild the
    // pointer inside the main actor. The callback is delivered on the main run
    // loop, so `assumeIsolated` is sound.
    let bits = UInt(bitPattern: refcon)
    MainActor.assumeIsolated {
        guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        Unmanaged<DockObserver>.fromOpaque(raw).takeUnretainedValue().selectionChanged()
    }
}

/// Watches the Dock for hover changes and reports the app under the cursor.
/// Fail-alone: if Accessibility is not granted or the Dock is not answering,
/// `start()` simply installs nothing and `onHover` never fires — no crash, no
/// prompt (the tile surfaces the onboarding card instead).
@MainActor
final class DockObserver {
    /// Fired on every Dock selection change: a target when a running app's icon
    /// is hovered, `nil` when the selection clears or is not an app.
    var onHover: ((DockHoverTarget?) -> Void)?

    private var axObserver: AXObserver?
    private var dockPID: pid_t?
    private var subscribedList: AXUIElement?
    private var launchObserver: NSObjectProtocol?

    /// Installs the Dock AXObserver (only if already trusted — never prompts)
    /// and an event-driven Dock-relaunch watcher. Safe to call when untrusted:
    /// the AX subscription is skipped. Idempotent, so the settings card can
    /// call it again the moment Accessibility is granted — the tool is enabled
    /// by default, and on a fresh install trust usually arrives after launch.
    func start() {
        if launchObserver == nil {
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.apple.dock" else { return }
                MainActor.assumeIsolated { self?.resubscribe() }
            }
        }
        guard AXIsProcessTrusted(), axObserver == nil else { return }
        subscribe()
    }

    /// Full teardown: removes the run-loop source, the observer, and the launch
    /// watcher. Leaves zero residue (the tool's live-disable path calls this).
    func stop() {
        teardown()
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }
    }

    // MARK: - Subscription lifecycle

    private func teardown() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
        }
        axObserver = nil
        dockPID = nil
        subscribedList = nil
    }

    private func resubscribe() {
        teardown()
        subscribe()
    }

    private func subscribe() {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first
        else {
            return
        }
        let pid = dock.processIdentifier
        let dockElement = AXUIElementCreateApplication(pid)
        DockAX.capTimeout(dockElement)

        guard let children = DockAX.elements(dockElement, kAXChildrenAttribute),
              let axList = children.first(where: { DockAX.string($0, kAXRoleAttribute) == (kAXListRole as String) })
        else {
            return
        }

        var observer: AXObserver?
        guard AXObserverCreate(pid, dockSelectionChangedCallback, &observer) == .success,
              let observer
        else {
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverAddNotification(
            observer, axList, kAXSelectedChildrenChangedNotification as CFString, refcon
        )
        guard result == .success || result == .notificationAlreadyRegistered else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
        subscribedList = axList
        dockPID = pid
    }

    // MARK: - Hover resolution

    func selectionChanged() {
        onHover?(hoverTarget())
    }

    /// Resolves the currently hovered Dock icon into a running-app target, or
    /// `nil` when nothing app-like is hovered.
    private func hoverTarget() -> DockHoverTarget? {
        guard let dockPID else { return nil }
        let dockElement = AXUIElementCreateApplication(dockPID)
        DockAX.capTimeout(dockElement)

        // The Dock application's first child is the icon list; its selected
        // child is the hovered item.
        guard let listChildren = DockAX.elements(dockElement, kAXChildrenAttribute),
              let list = listChildren.first,
              let selected = DockAX.elements(list, kAXSelectedChildrenAttribute),
              let item = selected.first
        else {
            return nil
        }

        guard DockAX.string(item, kAXSubroleAttribute) == "AXApplicationDockItem" else { return nil }
        guard let app = runningApp(for: item) else { return nil }

        guard let size = DockAX.size(item, kAXSizeAttribute) else { return nil }
        let origin = DockAX.point(item, kAXPositionAttribute) ?? .zero
        return DockHoverTarget(app: DockApp(app), iconRectAX: CGRect(origin: origin, size: size))
    }

    /// The running app for a hovered Dock item: by bundle id from its URL, else
    /// by localized name. `nil` when the app is not running (v1 shows nothing
    /// for not-running apps).
    private func runningApp(for item: AXUIElement) -> NSRunningApplication? {
        if let url = DockAX.url(item, kAXURLAttribute),
           let bundleID = Bundle(url: url)?.bundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        {
            return app
        }
        if let title = DockAX.string(item, kAXTitleAttribute) {
            return NSWorkspace.shared.runningApplications.first { $0.localizedName == title }
        }
        return nil
    }
}
