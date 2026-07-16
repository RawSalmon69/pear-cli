import AppKit
import SwiftUI

/// Owns the shelf's floating panel. Unlike the clipboard picker this panel
/// stays open until explicitly toggled or closed — it does NOT order out on
/// losing key focus, so you can click into another app and drag files back
/// onto it. Toggling (tile or ⌃⇧V) shows/hides it.
@MainActor
final class ShelfWindowController {
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private let store: ShelfStore

    private static let panelSize = NSSize(width: 300, height: 380)

    init(store: ShelfStore) {
        self.store = store
    }

    func toggle() {
        if panel != nil {
            hide()
        } else {
            show()
        }
    }

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func show() {
        let view = ShelfView(store: store, onClose: { [weak self] in self?.hide() })

        let panel = ShelfPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Window dragging is driven explicitly by `ShelfWindowMoveOverlay` so
        // it can never preempt an item row's drag-out (see that view's note).
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: 260, height: 300)
        panel.onCancel = { [weak self] in self?.hide() }
        let host = FirstMouseHostingView(rootView: view)
        host.clipToCard()
        panel.contentView = host

        // Centered on the screen under the pointer.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - Self.panelSize.width / 2,
                y: visible.midY - Self.panelSize.height / 2
            ))
        }

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        installKeyMonitor(for: panel)
    }

    /// ⌘V pastes the clipboard into the shelf; ⌘C copies the hovered row out.
    /// A local key monitor scoped to the panel's visibility — installed on
    /// show, torn down in `hide()` — mirroring the session-scoped monitors in
    /// RadialTrigger / DockSwitcher. The non-activating panel means a SwiftUI
    /// `.onPasteCommand` would not fire reliably, so the shortcuts live here.
    private func installKeyMonitor(for panel: NSPanel) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, event.window === panel,
                  event.modifierFlags.contains(.command) else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v":
                self.store.ingest(from: .general)
                return nil
            case "c":
                return self.store.copyHovered(to: .general) ? nil : event
            default:
                return event
            }
        }
    }
}

/// Borderless panel that can take key focus (so buttons and Quick Look work)
/// but — deliberately unlike `KeyablePanel` — does not close on `resignKey`.
private final class ShelfPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // One dismissal grammar across every floating surface: Esc closes.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Delivers the first click even when the panel isn't key, so a row drag or
/// button press lands on the first press instead of only promoting the panel
/// to key. Adapted from Dropshit (MIT), `FloatingPanel.swift`.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
