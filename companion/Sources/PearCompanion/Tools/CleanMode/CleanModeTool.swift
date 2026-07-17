import SwiftUI

/// Clean Mode: blacks out every display and (by default) locks the keyboard so
/// you can wipe the screen and keys without triggering anything. Entering is
/// explicit — a tile click, never automatic. Exit is guaranteed three ways, each
/// independently sufficient: the on-screen Done button, the auto-timeout, and —
/// because the mouse is never tapped — the pointer stays fully live throughout.
///
/// Off by default: it mutates system input while active, so it ships opt-in like
/// the other system-touching tools. `stop()` (live-disable) force-exits, so
/// turning the tool off can never strand an active session.
@MainActor
final class CleanModeTool: Tool {
    static let toolID = "cleanmode"

    let id = CleanModeTool.toolID
    let title = "Clean Mode"
    let icon = "sparkles.tv"
    let category = ToolCategory.system
    let summary = "Black out the screen and lock the keyboard to clean your Mac. Click Done or wait to exit."
    // Opt-in: it locks keyboard input while active (a system-mutating tool).
    let defaultEnabled = false
    let hotkey: HotKeyChord? = nil

    private let controller = CleanModeController()

    var entry: ToolEntry {
        // Explicit entry only: clicking the tile enters Clean Mode. Never auto.
        .action { [controller] in controller.enter() }
    }

    /// Live-disable (and app teardown via the registry) must never leave a
    /// session running.
    func stop() {
        controller.exit()
    }
}
