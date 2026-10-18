import Foundation

/// UserDefaults-backed toggles, one place so views and services agree on keys.
enum Prefs {
    static let soundsKey = "soundEffectsEnabled"
    static let autoSaveKey = "screenshotAutoSave"
    static let colorFormatKey = "colorCopyFormat"
    static let previewAutoDismissKey = "screenshotPreviewAutoDismiss"
    static let previewAutoDismissSecondsKey = "screenshotPreviewAutoDismissSeconds"
    static let previewMaxStackKey = "screenshotPreviewMaxStack"
    static let panelClosesOnFocusLossKey = "panelClosesOnFocusLoss"
    static let hdBackgroundRemovalKey = "hdBackgroundRemoval"

    /// Default on for both — opt-out, not opt-in.
    static var soundsEnabled: Bool {
        UserDefaults.standard.object(forKey: soundsKey) as? Bool ?? true
    }

    /// The panel closes when it loses focus (like a normal menu popover).
    /// Default on; opt out to pin it open until an explicit close (Esc, the
    /// menu-bar click, or ⌃⇧P) — the pre-2.7.x behavior.
    static var panelClosesOnFocusLoss: Bool {
        UserDefaults.standard.object(forKey: panelClosesOnFocusLossKey) as? Bool ?? true
    }

    static var screenshotAutoSave: Bool {
        UserDefaults.standard.object(forKey: autoSaveKey) as? Bool ?? true
    }

    /// Opt-in: use the downloaded high-quality (BEN2) model for background
    /// removal. Default off — the built-in Vision cutout needs no download.
    static var hdBackgroundRemoval: Bool {
        UserDefaults.standard.bool(forKey: hdBackgroundRemovalKey)
    }

    /// Which format the eyedropper drops on the clipboard — read by both the
    /// tile "Pick color" button and the global hotkey. Defaults to HEX.
    static var colorFormat: ColorFormat {
        UserDefaults.standard.string(forKey: colorFormatKey)
            .flatMap(ColorFormat.init(rawValue:)) ?? .hex
    }

    // MARK: - Screenshot preview stack

    /// Previews persist until swiped away unless the user opts into a timeout.
    static var previewAutoDismiss: Bool {
        UserDefaults.standard.bool(forKey: previewAutoDismissKey)
    }

    static var previewAutoDismissSeconds: Double {
        let stored = UserDefaults.standard.object(forKey: previewAutoDismissSecondsKey) as? Double
        return stored ?? 6
    }

    /// How many previews may stack before the oldest is evicted.
    static var previewMaxStack: Int {
        let stored = UserDefaults.standard.object(forKey: previewMaxStackKey) as? Int
        return max(1, stored ?? 5)
    }

    // MARK: - Settings window

    static let settingsPageKey = "settingsLastPage"

    /// The page Settings opens on: the last one shown, or General. A stored page
    /// that is not offered (Licence in a free build) also gives General.
    static func settingsPage(defaults: UserDefaults = .standard) -> SettingsPage {
        SettingsPage.resolved(defaults.string(forKey: settingsPageKey))
    }

    static func setSettingsPage(_ page: SettingsPage, defaults: UserDefaults = .standard) {
        defaults.set(page.rawValue, forKey: settingsPageKey)
    }

    // MARK: - Panel pins

    static let pinnedToolsKey = "panelPinnedTools"
    static let pickYourFourDismissedKey = "panelPickYourFourDismissed"
    /// Windows defaults off, so it is not here.
    static let defaultPinnedTools = ["screenshot", "ocr", "clipboard", "shelf"]

    /// The user's pinned tool ids, in order. Absence means the defaults; an
    /// empty list is a real choice and stays empty (the panel still fills its
    /// row from the other tools).
    static func pinnedTools(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: pinnedToolsKey) ?? defaultPinnedTools
    }

    /// Any pin change also retires the "Pick your four" card for good: whoever
    /// changed a pin has found pinning. The panel and Settings both call this.
    static func setPinnedTools(_ ids: [String], defaults: UserDefaults = .standard) {
        defaults.set(ids, forKey: pinnedToolsKey)
        dismissPickYourFour(defaults: defaults)
    }

    static func isPickYourFourDismissed(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: pickYourFourDismissedKey)
    }

    static func dismissPickYourFour(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: pickYourFourDismissedKey)
    }

    // MARK: - Recent captures

    static let recentCapturesKey = "recentCaptures"
    /// How many filed captures are remembered; the panel shows the newest three
    /// that still exist.
    static let recentCapturesKept = 10

    /// Newest first, minus any whose file is gone (the 7-day sweep, or the user
    /// deleted it). Stored as plain paths: every entry is a file Pear filed
    /// itself. `exists` is injected so the filter is testable off-disk.
    static func recentCaptures(
        defaults: UserDefaults = .standard,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [URL] {
        (defaults.stringArray(forKey: recentCapturesKey) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: false) }
            .filter(exists)
    }

    /// Puts a just-filed capture first, dropping any older entry for the same
    /// file and anything past the cap.
    static func recordCapture(_ url: URL, defaults: UserDefaults = .standard) {
        let path = url.path
        let older = (defaults.stringArray(forKey: recentCapturesKey) ?? []).filter { $0 != path }
        defaults.set(Array(([path] + older).prefix(recentCapturesKept)), forKey: recentCapturesKey)
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

    /// Sentinel raw value: the user removed the binding entirely — no chord
    /// fires, not even the tool's default. (Also parses to nil below, so an
    /// older build reading it just falls back to the default chord.)
    static let hotkeyRemovedValue = "none"

    static func isHotkeyRemoved(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: toolHotkeyKey(id)) == hotkeyRemovedValue
    }

    static func removeHotkey(_ id: String, defaults: UserDefaults = .standard) {
        defaults.set(hotkeyRemovedValue, forKey: toolHotkeyKey(id))
    }

    /// Whether the user customized this tool's shortcut at all — an override
    /// chord or an explicit removal. Drives the "reset to default" affordance.
    static func hasHotkeyCustomization(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: toolHotkeyKey(id)) != nil
    }

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
