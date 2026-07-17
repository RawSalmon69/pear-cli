// Adapted from DockDoor (GPL-3.0), https://github.com/ejbills/DockDoor,
// commit 78b0862f — original: DockDoor/Utilities/DockUtils.swift and
// Views/Hover Window/Shared Components/SharedPreviewWindowCoordinator.swift.
//
// DockDoor reads the dock's edge from the private CoreDockGetOrientationAndPinning
// and its panel-anchoring math converts between AX (top-left) and AppKit
// (bottom-left) coordinate spaces via DockObserver.cgPointFromNSPoint. This port
// keeps the anchoring geometry but derives the dock edge from public screen
// insets (NSScreen.frame vs .visibleFrame) instead of the private CoreDock call,
// and does the coordinate flip about the primary screen's top edge. Pure math,
// no AppKit side effects, so the geometry is unit-testable without a live Dock.

import CoreGraphics
import Foundation

/// Which screen edge the Dock sits on. `.bottom` is the default (and the
/// fallback when the Dock is auto-hidden, so no inset is visible).
enum DockSide: Equatable {
    case bottom, left, right
}

/// Pure Dock geometry: edge detection from screen insets, AX↔AppKit rect
/// flipping, and preview-panel anchoring relative to the hovered icon.
enum DockGeometry {
    /// The minimum inset (points) that counts as "the Dock is here". Small
    /// insets (a notch, hairline) never trip a false edge; an auto-hidden Dock
    /// shows no inset and falls through to `.bottom`.
    static let minDockInset: CGFloat = 20

    /// Derives the Dock edge from the gap between a screen's full `frame` and
    /// its `visibleFrame`. The largest qualifying inset among bottom/left/right
    /// wins; the top inset is ignored because the menu bar also lives there and
    /// a top Dock is vanishingly rare (documented v1 limitation).
    static func side(frame: CGRect, visibleFrame: CGRect) -> DockSide {
        let bottom = visibleFrame.minY - frame.minY
        let left = visibleFrame.minX - frame.minX
        let right = frame.maxX - visibleFrame.maxX

        let best = max(bottom, max(left, right))
        guard best >= minDockInset else { return .bottom }

        if left == best { return .left }
        if right == best { return .right }
        return .bottom
    }

    /// Reflects an AX rect (top-left origin, y-down) into AppKit space
    /// (bottom-left origin, y-up) about the primary screen's top edge. The
    /// transform is its own inverse. `primaryMaxY` is the primary screen's
    /// `frame.maxY` (its full height when the primary origin is zero).
    static func flipToAppKit(_ rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Resolves a user placement setting into a concrete anchor. `.auto` follows
    /// the detected Dock side (bottom → above, left → right of the icon, right →
    /// left of the icon); every other case is returned unchanged, forcing that
    /// anchor regardless of where the Dock sits. Never returns `.auto`. Pure, so
    /// the auto-vs-override decision is unit-testable without a live Dock.
    static func resolvedPlacement(_ placement: DockPreviewPlacement, side: DockSide) -> DockPreviewPlacement {
        guard placement == .auto else { return placement }
        switch side {
        case .bottom: return .above
        case .left: return .right
        case .right: return .left
        }
    }

    /// Panel origin (AppKit bottom-left) that anchors a `panelSize` preview to a
    /// hovered dock `iconRect` (both in AppKit y-up space), sitting `gap` points
    /// off the icon on the `placement` side, then clamped fully inside
    /// `visibleFrame` with a `margin`. `placement` is expected already resolved
    /// via `resolvedPlacement`; `.auto` is folded into `.above` defensively so
    /// the switch stays total.
    ///
    /// - above → panel above the icon, horizontally centered on it.
    /// - below → panel below the icon, horizontally centered on it.
    /// - right → panel to the icon's right, vertically centered.
    /// - left → panel to the icon's left, vertically centered.
    static func panelOrigin(
        iconRect: CGRect,
        panelSize: CGSize,
        placement: DockPreviewPlacement,
        visibleFrame: CGRect,
        gap: CGFloat = 8,
        margin: CGFloat = 8
    ) -> CGPoint {
        var x: CGFloat
        var y: CGFloat

        switch placement {
        case .auto, .above:
            x = iconRect.midX - panelSize.width / 2
            y = iconRect.maxY + gap
        case .below:
            x = iconRect.midX - panelSize.width / 2
            y = iconRect.minY - panelSize.height - gap
        case .right:
            x = iconRect.maxX + gap
            y = iconRect.midY - panelSize.height / 2
        case .left:
            x = iconRect.minX - panelSize.width - gap
            y = iconRect.midY - panelSize.height / 2
        }

        x = clamp(x, min: visibleFrame.minX + margin, max: visibleFrame.maxX - panelSize.width - margin)
        y = clamp(y, min: visibleFrame.minY + margin, max: visibleFrame.maxY - panelSize.height - margin)
        return CGPoint(x: x, y: y)
    }

    /// Clamp helper that tolerates an inverted range (panel wider/taller than
    /// the visible frame): it pins to the lower bound rather than trapping.
    private static func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        guard hi > lo else { return lo }
        return Swift.min(Swift.max(value, lo), hi)
    }
}
