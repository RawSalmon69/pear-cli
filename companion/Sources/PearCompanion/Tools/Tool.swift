import Observation
import SwiftUI

/// A global hotkey chord plus the label shown under the tool's tile.
struct HotKeyChord: Equatable {
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
    /// Whether the tool shows a tile in the panel's Tools grid. Defaults true;
    /// the `panel` pseudo-tool opts out — you don't open the panel from inside
    /// it — while still registering a rebindable hotkey through the registry.
    var showsTile: Bool { get }
    /// Hotkey behavior; defaults to the tile action for `.action` tools.
    func hotkeyFired()
    /// Launch-time hook for always-on engines. Default no-op.
    func start()
    /// Teardown mirror of `start()`: a disabled tool must release every
    /// always-on resource it acquired — timers, status items, monitors, and any
    /// hotkey tokens it registered itself. Default no-op.
    func stop()
}

extension Tool {
    var category: ToolCategory { .utilities }
    var summary: String { "" }
    var defaultEnabled: Bool { true }
    var showsTile: Bool { true }

    func start() {}
    func stop() {}

    func hotkeyFired() {
        if case .action(let run) = entry { run() }
    }
}

/// Launch-time list of tools plus the live enable/disable and custom-hotkey
/// plumbing the settings UI drives. Registers hotkeys and starts always-on
/// engines; adding a tool to the app is one `offer` call. `@Observable` so a
/// toggle or shortcut change re-renders the panel and settings without a
/// relaunch.
@MainActor
@Observable
final class ToolRegistry {
    /// Display metadata for every offered tool, enabled or not — drives the
    /// settings toggles and the help sheet without holding the live tool.
    /// `hotkeyLabel` tracks the *effective* chord (override or default) so both
    /// surfaces update the moment a shortcut changes.
    struct KnownTool {
        let id: String
        let title: String
        let icon: String
        let hotkeyLabel: String?
        let category: ToolCategory
        let summary: String
        let defaultEnabled: Bool
    }

    /// Enabled tools, in offer order.
    private(set) var all: [any Tool] = []
    /// Every offered tool, enabled or not — drives the settings toggles.
    private(set) var known: [KnownTool] = []

    /// Every offered tool instance in offer order, enabled or not. Tool inits
    /// are cheap by contract, so a disabled tool stays live and cost-free here,
    /// ready for `setEnabled` to start it without replaying the offer list.
    @ObservationIgnored private var catalog: [(id: String, tool: any Tool)] = []
    @ObservationIgnored private var hotkeyTokens: [String: HotKeyManager.Token] = [:]

    // MARK: - Registration

    /// Catalogs the tool and — unless the user disabled it — puts it live:
    /// a disabled tool's hotkeys and engines never load.
    func offer(_ tool: any Tool) {
        known.append(KnownTool(
            id: tool.id, title: tool.title, icon: tool.icon,
            hotkeyLabel: effectiveChord(for: tool)?.label, category: tool.category,
            summary: tool.summary, defaultEnabled: tool.defaultEnabled))
        catalog.append((id: tool.id, tool: tool))
        guard Prefs.isToolEnabled(tool.id, default: tool.defaultEnabled) else { return }
        all.append(tool)
        activate(tool)
    }

    // MARK: - Live enable / disable

    /// Flips a tool on or off without a relaunch: persists the choice, then
    /// registers (hotkey + `start()`) or tears it down (unregister + `stop()`).
    /// Rebuilds `all` from catalog order so panel tile order never shifts.
    func setEnabled(_ id: String, _ enabled: Bool) {
        Prefs.setToolEnabled(id, enabled)
        guard let entry = catalog.first(where: { $0.id == id }) else { return }
        if enabled { activate(entry.tool) } else { deactivate(entry.tool) }
        rebuildAll()
    }

    /// Sets or clears (`nil`) a tool's custom chord, live. Persists it, then —
    /// if the tool is enabled — swaps the running hotkey to the new effective
    /// chord. A disabled tool just stores the value for its next enable.
    func setHotkeyOverride(_ id: String, _ chord: HotKeyChord?) {
        Prefs.setHotkeyOverride(id, chord)
        guard let entry = catalog.first(where: { $0.id == id }) else { return }
        refreshKnownLabel(for: entry.tool)
        guard Prefs.isToolEnabled(id, default: entry.tool.defaultEnabled) else { return }
        unregisterHotkey(id)
        registerHotkey(entry.tool)
    }

    // MARK: - Settings UI support

    /// Effective chord label, read through `known` so the panel tile and the
    /// settings row re-render the instant a shortcut changes.
    func hotkeyLabel(for id: String) -> String? {
        known.first(where: { $0.id == id })?.hotkeyLabel
    }

    /// Removes a tool's shortcut entirely, live: no chord fires — not even the
    /// default — until the user records a new one or resets to default.
    func removeHotkey(_ id: String) {
        Prefs.removeHotkey(id)
        guard let entry = catalog.first(where: { $0.id == id }) else { return }
        refreshKnownLabel(for: entry.tool)
        unregisterHotkey(id)
    }

    func hasHotkeyOverride(_ id: String) -> Bool {
        Prefs.hasHotkeyCustomization(id)
    }

    /// Whether the tool ships with a default chord — drives the "reset to
    /// default" affordance, which only makes sense when there's a default to
    /// reset to.
    func hasDefaultHotkey(_ id: String) -> Bool {
        catalog.first(where: { $0.id == id })?.tool.hotkey != nil
    }

    /// Title of an enabled tool already bound to `chord`, or nil if it's free.
    /// Matches keyCode+modifiers (labels are cosmetic) against every enabled
    /// tool's effective chord, plus WindowsTool's static zone chords, which
    /// aren't surfaced through the single-`hotkey` protocol.
    func conflictingTool(for chord: HotKeyChord, excluding id: String) -> String? {
        for entry in catalog where entry.id != id {
            guard Prefs.isToolEnabled(entry.id, default: entry.tool.defaultEnabled) else { continue }
            if let existing = effectiveChord(for: entry.tool),
               existing.keyCode == chord.keyCode, existing.modifiers == chord.modifiers {
                return entry.tool.title
            }
            if let windows = entry.tool as? WindowsTool,
               WindowsTool.isZoneChord(keyCode: chord.keyCode, modifiers: chord.modifiers) {
                return windows.title
            }
        }
        return nil
    }

    // MARK: - Internals

    private func activate(_ tool: any Tool) {
        registerHotkey(tool)
        tool.start()
    }

    private func deactivate(_ tool: any Tool) {
        unregisterHotkey(tool.id)
        tool.stop()
    }

    private func rebuildAll() {
        all = catalog
            .filter { Prefs.isToolEnabled($0.id, default: $0.tool.defaultEnabled) }
            .map(\.tool)
    }

    /// Single choke point: resolves the effective chord and registers it,
    /// storing the token under the tool id. Tools that own a *set* of chords
    /// (Windows) have no single `hotkey` and register those in `start()`.
    private func registerHotkey(_ tool: any Tool) {
        guard let chord = effectiveChord(for: tool) else { return }
        hotkeyTokens[tool.id] = HotKeyManager.shared.register(
            keyCode: chord.keyCode, modifiers: chord.modifiers
        ) { [weak tool] in tool?.hotkeyFired() }
    }

    private func unregisterHotkey(_ id: String) {
        if let token = hotkeyTokens.removeValue(forKey: id) {
            HotKeyManager.shared.unregister(token)
        }
    }

    private func effectiveChord(for tool: any Tool) -> HotKeyChord? {
        if Prefs.isHotkeyRemoved(tool.id) { return nil }
        return Prefs.hotkeyOverride(tool.id) ?? tool.hotkey
    }

    private func refreshKnownLabel(for tool: any Tool) {
        guard let index = known.firstIndex(where: { $0.id == tool.id }) else { return }
        let existing = known[index]
        known[index] = KnownTool(
            id: existing.id, title: existing.title, icon: existing.icon,
            hotkeyLabel: effectiveChord(for: tool)?.label, category: existing.category,
            summary: existing.summary, defaultEnabled: existing.defaultEnabled)
    }
}
