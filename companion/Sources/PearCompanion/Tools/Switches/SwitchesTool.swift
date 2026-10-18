import SwiftUI

/// Quick system toggles in a grid: Keep Awake, Lid Closed, Screen Saver, Lock Screen,
/// Hide Desktop, Show Hidden, Big Cursor. The tile only opens the grid;
/// individual switches act only on a user tap, so the tool is safe to enable
/// by default. `stop()` releases any held power assertion.
@MainActor
final class SwitchesTool: Tool {
    let id = "switches"
    let title = "Switches"
    let icon = "switch.2"
    let category = ToolCategory.system
    let summary = "System toggles: keep awake, lock the screen, hide the desktop."
    let hotkey: HotKeyChord? = nil

    private let model = SwitchesModel()

    var acceptsHotkey: Bool { false }

    /// How many toggles are on, as last read. Keep Awake is always current
    /// (Pear holds the assertion); the rest are as fresh as the popover's last
    /// `refresh()` — no process is spawned just to label a row.
    var status: String? {
        let on = [model.keepAwakeOn, model.lidClosedOn, model.hideDesktopOn, model.showHiddenOn]
            .filter { $0 }.count
        return on > 0 ? "\(on) on" : nil
    }

    var entry: ToolEntry {
        .popover { [model] in AnyView(SwitchesView(model: model)) }
    }

    func stop() {
        model.teardown()
    }
}
