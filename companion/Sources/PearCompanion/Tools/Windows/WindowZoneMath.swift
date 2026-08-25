import CoreGraphics
import Foundation

/// The built-in zone catalogue and the only place a `WindowAction` becomes a
/// concrete frame.
///
/// Pure on purpose: no `NSScreen`, no clock, no stored state. The caller passes
/// the screen's visible frame and the window's current frame in, which is what
/// makes every snap in the app testable at exact pixel values without a display
/// attached or a window to move.
enum WindowZoneMath {
    /// Thirds share these two constants so that one third's right edge and the
    /// next third's left edge are the *same* `Double`, which is what makes them
    /// tile (see `snapped`). Do not spell the second one `1 - third`: that is a
    /// different double than `2.0 / 3.0`, and the pair would stop meeting.
    private static let third = 1.0 / 3.0
    private static let twoThirds = 2.0 / 3.0

    // MARK: - Catalogue

    static let leftHalf = WindowZone(
        id: "left-half", name: "Left Half", unit: CGRect(x: 0, y: 0, width: 0.5, height: 1))
    static let rightHalf = WindowZone(
        id: "right-half", name: "Right Half", unit: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
    static let topHalf = WindowZone(
        id: "top-half", name: "Top Half", unit: CGRect(x: 0, y: 0, width: 1, height: 0.5))
    static let bottomHalf = WindowZone(
        id: "bottom-half", name: "Bottom Half", unit: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))

    static let topLeftQuarter = WindowZone(
        id: "top-left-quarter", name: "Top Left", unit: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
    static let topRightQuarter = WindowZone(
        id: "top-right-quarter", name: "Top Right", unit: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
    static let bottomLeftQuarter = WindowZone(
        id: "bottom-left-quarter", name: "Bottom Left", unit: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
    static let bottomRightQuarter = WindowZone(
        id: "bottom-right-quarter", name: "Bottom Right", unit: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))

    static let leftThird = WindowZone(
        id: "left-third", name: "Left Third", unit: CGRect(x: 0, y: 0, width: third, height: 1))
    static let centerThird = WindowZone(
        id: "center-third", name: "Center Third", unit: CGRect(x: third, y: 0, width: third, height: 1))
    static let rightThird = WindowZone(
        id: "right-third", name: "Right Third", unit: CGRect(x: twoThirds, y: 0, width: third, height: 1))
    static let leftTwoThirds = WindowZone(
        id: "left-two-thirds", name: "Left Two Thirds", unit: CGRect(x: 0, y: 0, width: twoThirds, height: 1))
    static let rightTwoThirds = WindowZone(
        id: "right-two-thirds", name: "Right Two Thirds", unit: CGRect(x: third, y: 0, width: twoThirds, height: 1))

    static let maximize = WindowZone(
        id: "maximize", name: "Maximise", unit: CGRect(x: 0, y: 0, width: 1, height: 1))

    /// Every built-in zone, in the order settings and the zone picker list them:
    /// halves, quarters, thirds, then maximise.
    static let zones: [WindowZone] = [
        leftHalf, rightHalf, topHalf, bottomHalf,
        topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter,
        leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds,
        maximize,
    ]

    /// Resolves a persisted zone id. Returns nil for an id this build no longer
    /// ships, so a stale setting degrades to "unbound" instead of a wrong snap.
    static func zone(id: String) -> WindowZone? {
        zones.first { $0.id == id }
    }

    // MARK: - Geometry

    /// The frame `action` would give a window whose current frame is `current`
    /// on a screen whose visible area is `visibleFrame`. Nil means "do nothing":
    /// only `.restore` with no previous frame can produce it.
    static func frame(
        for action: WindowAction, in visibleFrame: CGRect, current: CGRect, lastFrame: CGRect?
    ) -> CGRect? {
        switch action {
        case .snap(let zone):
            return snapped(zone, in: visibleFrame)
        case .center:
            return centered(current, in: visibleFrame)
        case .restore:
            return lastFrame.map(integral)
        case .minimize, .fullScreen, .close, .quitApp:
            // Not geometry: these change a window's existence, not its frame.
            // Nil means "no frame to apply", which the mover reads as "handle
            // this one yourself". `fullScreen` belongs here and not with the
            // zones: the window server owns a full-screen window's frame, so
            // there is no rect to compute and none to preview.
            return nil
        }
    }

    /// Rounds the zone's four *edges*, never its origin and size separately.
    ///
    /// Two complementary zones share an edge expression — the left half's `0.5`
    /// and the right half's `0.5` are the same double against the same width —
    /// so both edges round to the same integer and the pair tiles with no seam
    /// and no overlap at any width, odd ones included. Rounding the width on its
    /// own is what leaves the 1px gap between two snapped windows, and that gap
    /// is the first thing anyone notices.
    private static func snapped(_ zone: WindowZone, in visibleFrame: CGRect) -> CGRect {
        let minX = (visibleFrame.minX + zone.unit.minX * visibleFrame.width).rounded()
        let maxX = (visibleFrame.minX + zone.unit.maxX * visibleFrame.width).rounded()
        let minY = (visibleFrame.minY + zone.unit.minY * visibleFrame.height).rounded()
        let maxY = (visibleFrame.minY + zone.unit.maxY * visibleFrame.height).rounded()
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Keeps the window's size — `.center` is a move, not a resize.
    ///
    /// A window bigger than the screen centres to a negative offset, which puts
    /// its title bar and traffic lights off the top edge where the user can no
    /// longer grab them. Clamp the origin to the visible frame instead: too far
    /// left is recoverable, off-screen is not.
    private static func centered(_ current: CGRect, in visibleFrame: CGRect) -> CGRect {
        let x = visibleFrame.minX + (visibleFrame.width - current.width) / 2
        let y = visibleFrame.minY + (visibleFrame.height - current.height) / 2
        return integral(CGRect(
            x: max(visibleFrame.minX, x), y: max(visibleFrame.minY, y),
            width: current.width, height: current.height))
    }

    /// Every frame this type hands back is integral, including a restored one:
    /// a fractional device pixel shows up as a hairline of desktop between two
    /// snapped windows.
    private static func integral(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x.rounded(), y: rect.origin.y.rounded(),
            width: rect.width.rounded(), height: rect.height.rounded())
    }
}
