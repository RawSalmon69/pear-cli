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
    let category = ToolCategory.utilities
    let summary = "A floating note that saves as you type."
    /// Holds the user's own writing, so it stays reachable with the app locked.
    /// The terms promise that in writing; see `Tool.survivesExpiry`.
    let survivesExpiry = true
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

    /// Live-disable: close the panel (which saves and removes the scroll
    /// monitor) so a disabled tool leaves no window or event monitor behind.
    func stop() {
        window?.hide()
    }

    /// The New Scratchpad Note action: a fresh note (holding `text`, if any),
    /// with the panel opened if it is closed.
    func newNote(text: String?) {
        let controller = resolveWindow()
        controller.store.createNote()
        if let text, !text.isEmpty { controller.store.updateText(text) }
        if !controller.isOpen { controller.toggle() }
    }

    private func toggle() {
        resolveWindow().toggle()
    }

    private func resolveWindow() -> ScratchpadWindowController {
        let controller = window ?? ScratchpadWindowController()
        window = controller
        return controller
    }
}
