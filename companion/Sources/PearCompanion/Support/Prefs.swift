import Foundation

/// UserDefaults-backed toggles, one place so views and services agree on keys.
enum Prefs {
    static let soundsKey = "soundEffectsEnabled"
    static let autoSaveKey = "screenshotAutoSave"
    static let colorFormatKey = "colorCopyFormat"

    /// Default on for both — opt-out, not opt-in.
    static var soundsEnabled: Bool {
        UserDefaults.standard.object(forKey: soundsKey) as? Bool ?? true
    }

    static var screenshotAutoSave: Bool {
        UserDefaults.standard.object(forKey: autoSaveKey) as? Bool ?? true
    }

    /// Which format the eyedropper drops on the clipboard — read by both the
    /// tile "Pick color" button and the global hotkey. Defaults to HEX.
    static var colorFormat: ColorFormat {
        UserDefaults.standard.string(forKey: colorFormatKey)
            .flatMap(ColorFormat.init(rawValue:)) ?? .hex
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

    // MARK: - Per-tool hotkey overrides

    /// A custom chord replaces the tool's built-in one; absence means "use the
    /// default". Stored as "keyCode,modifiers,label" — labels never contain a
    /// comma (they're modifier symbols plus a key name), so a plain split is
    /// enough. `defaults` is injectable so persistence round-trips can be
    /// tested without touching the real domain.
    static func toolHotkeyKey(_ id: String) -> String { "toolHotkey.\(id)" }

    static func hotkeyOverride(_ id: String, defaults: UserDefaults = .standard) -> HotKeyChord? {
        guard let raw = defaults.string(forKey: toolHotkeyKey(id)) else { return nil }
        let parts = raw.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let keyCode = Int(parts[0]), let modifiers = Int(parts[1]) else { return nil }
        return HotKeyChord(keyCode: keyCode, modifiers: modifiers, label: String(parts[2]))
    }

    static func setHotkeyOverride(_ id: String, _ chord: HotKeyChord?, defaults: UserDefaults = .standard) {
        let key = toolHotkeyKey(id)
        guard let chord else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set("\(chord.keyCode),\(chord.modifiers),\(chord.label)", forKey: key)
    }
}
