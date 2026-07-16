import SwiftUI

/// Menu-bar declutter: an always-visible chevron plus a stretch separator whose
/// length toggles to hide/show the icons the user ⌘-drags between them, and an
/// optional always-hidden zone further left. These status items are the tool's
/// only always-on cost, so `start()` — which the registry only calls for
/// enabled tools — creates them. The tile opens a popover for the toggle,
/// auto-rehide interval, the always-hidden/⌥-reveal settings, and the ⌘-drag
/// hint. Multi-item model ported from Hidden Bar (MIT).
@MainActor
final class MenuBarTool: Tool {
    let id = "menubar"
    let title = "Menu Bar"
    let icon = "menubar.rectangle"
    let category = ToolCategory.system
    let summary = "Hide menu-bar clutter behind a click."
    // Off by default: it mutates the bar on launch (collapses, hiding icons to
    // the separator's left). Opt in when you want it.
    let defaultEnabled = false
    let hotkey: HotKeyChord? = nil

    let manager = MenuBarManager()

    func start() {
        manager.installSurface()
    }

    func stop() {
        manager.uninstallSurface()
    }

    var entry: ToolEntry {
        .popover { [manager] in AnyView(MenuBarSettingsView(manager: manager)) }
    }

    /// A custom chord (the tool has no default) toggles the collapse/expand —
    /// the same action as clicking the chevron.
    func hotkeyFired() {
        manager.toggle()
    }
}
