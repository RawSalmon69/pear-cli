import SwiftUI
import AppKit

/// Standalone background remover: opens a window where you drop or choose any
/// image and get a transparent cutout to copy or save. Uses the same engine as
/// the screenshot/shelf actions — Apple Vision by default, the opt-in HD model
/// when it's enabled and ready. Tile-only; nothing runs until opened.
@MainActor
final class BackgroundRemoverTool: Tool {
    let id = "backgroundremover"
    let title = "Remove Background"
    let icon = "person.and.background.dotted"
    let category = ToolCategory.capture
    let summary = "Drop or choose an image and cut out its background on-device. Enable High-quality mode in Settings for remove.bg-class edges."
    let hotkey: HotKeyChord? = nil

    private let window = BackgroundRemoverWindowController()

    var entry: ToolEntry { .action { [window] in window.show() } }
}

/// A reusable titled window hosting the remover. Reused across opens so the
/// last result stays until replaced.
@MainActor
final class BackgroundRemoverWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = BackgroundRemoverModel()

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = EscClosableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Remove Background"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BackgroundRemoverView(model: model))
        window.delegate = self
        window.setFrameAutosaveName("PearBackgroundRemoverWindow")
        if !window.setFrameUsingName("PearBackgroundRemoverWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

/// Titled window that also closes on Esc — matches the app's dismissal grammar
/// (Monitor/Disk windows, the floating panels).
private final class EscClosableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}
