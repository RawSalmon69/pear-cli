import SwiftUI

/// A global hotkey chord plus the label shown under the tool's tile.
struct HotKeyChord {
    let keyCode: Int
    let modifiers: Int
    let label: String
}

/// How a tool's panel tile behaves when tapped.
enum ToolEntry {
    /// Runs an action (screenshot, OCR).
    case action(() -> Void)
    /// Opens a popover anchored to the tile.
    case popover(() -> AnyView)
}

/// One tool: a tile in the panel's Tools section, optionally a global
/// hotkey. Conformer inits run at launch for every registered tool, so they
/// must stay cheap — create the heavy service lazily on first activation.
/// Engines that must observe continuously from launch (clipboard history)
/// opt into `start()`.
@MainActor
protocol Tool: AnyObject {
    var id: String { get }
    var title: String { get }
    var icon: String { get }
    var hotkey: HotKeyChord? { get }
    var entry: ToolEntry { get }
    /// Hotkey behavior; defaults to the tile action for `.action` tools.
    func hotkeyFired()
    /// Launch-time hook for always-on engines. Default no-op.
    func start()
}

extension Tool {
    func start() {}

    func hotkeyFired() {
        if case .action(let run) = entry { run() }
    }
}

/// Launch-time list of tools. Registers hotkeys and starts always-on
/// engines; adding a tool to the app is one `register` call.
@MainActor
final class ToolRegistry {
    private(set) var all: [any Tool] = []
    private var hotkeyTokens: [String: HotKeyManager.Token] = [:]

    func register(_ tool: any Tool) {
        all.append(tool)
        if let chord = tool.hotkey {
            hotkeyTokens[tool.id] = HotKeyManager.shared.register(
                keyCode: chord.keyCode,
                modifiers: chord.modifiers
            ) { [weak tool] in tool?.hotkeyFired() }
        }
        tool.start()
    }
}
