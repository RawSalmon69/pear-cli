// The animation-speed curve values below are adapted from Loop (GPL-3.0),
// https://github.com/MrKai77/Loop, commit 3b632db5 — original file
// Loop/Utilities/AnimationConfiguration.swift. The rest (keys, defaults,
// ranges, accessors) is Pear's own settings plumbing.

import SwiftUI

/// The five animation speeds Loop exposes. In Pear a single picker drives the
/// snap-animation duration (`snapDuration`), and the ring/preview animate at
/// the matching Loop curve so the whole tool moves at one consistent speed.
/// `.instant` means no animation anywhere — snaps jump straight to the target.
enum WindowAnimationSpeed: String, CaseIterable, Identifiable {
    case fluid
    case relaxed
    case snappy
    case brisk
    case instant

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fluid: "Fluid"
        case .relaxed: "Relaxed"
        case .snappy: "Snappy"
        case .brisk: "Brisk"
        case .instant: "Instant"
        }
    }

    /// Snap (AX window-transform) duration in seconds, or `nil` for instant
    /// (no animation). Loop always animates the real window at a fixed 0.3 s;
    /// here the picker scales it so the owner can dial the snap feel.
    var snapDuration: Double? {
        switch self {
        case .fluid: 0.35
        case .relaxed: 0.28
        case .snappy: 0.22
        case .brisk: 0.15
        case .instant: nil
        }
    }

    // MARK: Ring + preview curves (Loop's AnimationConfiguration values)

    /// Ring pop-in / fill scale animation.
    var radialMenuSize: Animation {
        switch self {
        case .fluid, .relaxed, .snappy: .easeOut(duration: 0.2)
        case .brisk: .easeOut(duration: 0.15)
        case .instant: .easeOut(duration: 0.1)
        }
    }

    /// Direction-highlight rotation animation.
    var radialMenuAngle: Animation {
        self == .instant ? .linear(duration: 0) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.2)
    }

    /// Preview overlay glide between zone frames; `nil` disables the glide.
    var previewWindow: Animation? {
        switch self {
        case .fluid: .timingCurve(0, 0.26, 0.45, 1, duration: 0.325)
        case .relaxed: .timingCurve(0.15, 0.8, 0.46, 1, duration: 0.3)
        case .snappy: .timingCurve(0.22, 1, 0.47, 1, duration: 0.25)
        case .brisk: .timingCurve(0.25, 1, 0.48, 1, duration: 0.15)
        case .instant: nil
        }
    }

    /// Whether the ring animates its appearance at all.
    var animateRadialMenuAppearance: Bool { self != .instant }
}

/// Live per-tool settings for the Windows tool. Every value is persisted under
/// a `windows.*` UserDefaults key and read at use time, so changes apply with
/// no relaunch. Ranges mirror Loop's sliders; accessors clamp on read so a
/// stray `defaults write` can never push the ring/preview to a broken value.
enum WindowSettings {
    enum Key {
        static let ringCornerRadius = "windows.ring.cornerRadius"
        static let ringThickness = "windows.ring.thickness"
        static let previewPadding = "windows.preview.padding"
        static let previewBlur = "windows.preview.blur"
        static let animationEnabled = "windows.animation.enabled"
        static let animationSpeed = "windows.animation.speed"
        static let triggerDelay = "windows.triggerDelay"
    }

    // Defaults — Loop's where one exists, else Pear's chosen default.
    static let defaultRingCornerRadius: Double = 50 // Loop default
    static let defaultRingThickness: Double = 22 // Loop default
    static let defaultPreviewPadding: Double = 10 // Loop default
    static let defaultPreviewBlur = true // Loop default
    static let defaultAnimationEnabled = true // owner wants snap animation ON
    static let defaultAnimationSpeed = WindowAnimationSpeed.snappy // Loop default
    static let defaultTriggerDelay: Double = 0.1 // preserves the prior 100 ms hold

    // Slider ranges (Loop's).
    static let ringCornerRadiusRange: ClosedRange<Double> = 30 ... 50
    static let ringThicknessRange: ClosedRange<Double> = 10 ... 35
    static let previewPaddingRange: ClosedRange<Double> = 0 ... 20
    static let triggerDelayRange: ClosedRange<Double> = 0 ... 1

    // MARK: Read accessors (clamp on read)

    static func ringCornerRadius(_ store: UserDefaults = .standard) -> Double {
        clamped(store, Key.ringCornerRadius, defaultRingCornerRadius, ringCornerRadiusRange)
    }

    static func ringThickness(_ store: UserDefaults = .standard) -> Double {
        clamped(store, Key.ringThickness, defaultRingThickness, ringThicknessRange)
    }

    static func previewPadding(_ store: UserDefaults = .standard) -> Double {
        clamped(store, Key.previewPadding, defaultPreviewPadding, previewPaddingRange)
    }

    static func previewBlur(_ store: UserDefaults = .standard) -> Bool {
        store.object(forKey: Key.previewBlur) == nil ? defaultPreviewBlur : store.bool(forKey: Key.previewBlur)
    }

    static func animationEnabled(_ store: UserDefaults = .standard) -> Bool {
        store.object(forKey: Key.animationEnabled) == nil
            ? defaultAnimationEnabled
            : store.bool(forKey: Key.animationEnabled)
    }

    static func animationSpeed(_ store: UserDefaults = .standard) -> WindowAnimationSpeed {
        store.string(forKey: Key.animationSpeed).flatMap(WindowAnimationSpeed.init) ?? defaultAnimationSpeed
    }

    static func triggerDelay(_ store: UserDefaults = .standard) -> Double {
        clamped(store, Key.triggerDelay, defaultTriggerDelay, triggerDelayRange)
    }

    /// Effective snap-animation duration in seconds, honoring both the on/off
    /// toggle and the speed picker. `nil` means "no animation — jump to the
    /// final frame" (toggle off, or speed set to Instant).
    static func snapDuration(_ store: UserDefaults = .standard) -> Double? {
        guard animationEnabled(store) else { return nil }
        return animationSpeed(store).snapDuration
    }

    private static func clamped(
        _ store: UserDefaults,
        _ key: String,
        _ fallback: Double,
        _ range: ClosedRange<Double>
    ) -> Double {
        let value = store.object(forKey: key) == nil ? fallback : store.double(forKey: key)
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
