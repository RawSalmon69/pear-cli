// Adapted from DockDoor (GPL-3.0), https://github.com/ejbills/DockDoor,
// commit 78b0862f — original: DockDoor/Views/Hover Window/Shared Components/
// SharedPreviewWindowCoordinator.swift and
// WindowPreview Supporting/WindowDismissalContainer.swift.
//
// DockDoor's coordinator IS the panel (a 1000-line NSPanel subclass doing
// switcher, media, folder, drag-to-desktop, and search). This is a much smaller
// hover-only panel: a borderless nonactivating NSPanel above the Dock, SwiftUI
// content clipped to the card, anchored via the pure DockGeometry math. Mouse
// exit is reported through SwiftUI's own .onHover (no NSTrackingArea subclass),
// matching the map's suggestion. Esc routes through cancelOperation, Pear's
// one dismissal grammar for floating surfaces.

import AppKit
import SwiftUI

/// Owns the hover NSPanel and its SwiftUI model. Reused across hovers: content
/// is re-hosted and the frame re-anchored on each `show`.
@MainActor
final class DockPreviewPanel {
    let model = DockPreviewModel()

    /// pid of the app currently shown, or nil when hidden. Lets the controller
    /// skip re-showing the same app and drop stale async capture results.
    private(set) var shownPID: pid_t?

    /// Esc while the panel is key (the nonactivating design rarely makes it key,
    /// so mouse-exit is the primary dismissal — this is the shared pattern).
    var onEsc: (() -> Void)?

    private var panel: DockPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Panel frame in screen coordinates while visible, nil when hidden — the
    /// keep-open mode's click-outside test needs it.
    var panelFrame: CGRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame
    }

    func show(
        app: DockApp,
        iconRectAX: CGRect,
        windows: [DockWindow],
        showTitles: Bool,
        maxDimension: CGFloat,
        onActivate: @escaping (DockWindow) -> Void
    ) {
        model.appName = app.name
        model.appIcon = app.hydrate()?.icon
        model.showTitles = showTitles
        model.tileMaxDimension = maxDimension
        model.tiles = windows.map { window in
            DockWindowTile(
                id: window.id,
                title: window.title,
                isMinimized: window.isMinimized,
                image: nil,
                activate: { onActivate(window) }
            )
        }
        shownPID = app.pid

        let host = FirstMouseHostingView(rootView: DockPreviewView(model: model).glassCard(cornerRadius: 14))
        host.clipToCard(radius: 14)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let panel = ensurePanel()
        panel.contentView = host

        let frame = frame(forIconRectAX: iconRectAX, panelSize: size)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless() // nonactivating: show without stealing focus
    }

    /// Attach captured thumbnails to their tiles by index; missing indices keep
    /// their icon fallback.
    func attachImages(_ images: [Int: CGImage]) {
        for tile in model.tiles {
            if let image = images[tile.id] { tile.image = image }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        shownPID = nil
        model.tiles = []
    }

    // MARK: - Geometry

    /// Anchors the panel to the hovered icon: flip the AX (top-left) icon rect
    /// into AppKit space, pick the screen it sits on, derive the Dock edge from
    /// that screen's insets, resolve the user's placement setting against that
    /// edge, then place and clamp via `DockGeometry`. Placement and gap are read
    /// live, so a settings change applies on the next hover with no relaunch.
    private func frame(forIconRectAX iconRectAX: CGRect, panelSize: CGSize) -> CGRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let iconAppKit = DockGeometry.flipToAppKit(iconRectAX, primaryMaxY: primaryMaxY)
        let screen = screenContaining(iconAppKit) ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        // iconRect lets the edge inference survive an auto-hidden Dock, which
        // reserves no inset for the inset-based detection to see.
        let side = DockGeometry.side(
            frame: screen?.frame ?? .zero, visibleFrame: visible, iconRect: iconAppKit)
        let placement = DockGeometry.resolvedPlacement(DockDoorSettings.previewPlacement(), side: side)
        let origin = DockGeometry.panelOrigin(
            iconRect: iconAppKit, panelSize: panelSize, placement: placement,
            visibleFrame: visible, gap: DockDoorSettings.previewGap()
        )
        return CGRect(origin: origin, size: panelSize)
    }

    private func screenContaining(_ rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    // MARK: - Panel

    private func ensurePanel() -> DockPanel {
        if let panel { return panel }
        let panel = DockPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // The Dock sits at CGWindowLevelForKey(.dockWindow) (== 20), ABOVE
        // NSWindow.Level.floating (== 3), so a .floating panel is drawn behind
        // the Dock — the preview appeared clipped under it. DockDoor's
        // SharedPreviewWindowCoordinator.setupWindow raises the level for exactly
        // this reason (`level = Defaults[.raisedWindowLevel] ? .statusBar : .floating`,
        // raisedWindowLevel default true); .statusBar (== 25) clears the Dock.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.onCancel = { [weak self] in self?.onEsc?() }
        self.panel = panel
        return panel
    }

    /// First click lands on a window tile instead of only focusing the panel.
    private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// Borderless nonactivating panel that hides on Esc. Mirrors the app's other
/// floating surfaces (WindowsPanel): one dismissal grammar, Esc closes.
private final class DockPanel: NSPanel {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
