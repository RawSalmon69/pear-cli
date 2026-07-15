import SwiftUI
import Carbon.HIToolbox

/// Floating quick-note panel, Antinote-style: type immediately, cycle
/// through several notes, autosaves to disk. The tile and the ⌃⇧N hotkey
/// both toggle the same panel open/closed.
@MainActor
final class ScratchpadTool: Tool {
    let id = "scratchpad"
    let title = "Scratchpad"
    let icon = "note.text"
    let hotkey: HotKeyChord? = HotKeyChord(
        keyCode: kVK_ANSI_N, modifiers: controlKey | shiftKey, label: "⌃⇧N")

    // Lazy: created on first activation, not at launch.
    private var window: ScratchpadWindowController?

    var entry: ToolEntry {
        .action { [weak self] in self?.toggle() }
    }

    func hotkeyFired() {
        toggle()
    }

    private func toggle() {
        let controller = window ?? ScratchpadWindowController()
        window = controller
        controller.toggle()
    }
}
