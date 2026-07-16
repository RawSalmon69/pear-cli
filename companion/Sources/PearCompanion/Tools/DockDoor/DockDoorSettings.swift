import Foundation

/// Live per-tool settings for DockDoor hover-preview. Every value is persisted
/// under a `dockdoor.*` UserDefaults key and read at use time, so changes apply
/// with no relaunch. Accessors clamp on read so a stray `defaults write` can
/// never push the hover delay or preview size to a broken value.
enum DockDoorSettings {
    enum Key {
        static let hoverDelay = "dockdoor.hoverDelay"
        static let previewSize = "dockdoor.previewSize"
        static let showTitles = "dockdoor.showTitles"
        static let switcherEnabled = "dockdoor.switcher.enabled"
        static let switcherScope = "dockdoor.switcher.scope"
    }

    // Defaults.
    static let defaultHoverDelay: Double = 200 // ms
    static let defaultPreviewSize = DockPreviewSize.medium
    static let defaultShowTitles = true
    /// The ⌥-tab switcher is on by default — it only acts on ⌥-tab and is
    /// silent otherwise, so an on default costs nothing until summoned.
    static let defaultSwitcherEnabled = true
    static let defaultSwitcherScope = DockSwitcherScope.allWindows

    // Hover delay slider range, in milliseconds.
    static let hoverDelayRange: ClosedRange<Double> = 0 ... 500

    // MARK: Read accessors (clamp on read)

    /// Hover-intent delay in milliseconds, clamped to `hoverDelayRange`.
    static func hoverDelay(_ store: UserDefaults = .standard) -> Double {
        let value = store.object(forKey: Key.hoverDelay) == nil
            ? defaultHoverDelay
            : store.double(forKey: Key.hoverDelay)
        return min(max(value, hoverDelayRange.lowerBound), hoverDelayRange.upperBound)
    }

    static func previewSize(_ store: UserDefaults = .standard) -> DockPreviewSize {
        store.string(forKey: Key.previewSize).flatMap(DockPreviewSize.init) ?? defaultPreviewSize
    }

    static func showTitles(_ store: UserDefaults = .standard) -> Bool {
        store.object(forKey: Key.showTitles) == nil
            ? defaultShowTitles
            : store.bool(forKey: Key.showTitles)
    }

    static func switcherEnabled(_ store: UserDefaults = .standard) -> Bool {
        store.object(forKey: Key.switcherEnabled) == nil
            ? defaultSwitcherEnabled
            : store.bool(forKey: Key.switcherEnabled)
    }

    static func switcherScope(_ store: UserDefaults = .standard) -> DockSwitcherScope {
        store.string(forKey: Key.switcherScope).flatMap(DockSwitcherScope.init) ?? defaultSwitcherScope
    }
}

/// Which windows the ⌥-tab switcher cycles through. Mirrors DockDoor's
/// `SwitcherInvocationMode` (`.allWindows` / `.activeAppOnly`), trimmed to the
/// two scopes that matter without a live Dock: everything, or just the
/// frontmost app's windows.
enum DockSwitcherScope: String, CaseIterable, Identifiable {
    case allWindows, activeApp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allWindows: "All Windows"
        case .activeApp: "Active App"
        }
    }
}

/// Thumbnail tile size. The raw value is the persisted string; `maxDimension`
/// is the longest edge (points) a captured thumbnail is scaled to fit.
enum DockPreviewSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// Longest tile edge in points. The captured CGImage is fit into this box
    /// preserving aspect ratio.
    var maxDimension: CGFloat {
        switch self {
        case .small: 140
        case .medium: 200
        case .large: 280
        }
    }
}
