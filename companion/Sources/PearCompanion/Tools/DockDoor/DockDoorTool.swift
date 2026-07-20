import AppKit
import SwiftUI

/// Dock hover-preview. Hovering a Dock icon shows that app's windows as
/// thumbnails above the Dock; clicking one raises it. On by default — it only
/// observes (never mutates system state) and never prompts: until Pear is
/// trusted for Accessibility the observer no-ops and the tile shows an
/// onboarding card, whose grant flow restarts the observer live.
///
/// The always-on cost while enabled is a single Dock AXObserver; nothing polls.
/// `stop()` (which the registry calls on live-disable) tears the observer, the
/// panel, and every pending timer down completely.
@MainActor
final class DockDoorTool: Tool {
    let id = "dockdoor"
    let title = "Dock Preview"
    let icon = "dock.rectangle"
    let category = ToolCategory.system
    let summary = "Hover a Dock icon to preview its windows."
    let hotkey: HotKeyChord? = nil

    private let controller = DockHoverController()

    func start() {
        controller.start()
    }

    func stop() {
        controller.stop()
    }

    var entry: ToolEntry {
        // onTrusted: the permission card just confirmed Accessibility, so the
        // (idempotent) start path can install the Dock observer live.
        .popover { [controller] in
            AnyView(DockDoorSettingsView(onTrusted: { controller.start() }))
        }
    }
}

/// Wires Dock hover → window enumeration → thumbnail capture → panel, with a
/// hover-intent show delay and a short hide grace so moving from the icon into
/// the panel never flickers. Everything runs on the main actor; the only value
/// that crosses into the (off-main) capture task is the Sendable `DockApp`
/// snapshot plus per-window frames.
@MainActor
final class DockHoverController {
    private let observer = DockObserver()
    private let panel = DockPreviewPanel()

    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var clickMonitors: [Any] = []
    /// pid a scheduled/retrying show is in flight for; nil when idle or shown.
    private var pendingShowPID: pid_t?

    /// Grace period before hiding, so the cursor can cross the gap between the
    /// Dock icon and the panel (which cancels the hide) without a flicker.
    private static let hideGraceMs = 180

    func start() {
        observer.onHover = { [weak self] target in self?.hoverChanged(target) }
        panel.model.onHoverChange = { [weak self] inside in self?.panelHoverChanged(inside) }
        panel.onEsc = { [weak self] in self?.hideNow() }
        observer.start()
    }

    func stop() {
        showTask?.cancel(); showTask = nil
        hideTask?.cancel(); hideTask = nil
        pendingShowPID = nil
        removeClickMonitors()
        observer.stop()
        panel.hide()
        panel.model.onHoverChange = nil
    }

    // MARK: - Hover intent (pure decision + scheduling)

    /// What a hover event should do given the app under the cursor, the app
    /// currently shown, and the app a show (with its cold-AX retry loop) is
    /// already in flight for. Pure — unit-tested without a live Dock.
    ///
    /// `pendingPID` matters for cold apps: during the retry loop nothing is
    /// shown yet (`shownPID` nil), so without it a re-hover of the SAME icon
    /// would read as `.show` and restart the retry budget from zero — jiggling
    /// the cursor on a slow Electron icon could starve it forever.
    enum HoverAction: Equatable {
        case show // an app icon, different from what's shown or pending
        case keep // the app that's already shown or already being shown
        case hide // nothing app-like under the cursor
    }

    static func action(hoveredPID: pid_t?, shownPID: pid_t?, pendingPID: pid_t?) -> HoverAction {
        guard let hoveredPID else { return .hide }
        return (hoveredPID == shownPID || hoveredPID == pendingPID) ? .keep : .show
    }

    private func hoverChanged(_ target: DockHoverTarget?) {
        switch Self.action(
            hoveredPID: target?.app.pid, shownPID: panel.shownPID, pendingPID: pendingShowPID
        ) {
        case .hide:
            // Keep-open mode: leaving the icon doesn't dismiss — the panel
            // stays until Esc, a tile click, or a click anywhere else (the
            // click-outside monitors installed in `present`).
            if !DockDoorSettings.keepPanelOpen() { scheduleHide() }
        case .keep:
            cancelHide()
        case .show:
            guard let target else { return }
            cancelHide()
            // Different app: drop the old app's tiles NOW. Leaving them up
            // while the new app's retry loop runs floated the previous app's
            // windows over the wrong icon for up to ~1.5 s.
            if panel.shownPID != nil { panel.hide() }
            scheduleShow(target)
        }
    }

    private func panelHoverChanged(_ inside: Bool) {
        if inside {
            cancelHide()
        } else if !DockDoorSettings.keepPanelOpen() {
            scheduleHide()
        }
    }

    // MARK: - Show / hide

    private func scheduleShow(_ target: DockHoverTarget) {
        showTask?.cancel()
        pendingShowPID = target.app.pid
        let delayMs = Int(DockDoorSettings.hoverDelay())
        showTask = Task { [weak self] in
            if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
            guard !Task.isCancelled, let self else { return }
            await present(target)
            // Clear only if a newer show hasn't already claimed the slot.
            if self.pendingShowPID == target.app.pid { self.pendingShowPID = nil }
        }
    }

    /// Cold-AX retry budget: a never-activated app's window list can read empty
    /// until its AX server wakes (the first query wakes it) or, for
    /// Chromium/Electron, until the AXManualAccessibility poke takes effect
    /// (`DockWindows.appendAXWindows`). Retrying only while the list is empty
    /// costs nothing visible — the panel had nothing to show anyway — and the
    /// show task is cancelled the moment the cursor moves on, so retries never
    /// outlive the hover. 5 × 250 ms comfortably covers an Electron tree build.
    private static let emptyRetryAttempts = 5
    private static let emptyRetryDelay: Duration = .milliseconds(250)

    private func present(_ target: DockHoverTarget) async {
        let app = target.app
        var windows = DockWindows.enumerate(app: app)
        var attempt = 0
        while windows.isEmpty, attempt < Self.emptyRetryAttempts {
            try? await Task.sleep(for: Self.emptyRetryDelay)
            guard !Task.isCancelled else { return }
            windows = DockWindows.enumerate(app: app)
            attempt += 1
        }
        guard !windows.isEmpty else { hideNow(); return }

        let maxDimension = DockDoorSettings.previewSize().maxDimension
        panel.show(
            app: app,
            iconRectAX: target.iconRectAX,
            windows: windows,
            showTitles: DockDoorSettings.showTitles(),
            maxDimension: maxDimension,
            onActivate: { [weak self] window in
                window.raise(app: app)
                self?.hideNow()
            }
        )

        if DockDoorSettings.keepPanelOpen() { installClickMonitors() }

        guard DockThumbnailer.canCapture else { return }
        // Only windows that can actually have an on-screen SCK image get a
        // capture target: a minimized or geometry-less window's zero/stale
        // frame would otherwise "closest-match" someone else's capture and put
        // the wrong thumbnail on the wrong tile. Those tiles keep the icon.
        let targets = windows
            .filter { !$0.isMinimized && $0.frame.width > 1 && $0.frame.height > 1 }
            .map { DockCaptureTarget(index: $0.id, frame: $0.frame) }
        guard !targets.isEmpty else { return }
        let images = await DockThumbnailer.capture(app: app, targets: targets, maxDimension: maxDimension)
        // Drop stale results: a later hover may have swapped the shown app.
        guard !Task.isCancelled, panel.shownPID == app.pid else { return }
        panel.attachImages(images)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.hideGraceMs))
            guard !Task.isCancelled, let self else { return }
            hideNow()
        }
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func hideNow() {
        showTask?.cancel(); showTask = nil
        pendingShowPID = nil
        cancelHide()
        removeClickMonitors()
        panel.hide()
    }

    // MARK: - Keep-open dismissal (click anywhere outside)

    /// Whether a mouse-down at `location` (AppKit screen coordinates) should
    /// dismiss a kept-open panel: any click outside the panel's frame. Pure —
    /// unit-tested without a live panel.
    static func clickDismisses(location: CGPoint, panelFrame: CGRect?) -> Bool {
        guard let panelFrame else { return false }
        return !panelFrame.contains(location)
    }

    /// While keep-open is active, the hover-exit hides are disabled, so the
    /// panel needs another way out: a click anywhere that isn't the panel.
    /// One global monitor (clicks in other apps — read-only, delivered after
    /// the target app gets the event) plus one local (clicks on Pear's own
    /// windows). Installed only while the panel is visible; `hideNow` removes
    /// them, so a disabled tool leaves no monitors behind.
    private func installClickMonitors() {
        guard clickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.dismissIfClickedOutside()
        }) {
            clickMonitors.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.dismissIfClickedOutside()
            return event
        }
        if let local { clickMonitors.append(local) }
    }

    private func removeClickMonitors() {
        for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
        clickMonitors.removeAll()
    }

    private func dismissIfClickedOutside() {
        if Self.clickDismisses(location: NSEvent.mouseLocation, panelFrame: panel.panelFrame) {
            hideNow()
        }
    }
}
