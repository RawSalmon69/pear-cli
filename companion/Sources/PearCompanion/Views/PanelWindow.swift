import AppKit
import Observation
import SwiftUI

extension Notification.Name {
    /// Posted by the `panel` pseudo-tool's global hotkey; the controller toggles
    /// the panel. Decouples the tool (registered inside the environment) from
    /// the controller (created later by the AppDelegate), so neither needs a
    /// reference to the other.
    static let pearTogglePanel = Notification.Name("pearTogglePanel")
}

/// Owns the menu-bar status item and the companion panel, replacing the old
/// `MenuBarExtra(.window)`. The point of the rewrite: a `MenuBarExtra` window
/// always dismisses on outside click, and no API disables that. A manual
/// non-activating `NSPanel` (the pattern the shelf and scratchpad already use)
/// stays open until you explicitly close it — status-item click, Esc, or the
/// ⌃⇧P hotkey.
///
/// The status item is always visible (`NSStatusItem.variableLength`, no length
/// tricks — the 2.1.0 lesson). Its button image is driven straight off the
/// `@Observable` runner via `withObservationTracking`, so a frame swap is one
/// `button.image =` assignment instead of a whole SwiftUI label re-render, and
/// there is no timer at rest.
@MainActor
final class PanelController: NSObject {
    private let env: AppEnvironment
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: NSPanel?
    private var host: PanelHostingView<AnyView>?

    init(env: AppEnvironment) {
        self.env = env
        super.init()

        // Always visible — no length-hiding. The menu-bar hider tool manages its
        // own separate items; this one must never disappear.
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp])
        }

        NotificationCenter.default.addObserver(
            forName: .pearTogglePanel, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.toggle() }
        }

        trackButton()
    }

    // MARK: - Status-item button

    /// Renders the button, then re-arms itself the moment any observed value
    /// changes. `withObservationTracking` fires `onChange` once per change on the
    /// mutating (main) actor; re-arming on the next turn re-reads the fresh
    /// values and re-registers the tracked set. Timer-free, no polling.
    private func trackButton() {
        withObservationTracking {
            renderButton()
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackButton() }
        }
    }

    /// Mirrors the old `MenuBarExtra` label exactly: runner frame (+ optional
    /// CPU%) when the runner is on, else the pear glyph with an unread badge.
    private func renderButton() {
        guard let button = statusItem.button else { return }
        let runner = env.runner
        if runner.isEnabled {
            button.image = runner.currentFrame
            if runner.showsCPU, let pct = runner.cpuPercent {
                button.title = " \(pct)%"
                button.imagePosition = .imageLeft
            } else {
                button.title = ""
                button.imagePosition = .imageOnly
            }
        } else {
            button.image = MenuBarIcon.image(unread: env.hasUnseenIncoming)
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    // MARK: - Panel

    @objc private func statusItemClicked() {
        toggle()
    }

    func toggle() {
        if panel == nil { show() } else { hide() }
    }

    /// Tears down the panel (and its hosting view) so the SwiftUI `.task`/timer
    /// stop and idle cost returns to ~0% — the recreate-per-open contract the
    /// panel's refresh logic assumed under `MenuBarExtra`.
    func hide() {
        panel?.orderOut(nil)
        panel = nil
        host = nil
    }

    private func show() {
        // Standalone the view needs its own glass, or it renders transparent
        // over the desktop — the window chrome that `MenuBarExtra` used to
        // supply. (Same fix the standalone clipboard picker makes.)
        let root = PanelView()
            .environment(env)
            .glassCard(cornerRadius: 16)
        let host = PanelHostingView(rootView: AnyView(root))
        host.clipToCard(radius: 16)
        host.onLayout = { [weak self] in self?.fitPanelToContent() }

        let panel = PearPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 392, height: 240)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar // floats above windows; hangs below the menu bar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in self?.hide() }
        panel.contentView = host

        self.host = host
        self.panel = panel

        host.layoutSubtreeIfNeeded()
        fitPanelToContent()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Sizes the panel to its SwiftUI content and anchors it just under the
    /// status item, clamped on-screen. Re-runs from the hosting view's `layout()`
    /// so the async stats fill-in (or a battery row appearing) never clips.
    private func fitPanelToContent() {
        guard let panel, let host,
              let buttonWindow = statusItem.button?.window else { return }
        let size = host.fittingSize
        guard size.width > 1, size.height > 1 else { return }
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? buttonWindow.frame
        var origin = NSPoint(
            x: buttonWindow.frame.midX - size.width / 2,
            y: buttonWindow.frame.minY - size.height
        )
        origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
        origin.y = max(visible.minY + 8, origin.y)
        let frame = NSRect(origin: origin, size: size)
        // Guarded so the setFrame → layout() → fit loop terminates.
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

/// Borderless, non-activating panel that stays open on focus loss — the whole
/// point — and closes only on Esc (routed to `onCancel`), the status-item click,
/// or the ⌃⇧P hotkey. Can become key so buttons and any text field respond;
/// first clicks land via `PanelHostingView.acceptsFirstMouse`.
private final class PearPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // One dismissal grammar across every floating surface: Esc closes.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Delivers the first click even when the panel isn't key, so a tile fires on
/// the first press instead of only promoting the panel to key (adapted from
/// Dropshit, MIT — the same trick the shelf/clipboard panels use). Also reports
/// SwiftUI content layout back so the controller keeps the panel sized to fit.
private final class PanelHostingView<Content: View>: NSHostingView<Content> {
    var onLayout: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }
}
