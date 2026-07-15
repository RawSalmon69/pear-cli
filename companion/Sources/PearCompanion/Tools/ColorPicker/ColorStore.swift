import AppKit
import Observation
import SwiftUI

/// One picked color plus every derived display format. Immutable — a new
/// value replaces `current`/history entries rather than mutating in place,
/// so `Identifiable`/`Equatable` conformance (both keyed off `hexString`)
/// stay trivially correct.
///
/// Color math (HSL, luminance, contrast ratio) is adapted from Pika (MIT,
/// https://github.com/superhighfives/pika) — see the per-property notes
/// below for which Pika file each was lifted from.
struct PickedColor: Identifiable, Equatable {
    let red: Double // sRGB, 0...1
    let green: Double
    let blue: Double
    let pickedAt: Date

    var id: String { hexString }

    init(red: Double, green: Double, blue: Double, pickedAt: Date = Date()) {
        self.red = red
        self.green = green
        self.blue = blue
        self.pickedAt = pickedAt
    }

    /// Builds from a color handed back by `NSColorSampler`. Sampled colors
    /// can arrive in a non-sRGB space (e.g. device RGB under a
    /// non-color-managed display), so this converts explicitly before
    /// reading components. Nil-safe: returns nil if the color can't be
    /// represented in sRGB at all.
    init?(sampled color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b))
    }

    /// Parses a persisted "#RRGGBB" (or bare "RRGGBB") hex string. Returns
    /// nil for anything malformed, so a corrupted UserDefaults entry is
    /// dropped instead of crashing.
    init?(hex: String) {
        var stripped = hex
        if stripped.hasPrefix("#") { stripped.removeFirst() }
        guard stripped.count == 6, let value = UInt32(stripped, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    private var rgb255: (r: Int, g: Int, b: Int) {
        (Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    var hexString: String {
        let c = rgb255
        return String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }

    var rgbString: String {
        let c = rgb255
        return "rgb(\(c.r), \(c.g), \(c.b))"
    }

    /// HSL components (h, s, l each 0...1). Adapted from Pika (MIT),
    /// `Pika/Extensions/NSColor+HSL.swift` `toHSLComponents()` — same
    /// min/max/delta derivation, rewritten against plain `Double` RGB
    /// instead of round-tripping through `NSColor`.
    private var hslComponents: (h: Double, s: Double, l: Double) {
        let minC = min(red, min(green, blue))
        let maxC = max(red, max(green, blue))
        let delta = maxC - minC

        var h: Double = 0
        if delta == 0 {
            h = 0
        } else if maxC == red {
            h = (green - blue) / delta
        } else if maxC == green {
            h = 2 + (blue - red) / delta
        } else {
            h = 4 + (red - green) / delta
        }
        h = min(h * 60, 360)
        if h < 0 { h += 360 }
        h /= 360

        let l = (minC + maxC) / 2
        let s: Double
        if maxC == minC {
            s = 0
        } else if l <= 0.5 {
            s = delta / (maxC + minC)
        } else {
            s = delta / (2 - maxC - minC)
        }
        return (h, s, l)
    }

    var hslString: String {
        let hsl = hslComponents
        let hue = Int((hsl.h * 360).rounded())
        let saturation = Int((hsl.s * 100).rounded())
        let lightness = Int((hsl.l * 100).rounded())
        return "hsl(\(hue), \(saturation)%, \(lightness)%)"
    }

    var swiftUIString: String {
        String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", red, green, blue)
    }

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue)
    }

    /// Relative luminance per WCAG 2.x. Adapted from Pika (MIT),
    /// `Pika/Extensions/NSColor+Luminance.swift` `luminance`.
    var luminance: Double {
        func linearize(_ component: Double) -> Double {
            component < 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }

    /// WCAG contrast ratio against another color, 1...21. Adapted from Pika
    /// (MIT), `Pika/Extensions/NSColor+Luminance.swift` `contrastRatio(with:)`.
    private func contrastRatio(against other: PickedColor) -> Double {
        let lighter = max(luminance, other.luminance)
        let darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// AA/AAA pass badges for the contrast ratio against `other`. Thresholds
    /// (normal text, WCAG 2.x) and the pass/fail split are adapted from
    /// Pika (MIT), `Pika/Extensions/WCAGCompliance.swift` `WCAGCompliance(with:)`.
    func contrast(against other: PickedColor) -> ContrastResult {
        ContrastResult(ratio: contrastRatio(against: other))
    }

    static let white = PickedColor(red: 1, green: 1, blue: 1)
    static let black = PickedColor(red: 0, green: 0, blue: 0)
}

/// One contrast-ratio result with WCAG 2.x pass badges for normal text
/// (AA ≥ 4.5:1, AAA ≥ 7:1). Adapted from Pika (MIT), `WCAGCompliance.swift`.
struct ContrastResult {
    let ratio: Double
    var passesAA: Bool { ratio >= 4.5 }
    var passesAAA: Bool { ratio >= 7.0 }
}

/// Picked-color state: the current selection plus a small persisted
/// history. Mirrors `ClipboardHistoryService`'s shape (`@MainActor
/// @Observable`, hex strings in UserDefaults — no JSON file needed for
/// eight short strings).
@MainActor
@Observable
final class ColorStore {
    private(set) var current: PickedColor?
    private(set) var history: [PickedColor] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let historyKey: String
    @ObservationIgnored private let maxHistory = 8

    /// `defaults`/`historyKey` are injectable so tests never touch the real
    /// UserDefaults suite.
    init(defaults: UserDefaults = .standard, historyKey: String = "colorPickerHistory") {
        self.defaults = defaults
        self.historyKey = historyKey
        history = Self.loadHistory(defaults: defaults, key: historyKey)
        current = history.first
    }

    /// Runs the native macOS eyedropper (`NSColorSampler`, macOS 10.15+) and
    /// records whatever color the user picks. `NSColorSampler`'s completion
    /// handler isn't guaranteed to fire on the main actor, so it only builds
    /// the Sendable `PickedColor` value before hopping back — the same
    /// weak-self-then-`Task { @MainActor in }` shape `ClipboardHistoryService`
    /// uses for its polling timer callback.
    func pickColor() {
        NSColorSampler().show { [weak self] color in
            guard let color, let picked = PickedColor(sampled: color) else { return }
            Task { @MainActor in
                self?.add(picked)
            }
        }
    }

    /// Adds a freshly-picked color: becomes current, moves to the front of
    /// history (de-duplicating by hex), capped at 8 entries. Exposed
    /// (rather than private) so tests can drive history behavior without
    /// going through the real eyedropper.
    func add(_ color: PickedColor) {
        current = color
        history.removeAll { $0.hexString == color.hexString }
        history.insert(color, at: 0)
        if history.count > maxHistory {
            history = Array(history.prefix(maxHistory))
        }
        persist()
    }

    /// Re-selects a history entry as the current color without reordering
    /// history — clicking a swatch shouldn't shuffle the strip under the
    /// cursor.
    func select(_ color: PickedColor) {
        current = color
    }

    /// Removes a history entry. Leaves `current` alone even if it matches —
    /// tidying the history strip isn't the same action as clearing the
    /// current swatch.
    func remove(_ color: PickedColor) {
        history.removeAll { $0.hexString == color.hexString }
        persist()
    }

    private func persist() {
        defaults.set(history.map(\.hexString), forKey: historyKey)
    }

    private static func loadHistory(defaults: UserDefaults, key: String) -> [PickedColor] {
        let hexes = defaults.stringArray(forKey: key) ?? []
        return hexes.compactMap { PickedColor(hex: $0) }
    }
}
