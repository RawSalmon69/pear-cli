// Adapted from Loop (GPL-3.0), https://github.com/MrKai77/Loop
//
// Loop's radial menu resolves a snap target from the cursor's offset relative
// to where the trigger was pressed: `MouseInteractionObserver` takes the
// atan2 angle of that offset, adds a half-sector bias, and floors into an
// evenly-spaced ring of directional actions (see
// `MouseInteractionObserver.processNewMouseLocation` and
// `CGPoint.angle(to:)`). Below a small distance it collapses to the center.
//
// We keep the same idea but reduce it to one pure, unit-testable function
// over a cursor offset in AppKit's y-up screen space (0° = +x / East,
// 90° = +y / North). No AX, no NSEvent, no screen — just geometry, so the
// whole direction→zone mapping can be exercised in isolation.

import Foundation

extension WindowZone {
    /// Number of directional sectors in the ring (4 cardinal halves + 4
    /// diagonal quarters). Each spans `360 / 8 = 45°`, centered on its compass
    /// point, matching Loop's evenly-spaced `directionalRadialMenuActions`.
    static let radialSectorCount = 8

    /// The snap target for a cursor `angle` (degrees, y-up: 0° = East,
    /// 90° = North) at `magnitude` points from the ring center. Within
    /// `deadzone` the ring has no direction, so this resolves to `.center`
    /// (Loop's small-movement center action). Pure — no I/O, no state.
    ///
    /// Sectors, biased by a half-sector so each compass point sits at a
    /// sector's midpoint (Loop's `+ halfAngleSpan` before the floor):
    ///   0 E → rightHalf   1 NE → topRightQuarter    2 N → topHalf
    ///   3 NW → topLeftQuarter                        4 W → leftHalf
    ///   5 SW → bottomLeftQuarter                     6 S → bottomHalf
    ///   7 SE → bottomRightQuarter
    static func radialZone(angleDegrees angle: Double, magnitude: CGFloat, deadzone: CGFloat) -> WindowZone {
        guard magnitude > deadzone else { return .center }

        // Normalize to [0, 360) so the wraparound at 0°/360° lands in the East
        // sector rather than falling off either end.
        let span = 360.0 / Double(radialSectorCount)
        let normalized = (angle.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let sector = Int((normalized + span / 2) / span) % radialSectorCount

        switch sector {
        case 0: return .rightHalf
        case 1: return .topRightQuarter
        case 2: return .topHalf
        case 3: return .topLeftQuarter
        case 4: return .leftHalf
        case 5: return .bottomLeftQuarter
        case 6: return .bottomHalf
        default: return .bottomRightQuarter
        }
    }

    /// Convenience over a raw cursor offset `(dx, dy)` from the ring center in
    /// y-up screen space (`dy > 0` = cursor moved up). Loop tracks exactly this
    /// offset from the press point and derives the sector from its angle.
    static func radialZone(dx: CGFloat, dy: CGFloat, deadzone: CGFloat) -> WindowZone {
        let magnitude = (dx * dx + dy * dy).squareRoot()
        let angle = atan2(Double(dy), Double(dx)) * 180 / .pi
        return radialZone(angleDegrees: angle, magnitude: magnitude, deadzone: deadzone)
    }

    /// The ring sector index (0…7, East-origin counter-clockwise) this zone
    /// highlights, or `nil` for zones the ring fills wholesale (`.center`,
    /// `.maximize`) or that never appear in the ring. Drives the ring's
    /// highlight; the inverse of `radialZone`'s sector switch.
    var radialSectorIndex: Int? {
        switch self {
        case .rightHalf: 0
        case .topRightQuarter: 1
        case .topHalf: 2
        case .topLeftQuarter: 3
        case .leftHalf: 4
        case .bottomLeftQuarter: 5
        case .bottomHalf: 6
        case .bottomRightQuarter: 7
        default: nil
        }
    }

    /// Arrow-key refinement of the current selection while the ring is open
    /// (Loop's keyboard direction picking: ← then ↑ lands top-left). An arrow
    /// orthogonal to the currently selected half combines into the quarter;
    /// anything else selects the arrow's own half. Pure.
    static func arrowSelection(current: WindowZone?, arrow: RadialArrow) -> WindowZone {
        switch (arrow, current) {
        case (.left, .topHalf): .topLeftQuarter
        case (.left, .bottomHalf): .bottomLeftQuarter
        case (.left, _): .leftHalf
        case (.right, .topHalf): .topRightQuarter
        case (.right, .bottomHalf): .bottomRightQuarter
        case (.right, _): .rightHalf
        case (.up, .leftHalf): .topLeftQuarter
        case (.up, .rightHalf): .topRightQuarter
        case (.up, _): .topHalf
        case (.down, .leftHalf): .bottomLeftQuarter
        case (.down, .rightHalf): .bottomRightQuarter
        case (.down, _): .bottomHalf
        }
    }

    /// Signed shortest angular difference `to − from` in degrees, wrapped to
    /// (−180, 180]. Summing these while the cursor circles the ring is how the
    /// full-circle → maximize gesture (Loop's namesake) accumulates a ±360°
    /// sweep without tripping over the 0°/360° seam. Pure.
    static func wrappedAngleDelta(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta <= -180 { delta += 360 }
        return delta
    }
}

/// An arrow key pressed while the ring is open.
enum RadialArrow {
    case left, right, up, down
}
