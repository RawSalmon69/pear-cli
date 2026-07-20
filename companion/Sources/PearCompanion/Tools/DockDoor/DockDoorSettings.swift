import Foundation

/// Live per-tool settings for DockDoor hover-preview. Every value is persisted
/// under a `dockdoor.*` UserDefaults key and read at use time, so changes apply
/// with no relaunch. Accessors clamp on read so a stray `defaults write` can
/// never push the hover delay or preview size to a broken value.
enum DockDoorSettings {
    enum Key {
        static let hoverDelay = "dockdoor.hoverDelay"
        static let previewSize = "dockdoor.previewSize"
        static let previewPlacement = "dockdoor.previewPlacement"
        static let previewGap = "dockdoor.previewGap"
        static let showTitles = "dockdoor.showTitles"
        static let keepOpen = "dockdoor.keepOpen"
    }

    // Defaults.
    static let defaultHoverDelay: Double = 200 // ms
    static let defaultPreviewSize = DockPreviewSize.medium
    /// Preview follows the Dock edge by default, so bottom-Dock users keep the
    /// good default (panel above the icon); side-Dock users can override.
    static let defaultPreviewPlacement = DockPreviewPlacement.auto
    /// Breathing room between the icon and the panel, in points. Matches the
    /// former hard-coded `panelOrigin` gap, so `.auto` + this default reproduces
    /// the prior behavior exactly.
    static let defaultPreviewGap: Double = 8
    static let defaultShowTitles = true
    /// Off = classic hover behavior (panel follows the cursor away). On, the
    /// panel stays up after the cursor leaves the icon and panel, dismissing
    /// on Esc, a tile click, hovering a different icon, or a click anywhere
    /// else.
    static let defaultKeepOpen = false

    // Hover delay slider range, in milliseconds.
    static let hoverDelayRange: ClosedRange<Double> = 0 ... 500

    // Preview gap stepper range, in points.
    static let previewGapRange: ClosedRange<Double> = 0 ... 80

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

    static func previewPlacement(_ store: UserDefaults = .standard) -> DockPreviewPlacement {
        store.string(forKey: Key.previewPlacement).flatMap(DockPreviewPlacement.init) ?? defaultPreviewPlacement
    }

    /// Icon-to-panel gap in points, clamped to `previewGapRange`.
    static func previewGap(_ store: UserDefaults = .standard) -> CGFloat {
        let value = store.object(forKey: Key.previewGap) == nil
            ? defaultPreviewGap
            : store.double(forKey: Key.previewGap)
        return CGFloat(min(max(value, previewGapRange.lowerBound), previewGapRange.upperBound))
    }

    static func showTitles(_ store: UserDefaults = .standard) -> Bool {
        store.object(forKey: Key.showTitles) == nil
            ? defaultShowTitles
            : store.bool(forKey: Key.showTitles)
    }

    static func keepPanelOpen(_ store: UserDefaults = .standard) -> Bool {
        store.object(forKey: Key.keepOpen) == nil
            ? defaultKeepOpen
            : store.bool(forKey: Key.keepOpen)
    }
}

/// Where the hover preview appears relative to the hovered Dock icon.
/// `.auto` keeps the per-Dock-side default (bottom → above, left → right of the
/// icon, right → left of the icon); the other cases force one anchor regardless
/// of Dock side, for users whose Dock edge puts the auto panel over their
/// window content. The panel is always clamped inside the visible screen.
enum DockPreviewPlacement: String, CaseIterable, Identifiable {
    case auto, above, below, left, right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto (follow Dock)"
        case .above: "Above icon"
        case .below: "Below icon"
        case .left: "Left of icon"
        case .right: "Right of icon"
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
