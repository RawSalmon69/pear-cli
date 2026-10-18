import AppKit

/// The rule every standard titled window (Settings, Disk, a screenshot's
/// detail, Markup, Remove Background) shares on close. Settings makes Pear a
/// regular app while it is open and stays regular if another titled window is
/// still up; whichever of them closes last puts Pear back to accessory, or the
/// Dock icon sticks. Only Settings switches to regular — the others never do.
@MainActor
enum StandardWindow {
    /// Call from `windowWillClose`, passing the closing window.
    static func didClose(_ closing: NSWindow?) {
        guard NSApp.activationPolicy() == .regular,
              !othersOpen(besides: closing, in: NSApp.windows) else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Whether any titled window other than `closing` is still on screen.
    /// Borderless panels (the companion panel, preview cards, pins) never count.
    static func othersOpen(besides closing: NSWindow?, in windows: [NSWindow]) -> Bool {
        windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
    }
}
