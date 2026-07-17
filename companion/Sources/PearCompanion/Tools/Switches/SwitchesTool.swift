import SwiftUI

/// Quick system toggles in a grid: Keep Awake, Mute, Screen Saver, Lock Screen,
/// Hide Desktop, Show Hidden, Big Cursor. The tile only opens the grid;
/// individual switches act only on a user tap, so the tool is safe to enable
/// by default. `stop()` releases any held power assertion.
@MainActor
final class SwitchesTool: Tool {
    let id = "switches"
    let title = "Switches"
    let icon = "switch.2"
    let category = ToolCategory.system
    let summary = "Quick system toggles — keep awake, mute, lock the screen, and more."
    let hotkey: HotKeyChord? = nil

    private let model = SwitchesModel()

    var entry: ToolEntry {
        .popover { [model] in AnyView(SwitchesView(model: model)) }
    }

    func stop() {
        model.teardown()
    }
}
