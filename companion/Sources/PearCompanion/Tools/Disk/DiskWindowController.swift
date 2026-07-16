import SwiftUI
import AppKit

/// A standard, reusable window hosting the Disk explorer. Unlike the floating
/// panels (clipboard, cleaner) this is an ordinary titled window: it stays open
/// when focus shifts elsewhere, so an in-progress analysis isn't lost. One
/// window is created and reused across opens; it remembers its size.
@MainActor
final class DiskWindowController {
    private var window: NSWindow?

    /// Shows the window, creating it once and reusing it thereafter.
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Disk"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DiskAnalyzeView())
        // Restore the last size/position; center only on first ever open.
        window.setFrameAutosaveName("PearDiskWindow")
        if !window.setFrameUsingName("PearDiskWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
