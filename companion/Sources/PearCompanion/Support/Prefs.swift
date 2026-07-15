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
    /// never load. Default on; takes effect at next launch.
    static func toolDisabledKey(_ id: String) -> String { "toolDisabled.\(id)" }

    static func isToolEnabled(_ id: String) -> Bool {
        !UserDefaults.standard.bool(forKey: toolDisabledKey(id))
    }

    static func setToolEnabled(_ id: String, _ enabled: Bool) {
        UserDefaults.standard.set(!enabled, forKey: toolDisabledKey(id))
    }
}
