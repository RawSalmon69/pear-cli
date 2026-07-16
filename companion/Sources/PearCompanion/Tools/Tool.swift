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

/// Groups tiles under a labeled row in the panel and the help sheet, so a
/// dozen tools read as a few small sections instead of one overwhelming wall.
enum ToolCategory: String, CaseIterable {
    case capture, utilities, system

    var title: String {
        switch self {
        case .capture: "Capture"
        case .utilities: "Utilities"
        case .system: "System"
        }
    }
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
    /// Panel/help grouping. Defaults to `.utilities`.
    var category: ToolCategory { get }
    /// One-line description shown in the help sheet. Defaults to empty.
    var summary: String { get }
    /// Whether the tool is on for a fresh install. Defaults true; a tool that
    /// alters the system on launch (the menu-bar hider) opts out.
    var defaultEnabled: Bool { get }
    /// Hotkey behavior; defaults to the tile action for `.action` tools.
    func hotkeyFired()
    /// Launch-time hook for always-on engines. Default no-op.
    func start()
}

extension Tool {
    var category: ToolCategory { .utilities }
    var summary: String { "" }
    var defaultEnabled: Bool { true }

    func start() {}

    func hotkeyFired() {
        if case .action(let run) = entry { run() }
    }
}

/// Launch-time list of tools. Registers hotkeys and starts always-on
/// engines; adding a tool to the app is one `offer` call.
@MainActor
final class ToolRegistry {
    /// Display metadata for every offered tool, enabled or not — drives the
    /// settings toggles and the help sheet without holding the live tool.
    struct KnownTool {
        let id: String
        let title: String
        let icon: String
        let hotkeyLabel: String?
        let category: ToolCategory
        let summary: String
        let defaultEnabled: Bool
    }

    /// Enabled tools, in panel order.
    private(set) var all: [any Tool] = []
    /// Every offered tool, enabled or not — drives the settings toggles.
    private(set) var known: [KnownTool] = []
    private var hotkeyTokens: [String: HotKeyManager.Token] = [:]

    /// Catalogs the tool and registers it unless the user disabled it —
    /// a disabled tool's hotkeys and engines never load.
    func offer(_ tool: any Tool) {
        known.append(KnownTool(
            id: tool.id, title: tool.title, icon: tool.icon,
            hotkeyLabel: tool.hotkey?.label, category: tool.category, summary: tool.summary,
            defaultEnabled: tool.defaultEnabled))
        guard Prefs.isToolEnabled(tool.id, default: tool.defaultEnabled) else { return }
        register(tool)
    }

    private func register(_ tool: any Tool) {
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
