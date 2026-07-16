import Foundation

/// UserDefaults-backed toggles, one place so views and services agree on keys.
enum Prefs {
    static let soundsKey = "soundEffectsEnabled"
    static let autoSaveKey = "screenshotAutoSave"

    /// Default on for both — opt-out, not opt-in.
    static var soundsEnabled: Bool {
        UserDefaults.standard.object(forKey: soundsKey) as? Bool ?? true
    }

    static var screenshotAutoSave: Bool {
        UserDefaults.standard.object(forKey: autoSaveKey) as? Bool ?? true
    }

    // MARK: - Per-tool toggles

    /// Disabled tools are never registered, so their hotkeys and engines
    /// never load. Takes effect at next launch. Stores the enabled state
    /// explicitly (presence = user chose), so a tool can default off — the
    /// menu-bar hider must, since auto-collapsing on launch can hide icons.
    static func toolEnabledKey(_ id: String) -> String { "toolEnabled.\(id)" }

    static func isToolEnabled(_ id: String, default defaultEnabled: Bool = true) -> Bool {
        (UserDefaults.standard.object(forKey: toolEnabledKey(id)) as? Bool) ?? defaultEnabled
    }

    static func setToolEnabled(_ id: String, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: toolEnabledKey(id))
    }
}
