import SwiftUI
import AppKit

/// Floating clipboard-history picker opened by ⌃⇧C from anywhere. Toggles:
/// pressing the hotkey again (or clicking away) hides it.
@MainActor
final class ClipboardWindowController {
    private var panel: NSPanel?

    func toggle(env: AppEnvironment) {
        if panel != nil {
            hide()
        } else {
            show(env: env)
        }
    }

    private func show(env: AppEnvironment) {
        let view = ClipboardHistoryView()
            .environmentObject(env)
            .frame(width: 300)

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 380),
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
        panel.contentView = NSHostingView(rootView: view)

        // Near the mouse, clamped on-screen.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let size = panel.frame.size
            var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 8)
            let vis = screen.visibleFrame
            origin.x = min(max(vis.minX + 8, origin.x), vis.maxX - size.width - 8)
            origin.y = min(max(vis.minY + 8, origin.y), vis.maxY - size.height - 8)
            panel.setFrameOrigin(origin)
        }

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Borderless panel that can take key focus (so buttons/clicks work) and
/// closes itself when it loses focus.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}
