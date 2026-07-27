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
    let category = ToolCategory.system
    let summary = "Live CPU, memory, network, battery, and sensors, with history graphs. Pick sections and refresh speed inside."
    let hotkey: HotKeyChord? = nil

    private let window: MonitorWindowController

    init(window: MonitorWindowController) {
        self.window = window
    }

    var entry: ToolEntry {
        .action { [window] in window.show() }
    }

    /// Live-disable: the sampling loop is owned by the window, not the tool, so
    /// unregistering the tool alone left it ticking on a feature the user just
    /// switched off.
    func stop() {
        window.close()
    }
}
