import SwiftUI
import AppKit

/// Floating scratchpad panel: non-activating, joins every Space, and does
/// NOT auto-hide on resignKey (unlike `ClipboardWindowController`) — a quick
/// note must survive switching to another app while you copy from it.
@MainActor
final class ScratchpadWindowController {
    let store: ScratchpadStore
    private var panel: NSPanel?

    /// `store` created here, not at `ScratchpadTool` init — both the window
    /// and its store are lazy, built together on first activation.
    init(store: ScratchpadStore = ScratchpadStore()) {
        self.store = store
    }

    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func hide() {
        store.saveNow()
        panel?.orderOut(nil)
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 320, height: 300)
        let panel = ScratchpadPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // No title bar to drag by; let the whole card move the window.
        panel.isMovableByWindowBackground = true
        panel.onCancel = { [weak self] in self?.hide() }
        let host = NSHostingView(
            rootView: ScratchpadView(store: store, onClose: { [weak self] in self?.hide() })
        )
        // Clip the rectangular backing to the card's corner radius so no
        // hairline edge shows past the rounded glass.
        host.wantsLayer = true
        host.layer?.cornerRadius = 16
        host.layer?.masksToBounds = true
        panel.contentView = host

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - size.width - 20,
                y: visible.minY + 20
            ))
        }
        return panel
    }
}

/// Borderless panel that both takes key focus (so typing works) and keeps
/// it — no `resignKey` auto-hide, so focus loss doesn't close the note.
private final class ScratchpadPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    // One dismissal grammar across every floating surface: Esc closes
    // (and the controller's hide() saves first).
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
