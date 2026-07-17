import SwiftUI
import AppKit

/// A standard, reusable window hosting the full Monitor. Shared by the Monitor
/// tile and by tapping the panel's compact "Mac" row, so both open the same
/// detail view (and it stays put when focus shifts, unlike a popover). The
/// model inside samples only while the window is visible.
@MainActor
final class MonitorWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    /// Owned here (not just inside the view) so `windowWillClose` can stop
    /// sampling; the window is reused across opens, so the model persists too.
    private let model = MonitorModel()

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Monitor"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MonitorView(model: model))
        window.delegate = self
        window.setFrameAutosaveName("PearMonitorWindow")
        if !window.setFrameUsingName("PearMonitorWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    /// Backstop for the view's `.onDisappear` stop: `onDisappear` isn't
    /// guaranteed to fire when the AppKit window closes, so stop sampling here
    /// too. `stop()` is idempotent, and `.onAppear` restarts it on the next
    /// open, so double-stopping is harmless.
    func windowWillClose(_ notification: Notification) {
        model.stop()
    }
}

/// Titled window that also closes on Esc, so the dismissal grammar matches the
/// floating panels (clipboard, shelf, scratchpad, windows grid). The close
/// button and ⌘W still work; this just adds Esc.
private final class KeyableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
