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
    let summary = "A tray that holds files while you move them between apps."
    /// Can be holding the user's files when the trial ends, so it stays reachable
    /// with the app locked. See `Tool.survivesExpiry`.
    let survivesExpiry = true
    let hotkey: HotKeyChord? = HotKeyChord(
        keyCode: kVK_ANSI_V, modifiers: controlKey | shiftKey, label: "⌃⇧V")

    private var window: ShelfWindowController?

    var entry: ToolEntry {
        .action { [weak self] in self?.toggle() }
    }

    func hotkeyFired() {
        toggle()
    }

    /// Live-disable: close the panel (which removes its keyDown monitor) so a
    /// disabled tool leaves no floating window or event monitor behind — the
    /// scratchpad's contract, which this tool was missing.
    func stop() {
        window?.hide()
    }

    /// The Add File to Shelf action: copies the file in, then opens the shelf
    /// if it is closed so the item is there to drag out.
    func add(_ file: URL) async {
        let controller = resolveWindow()
        await controller.store.add(file)
        if !controller.isOpen { controller.toggle() }
    }

    private func toggle() {
        resolveWindow().toggle()
    }

    private func resolveWindow() -> ShelfWindowController {
        let controller = window ?? ShelfWindowController(store: ShelfStore())
        window = controller
        return controller
    }
}
