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
}
