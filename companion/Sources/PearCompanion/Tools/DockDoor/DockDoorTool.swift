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
    let summary = "Hover a Dock icon to preview and raise its windows."
    let hotkey: HotKeyChord? = nil

    private let controller = DockHoverController()

    func start() { controller.start() }
    func stop() { controller.stop() }

    var entry: ToolEntry {
        // onTrusted: the permission card just confirmed Accessibility, so the
        // (idempotent) start path can now install the Dock observer live.
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
        observer.stop()
        panel.hide()
        panel.model.onHoverChange = nil
    }

    // MARK: - Hover intent (pure decision + scheduling)

    /// What a hover event should do given the app under the cursor and the app
    /// currently shown. Pure — unit-tested without a live Dock.
    enum HoverAction: Equatable {
        case show // an app icon, different from what's shown
        case keep // the same app that's already shown
        case hide // nothing app-like under the cursor
    }

    static func action(hoveredPID: pid_t?, shownPID: pid_t?) -> HoverAction {
        guard let hoveredPID else { return .hide }
        return hoveredPID == shownPID ? .keep : .show
    }

    private func hoverChanged(_ target: DockHoverTarget?) {
        switch Self.action(hoveredPID: target?.app.pid, shownPID: panel.shownPID) {
        case .hide:
            scheduleHide()
        case .keep:
            cancelHide()
        case .show:
            guard let target else { return }
            cancelHide()
            scheduleShow(target)
        }
    }

    private func panelHoverChanged(_ inside: Bool) {
        if inside { cancelHide() } else { scheduleHide() }
    }

    // MARK: - Show / hide

    private func scheduleShow(_ target: DockHoverTarget) {
        showTask?.cancel()
        let delayMs = Int(DockDoorSettings.hoverDelay())
        showTask = Task { [weak self] in
            if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
            guard !Task.isCancelled, let self else { return }
            await present(target)
        }
    }

    private func present(_ target: DockHoverTarget) async {
        let app = target.app
        let windows = DockWindows.enumerate(app: app)
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

        guard DockThumbnailer.canCapture else { return }
        let targets = windows.map { DockCaptureTarget(index: $0.id, frame: $0.frame) }
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
        cancelHide()
        panel.hide()
    }
}
