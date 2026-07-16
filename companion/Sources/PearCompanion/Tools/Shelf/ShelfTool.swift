import Carbon.HIToolbox
import SwiftUI

/// Dropover-style shelf: a floating drop target that holds files until you
/// drag them out. Tile and ⌃⇧V both toggle the panel. Stays cheap at init —
/// the store and window are built on first activation, not at launch.
@MainActor
final class ShelfTool: Tool {
    let id = "shelf"
    let title = "Shelf"
    let icon = "tray.full"
    let category = ToolCategory.utilities
    let summary = "A floating tray that holds files while you move them."
    let hotkey: HotKeyChord? = HotKeyChord(
        keyCode: kVK_ANSI_V, modifiers: controlKey | shiftKey, label: "⌃⇧V")

    private var window: ShelfWindowController?

    var entry: ToolEntry {
        .action { [weak self] in self?.toggle() }
    }

    func hotkeyFired() {
        toggle()
    }

    private func toggle() {
        let controller = window ?? ShelfWindowController(store: ShelfStore())
        window = controller
        controller.toggle()
    }
}
