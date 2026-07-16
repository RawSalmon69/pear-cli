// Adapted from Loop (GPL-3.0), https://github.com/MrKai77/Loop
//
// Loop expresses each snap target as a normalized rect of fractional
// multipliers (`WindowDirection.frameMultiplyValues`) applied to a screen's
// bounds. We adopt the same idea but resolve directly against an `NSRect`
// visible frame so the math is pure and unit-testable, with no AX or screen
// dependency. All rects here are in AppKit's bottom-left-origin, y-up space
// (an `NSScreen.visibleFrame`); the engine flips the result into AX's
// top-left-origin space once, at the edge.

import Foundation

/// A snap target. `frame(in:)` is pure geometry over a visible-frame rect and
/// carries no AX state, so it can be exercised in isolation. `.center` is the
/// one zone that preserves the window's size, so its placement needs the
/// window size (`centered(_:in:)`) rather than a fractional rect.
enum WindowZone: String, CaseIterable {
    case leftHalf
    case rightHalf
    // Top/bottom halves exist only as radial-ring cardinal targets (the grid
    // and ⌃⌥ chords don't use them); the ring needs all four halves.
    case topHalf
    case bottomHalf
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter
    case leftThird
    case centerThird
    case rightThird
    case leftTwoThirds
    case rightTwoThirds
    case maximize
    case center

    /// Whether applying this zone should resize the window. `.center` moves
    /// only; every other zone sets an explicit size.
    var resizes: Bool { self != .center }

    /// Fractional rect `(x, y, width, height)` in 0…1, y-up (0 = bottom edge of
    /// the visible frame, matching AppKit). `nil` for `.center`, which has no
    /// screen-derived size. Adapted from Loop's `frameMultiplyValues`, with the
    /// y axis flipped from Loop's top-left convention to AppKit's bottom-left.
    var unit: NSRect? {
        switch self {
        case .leftHalf: NSRect(x: 0, y: 0, width: 1.0 / 2.0, height: 1.0)
        case .rightHalf: NSRect(x: 1.0 / 2.0, y: 0, width: 1.0 / 2.0, height: 1.0)
        // Top/bottom halves (y-up: "top" sits at y = 1/2).
        case .topHalf: NSRect(x: 0, y: 1.0 / 2.0, width: 1.0, height: 1.0 / 2.0)
        case .bottomHalf: NSRect(x: 0, y: 0, width: 1.0, height: 1.0 / 2.0)
        // Quarters (y-up: "top" rows sit at y = 1/2).
        case .topLeftQuarter: NSRect(x: 0, y: 1.0 / 2.0, width: 1.0 / 2.0, height: 1.0 / 2.0)
        case .topRightQuarter: NSRect(x: 1.0 / 2.0, y: 1.0 / 2.0, width: 1.0 / 2.0, height: 1.0 / 2.0)
        case .bottomLeftQuarter: NSRect(x: 0, y: 0, width: 1.0 / 2.0, height: 1.0 / 2.0)
        case .bottomRightQuarter: NSRect(x: 1.0 / 2.0, y: 0, width: 1.0 / 2.0, height: 1.0 / 2.0)
        // Thirds.
        case .leftThird: NSRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1.0)
        case .centerThird: NSRect(x: 1.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1.0)
        case .rightThird: NSRect(x: 2.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1.0)
        case .leftTwoThirds: NSRect(x: 0, y: 0, width: 2.0 / 3.0, height: 1.0)
        case .rightTwoThirds: NSRect(x: 1.0 / 3.0, y: 0, width: 2.0 / 3.0, height: 1.0)
        case .maximize: NSRect(x: 0, y: 0, width: 1.0, height: 1.0)
        case .center: nil
        }
    }

    /// The target frame inside `area` (a y-up visible frame). For `.center`,
    /// where no size is implied by the screen, this falls back to `area`
    /// itself; the engine calls `centered(_:in:)` with the window's real size
    /// instead of using this value.
    func frame(in area: NSRect) -> NSRect {
        guard let unit else { return area }
        return NSRect(
            x: area.minX + unit.minX * area.width,
            y: area.minY + unit.minY * area.height,
            width: unit.width * area.width,
            height: unit.height * area.height
        )
    }

    /// Centers `size` inside `area` without resizing (the `.center` action).
    /// Pure geometry, y-up.
    static func centered(_ size: NSSize, in area: NSRect) -> NSRect {
        NSRect(
            x: area.minX + (area.width - size.width) / 2.0,
            y: area.minY + (area.height - size.height) / 2.0,
            width: size.width,
            height: size.height
        )
    }
}
