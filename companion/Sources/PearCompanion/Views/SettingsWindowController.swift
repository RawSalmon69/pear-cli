import AppKit
import SwiftUI

/// The Settings window: one standard titled window, created once and reused,
/// that remembers its frame. `PanelController` owns it and opens it for every
/// `pearOpenSettings` (gear, ⌘, from the panel, status-item menu, app menu).
///
/// While it is open Pear is a regular app — Dock icon, ⌘-Tab, its own menu bar —
/// so the window cannot get lost behind other apps the way an agent app's
/// window does; closing it returns Pear to accessory (menu-bar only). The
/// companion panel is a non-activating `NSPanel` either way, so the policy
/// change does not touch it.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let env: AppEnvironment
    private var window: NSWindow?
    private var host: NSHostingView<AnyView>?

    init(env: AppEnvironment) {
        self.env = env
    }

    func show() {
        if let window {
            // A reused window never re-fires `.onAppear`, and its `@State` (the
            // folder path, a half-shown accent wheel) would outlive the close.
            // A fresh root per open re-reads everything, as the old popover did
            // by being rebuilt. Not while it is up: that would wipe a typed field.
            if !window.isVisible { host?.rootView = root() }
        } else {
            let host = NSHostingView(rootView: root())
            // Min size only: the window keeps whatever size the user gave it.
            host.sizingOptions = [.minSize]
            let window = SettingsWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                // Not miniaturizable: a minimised window never fires
                // `windowWillClose`, which would leave Pear regular.
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Pear Settings"
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.delegate = self
            window.setFrameAutosaveName("PearSettingsWindow")
            if !window.setFrameUsingName("PearSettingsWindow") { window.center() }
            self.host = host
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        // Activating in the same turn as the policy change can leave the window
        // unfocused on the first open; one turn later the app is regular.
        Task { @MainActor [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func root() -> AnyView {
        AnyView(SettingsView().environment(env).id(UUID()))
    }

    /// Back to menu-bar only, unless another standard window (Disk, a
    /// screenshot's detail, Markup) is still up: dropping to accessory under it
    /// would take away its Dock icon and ⌘-Tab.
    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let othersOpen = NSApp.windows.contains {
            $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled)
        }
        if !othersOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Esc and ⌘W close it, the same grammar as the Disk window. ⌘W is handled
/// here because the menu bar only exists while Settings is open, and a
/// recording hotkey field swallows Esc before it gets this far.
private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Caps Lock is in the device-independent mask; it must not block ⌘W.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock) == .command,
           event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
