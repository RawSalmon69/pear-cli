import SwiftUI

/// Live, native system detail — a drill-down behind the compact "Mac" stats
/// row. Tile-only (no global hotkey); the popover owns a `MonitorModel` that
/// samples only while it is open. Cheap at init: nothing runs until the tile
/// is tapped.
@MainActor
final class MonitorTool: Tool {
    let id = "monitor"
    let title = "Monitor"
    let icon = "gauge.with.dots.needle.67percent"
    let hotkey: HotKeyChord? = nil

    var entry: ToolEntry {
        .popover { AnyView(MonitorView()) }
    }
}
