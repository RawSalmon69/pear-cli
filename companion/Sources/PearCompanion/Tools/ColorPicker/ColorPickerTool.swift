import SwiftUI

/// Eyedropper + format/contrast reference. Tile-only — no global hotkey,
/// since the popover is the whole interaction (pick, copy a format, done).
/// Mirrors `DiskTool`'s shape: the view owns its store via `@State`, so
/// nothing is constructed until the popover first opens.
@MainActor
final class ColorPickerTool: Tool {
    let id = "colorPicker"
    let title = "Color Picker"
    let icon = "eyedropper"
    let category = ToolCategory.utilities
    let summary = "Pick any on-screen color; copy it in HEX, RGB, or HSL."
    let hotkey: HotKeyChord? = nil

    /// Lazy hotkey-path store: only built if the user binds a custom chord and
    /// fires it. The popover keeps its own `@State` store (both persist to the
    /// same UserDefaults key), matching `DiskTool`'s lazy pattern.
    private var store: ColorStore?

    var entry: ToolEntry {
        .popover { AnyView(ColorPickerView()) }
    }

    /// A custom chord (the tool has no default) runs the eyedropper straight
    /// away and copies the picked hex — no popover round-trip needed.
    func hotkeyFired() {
        let store = store ?? ColorStore()
        self.store = store
        store.pickColor(copyingHex: true)
    }
}
