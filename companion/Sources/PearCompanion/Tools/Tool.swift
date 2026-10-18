import Observation
import SwiftUI

/// A global hotkey chord plus the label shown under the tool's tile.
struct HotKeyChord: Equatable {
    let keyCode: Int
    let modifiers: Int
    let label: String
}

/// Who a chord belongs to: a tool's single hotkey, or one Windows snap binding
/// (by its `WindowSettings.ChordBinding.id`).
enum ShortcutOwner: Hashable {
    case tool(String)
    case windows(String)
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
    /// Extra words the panel search matches besides title and summary
    /// (Grab Text: "ocr"). Defaults empty.
    var aliases: [String] { get }
    /// Short live state on the tool's panel row ("2 on"). Defaults nil; read in
    /// the row's body, so an `@Observable` source redraws it.
    var status: String? { get }
    /// Whether the tool is on for a fresh install. Defaults true; a tool that
    /// alters the system on launch (the menu-bar hider) opts out.
    var defaultEnabled: Bool { get }
    /// Whether the tool shows a tile in the panel's Tools grid. Defaults true;
    /// the `panel` pseudo-tool opts out — you don't open the panel from inside
    /// it — while still registering a rebindable hotkey through the registry.
    var showsTile: Bool { get }
    /// Whether a shortcut can do anything for this tool. Defaults true; a
    /// popover tool with no `hotkeyFired` of its own opts out, so Settings
    /// doesn't offer a recorder whose chord would fire into nothing.
    var acceptsHotkey: Bool { get }
    /// Whether the tool keeps working when the trial has ended and there is no
    /// licence. Defaults false: an expired app registers nothing, exactly as a
    /// user-disabled tool does.
    ///
    /// The two tools that hold the user's own content inside the app opt in,
    /// because `site/terms.html` §2 promises in writing that notes and shelf
    /// items "remain accessible and exportable" after the trial ends. Locking
    /// someone out of their own writing to sell them a licence is not a
    /// negotiating position. Saved screenshots need no exemption — they are plain
    /// files in a folder, reachable in Finder with the app locked.
    var survivesExpiry: Bool { get }
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
    var aliases: [String] { [] }
    var status: String? { nil }
    var defaultEnabled: Bool { true }
    var showsTile: Bool { true }
    var acceptsHotkey: Bool { true }
    var survivesExpiry: Bool { false }

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
        let acceptsHotkey: Bool
        /// Whether the user has this tool switched on. Held here rather than
        /// read from `Prefs` at the point of use because `UserDefaults` is not
        /// observable: a settings toggle bound straight to `Prefs` writes fine
        /// and then never redraws, so the switch stays visually off until
        /// something unrelated happens to invalidate the view.
        let isEnabled: Bool
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
    /// Ids currently live, so activation is idempotent.
    @ObservationIgnored private var activated: Set<String> = []

    /// Whether the paid tools are locked. Injected by `AppEnvironment` from the
    /// `EntitlementStore`; a registry built without it is unlocked, which keeps
    /// every existing test and any non-paid context working unchanged.
    ///
    /// **This is the entire paywall.** Gating here means a locked tool never
    /// registers a hotkey and never has `start()` called, so there are no
    /// `if licensed` checks scattered through twenty tools to get wrong — it is
    /// the same mechanism that already makes a user-disabled tool inert.
    @ObservationIgnored var isLocked: () -> Bool = { false }

    /// The Windows snap chords as they are now, in default order, removed ones
    /// left out. Held here so the Shortcuts page redraws and the conflict check
    /// sees the live set. `windowsStore` is injectable for tests; production and
    /// `WindowTrigger` both use `.standard`.
    private(set) var windowsChords: [WindowSettings.ChordBinding]
    @ObservationIgnored private let windowsStore: UserDefaults

    init(windowsStore: UserDefaults = .standard) {
        self.windowsStore = windowsStore
        windowsChords = WindowSettings.chords(windowsStore)
    }

    // MARK: - Registration

    /// Catalogs the tool and — unless the user disabled it, or the app is locked
    /// and the tool does not survive expiry — puts it live: an unregistered
    /// tool's hotkeys and engines never load.
    func offer(_ tool: any Tool) {
        known.append(KnownTool(
            id: tool.id, title: tool.title, icon: tool.icon,
            hotkeyLabel: effectiveChord(for: tool)?.label, category: tool.category,
            summary: tool.summary, defaultEnabled: tool.defaultEnabled,
            acceptsHotkey: tool.acceptsHotkey,
            isEnabled: Prefs.isToolEnabled(tool.id, default: tool.defaultEnabled)))
        catalog.append((id: tool.id, tool: tool))
        guard shouldRun(tool) else { return }
        all.append(tool)
        activate(tool)
    }

    /// The one gate: the user wants it on, and either the app is unlocked or the
    /// tool holds the user's own content and must stay reachable regardless.
    private func shouldRun(_ tool: any Tool) -> Bool {
        guard Prefs.isToolEnabled(tool.id, default: tool.defaultEnabled) else { return false }
        return !isLocked() || tool.survivesExpiry
    }

    /// The live tool an App Intent runs, through the same gate as registration:
    /// a tool the user switched off, or one the paywall locks, throws
    /// `ToolUnavailable` instead of running.
    func runnableTool(_ id: String) throws -> any Tool {
        guard let entry = catalog.first(where: { $0.id == id }) else {
            throw ToolUnavailable(title: id)
        }
        guard shouldRun(entry.tool) else { throw ToolUnavailable(title: entry.tool.title) }
        return entry.tool
    }

    /// The offered tool instance, enabled or not, for a Settings page that edits
    /// a tool's own options (the menu-bar hider's manager). Never runs it.
    func offeredTool(_ id: String) -> (any Tool)? {
        catalog.first { $0.id == id }?.tool
    }

    /// The app's registry, set once at launch so App Intents (which the system
    /// constructs itself) can reach it. Nil in tests and before launch.
    static var live: ToolRegistry?

    // MARK: - Live enable / disable

    /// Flips a tool on or off without a relaunch: persists the choice, then
    /// registers (hotkey + `start()`) or tears it down (unregister + `stop()`).
    /// Rebuilds `all` from catalog order so panel tile order never shifts.
    func setEnabled(_ id: String, _ enabled: Bool) {
        Prefs.setToolEnabled(id, enabled)
        refreshKnownEnabled(id, enabled)
        guard let entry = catalog.first(where: { $0.id == id }) else { return }
        if shouldRun(entry.tool) { activate(entry.tool) } else { deactivate(entry.tool) }
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

    /// Who already owns `chord`, as the warning names it — a tool's title, or
    /// "Windows: Left Half" — or nil if it's free. The one answer for both sets:
    /// every enabled tool's effective chord, then the live Windows bindings.
    /// Matches keyCode+modifiers only (labels are cosmetic). A disabled tool, or
    /// Windows switched off, registers nothing and so blocks nothing; but a
    /// Windows binding being recorded still sees the other Windows bindings,
    /// because that clash is inside the set and bites the moment it is enabled.
    func conflictingTool(for chord: HotKeyChord, excluding owner: ShortcutOwner) -> String? {
        func matches(_ other: HotKeyChord) -> Bool {
            other.keyCode == chord.keyCode && other.modifiers == chord.modifiers
        }
        for entry in catalog where owner != .tool(entry.id) {
            guard shouldRun(entry.tool), let existing = effectiveChord(for: entry.tool),
                  matches(existing) else { continue }
            return entry.tool.title
        }
        let windows = catalog.first { $0.id == WindowsTool.toolID }
        let recordingWindows = if case .windows = owner { true } else { false }
        guard recordingWindows || windows.map({ shouldRun($0.tool) }) == true else { return nil }
        for binding in windowsChords where owner != .windows(binding.id) && matches(binding.chord) {
            return "\(windows?.tool.title ?? "Windows"): \(RingLabel.text(for: binding.action))"
        }
        return nil
    }

    // MARK: - Windows chords

    func windowsChord(for id: String) -> HotKeyChord? {
        windowsChords.first { $0.id == id }?.chord
    }

    func isWindowsChordCustomized(_ id: String) -> Bool {
        WindowSettings.isChordCustomized(id, windowsStore)
    }

    /// Rebinds one Windows chord, or restores its default with nil, live.
    func setWindowsChord(_ chord: HotKeyChord?, for id: String) {
        WindowSettings.setChord(chord, for: id, windowsStore)
        reloadWindowsChords()
    }

    func removeWindowsChord(_ id: String) {
        WindowSettings.removeChord(for: id, windowsStore)
        reloadWindowsChords()
    }

    /// Every tool shortcut back to its default (removed ones too), and every
    /// Windows chord back to its default.
    func resetAllShortcuts() {
        for entry in catalog where Prefs.hasHotkeyCustomization(entry.id) {
            setHotkeyOverride(entry.id, nil)
        }
        WindowSettings.resetChords(windowsStore)
        reloadWindowsChords()
    }

    /// The Windows tool registers its chords itself in `start()`, so a running
    /// one is stopped and started to pick up the change (both are idempotent and
    /// cheap; `WindowTrigger` documents this as its rebind path). A disabled one
    /// just reads the stored value at its next enable.
    private func reloadWindowsChords() {
        windowsChords = WindowSettings.chords(windowsStore)
        guard let entry = catalog.first(where: { $0.id == WindowsTool.toolID }),
              activated.contains(entry.id) else { return }
        entry.tool.stop()
        entry.tool.start()
    }

    // MARK: - Internals

    /// Idempotent: a tool already live is not started twice, and one already
    /// torn down is not stopped twice. `reregister` leans on that, and so does a
    /// settings toggle flipped faster than the UI can keep up.
    private func activate(_ tool: any Tool) {
        guard activated.insert(tool.id).inserted else { return }
        registerHotkey(tool)
        tool.start()
    }

    private func deactivate(_ tool: any Tool) {
        guard activated.remove(tool.id) != nil else { return }
        unregisterHotkey(tool.id)
        tool.stop()
    }

    /// Re-evaluates every catalogued tool against the gate and brings the live
    /// set back in line. Called when the entitlement changes: a licence entered
    /// mid-session must bring the tools back without a relaunch, and `isLocked`
    /// being read live is not enough — nothing would re-register the hotkeys or
    /// call `start()`.
    func reregister() {
        for entry in catalog {
            if shouldRun(entry.tool) { activate(entry.tool) } else { deactivate(entry.tool) }
        }
        rebuildAll()
    }

    private func rebuildAll() {
        all = catalog.filter { shouldRun($0.tool) }.map(\.tool)
    }

    /// Single choke point: resolves the effective chord and registers it,
    /// storing the token under the tool id.
    private func registerHotkey(_ tool: any Tool) {
        // Tests drive the registry with real chords; none may claim a hotkey on
        // the developer's live session (same guard as `WindowTrigger`).
        guard !CleanModeRuntime.isRunningTests, let chord = effectiveChord(for: tool) else { return }
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
        guard tool.acceptsHotkey else { return nil }
        if Prefs.isHotkeyRemoved(tool.id) { return nil }
        return Prefs.hotkeyOverride(tool.id) ?? tool.hotkey
    }

    private func refreshKnownLabel(for tool: any Tool) {
        guard let index = known.firstIndex(where: { $0.id == tool.id }) else { return }
        let existing = known[index]
        known[index] = KnownTool(
            id: existing.id, title: existing.title, icon: existing.icon,
            hotkeyLabel: effectiveChord(for: tool)?.label, category: existing.category,
            summary: existing.summary, defaultEnabled: existing.defaultEnabled,
            acceptsHotkey: existing.acceptsHotkey,
            isEnabled: existing.isEnabled)
    }

    /// Republishes a tool's on/off into `known`, which is what a settings toggle
    /// observes. Without this the write happens and the switch does not move.
    private func refreshKnownEnabled(_ id: String, _ enabled: Bool) {
        guard let index = known.firstIndex(where: { $0.id == id }) else { return }
        let existing = known[index]
        known[index] = KnownTool(
            id: existing.id, title: existing.title, icon: existing.icon,
            hotkeyLabel: existing.hotkeyLabel, category: existing.category,
            summary: existing.summary, defaultEnabled: existing.defaultEnabled,
            acceptsHotkey: existing.acceptsHotkey,
            isEnabled: enabled)
    }

    /// The user's on/off for a tool, read from observable state so a view bound
    /// to it actually redraws when it changes.
    func isEnabled(_ id: String) -> Bool {
        known.first { $0.id == id }?.isEnabled ?? false
    }
}

/// Why a Shortcuts action did not run: its tool is off (or locked) in Settings.
/// `localizedStringResource` is the failure text Shortcuts shows.
struct ToolUnavailable: Error, CustomLocalizedStringResourceConvertible {
    let title: String
    var message: String { "\(title) is turned off in Pear Settings" }
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}
