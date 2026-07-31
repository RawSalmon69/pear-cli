import SwiftUI
import AppKit

/// A standard, reusable window hosting the Disk explorer. Unlike the floating
/// panels (clipboard, shelf) this is an ordinary titled window: it stays open
/// when focus shifts elsewhere, so an in-progress analysis isn't lost. One
/// window is created and reused across opens; it remembers its size.
@MainActor
final class DiskWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    /// Owned here, not inside the view, so `windowWillClose` can cancel the walk
    /// and a reopen can restart it. `.onDisappear`/`.task` do not fire again on a
    /// reused AppKit window — the same asymmetry the monitor window hit.
    private let model = DiskScanModel()

    /// Shows the window, creating it once and reusing it thereafter.
    func show() {
        if let window {
            model.scanIfNeeded(path: FileManager.default.homeDirectoryForCurrentUser.path)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Disk"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DiskAnalyzeView(scanModel: model))
        window.delegate = self
        // Restore the last size/position; center only on first ever open.
        window.setFrameAutosaveName("PearDiskWindow")
        if !window.setFrameUsingName("PearDiskWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    /// Closes the window (which cancels the scan) — used when the tool is
    /// switched off in Settings.
    func close() {
        window?.close()
    }

    /// Closing the window stops the scan. Without this an in-flight walk kept up
    /// to `min(cores, 8)` `.utility` tasks crawling the whole home folder with no
    /// window to show the result in.
    func windowWillClose(_ notification: Notification) {
        model.cancel()
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
