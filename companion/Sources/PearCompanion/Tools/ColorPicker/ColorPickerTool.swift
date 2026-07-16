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

    var entry: ToolEntry {
        .popover { AnyView(ColorPickerView()) }
    }
}
