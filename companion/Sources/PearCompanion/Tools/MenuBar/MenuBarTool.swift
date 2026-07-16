import SwiftUI

/// Menu-bar declutter: one extra "separator" status item whose length toggles
/// to hide/show the icons the user ⌘-drags to its left. The separator is the
/// tool's single always-on piece (one `NSStatusItem`, effectively free), so
/// `start()` — which the registry only calls for enabled tools — creates it.
/// The tile opens a popover for the toggle, auto-rehide interval, and the
/// ⌘-drag hint.
@MainActor
final class MenuBarTool: Tool {
    let id = "menubar"
    let title = "Menu Bar"
    let icon = "menubar.rectangle"
    let category = ToolCategory.system
    let summary = "Hide menu-bar clutter behind a click."
    // Off by default: it collapses on launch and the separator hides icons to
    // its left, which can include Pear's own. Opt in when you want it.
    let defaultEnabled = false
    let hotkey: HotKeyChord? = nil

    let manager = MenuBarManager()

    func start() {
        manager.installSeparator()
    }

    var entry: ToolEntry {
        .popover { [manager] in AnyView(MenuBarSettingsView(manager: manager)) }
    }
}
