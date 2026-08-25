import AppKit
import CoreGraphics
import SwiftUI

/// The ring's fixed geometry and, more importantly, its hit test.
///
/// Pure — no AppKit types, no window, no state — so the boundaries can be
/// asserted at exact values. The dead zone and the sector edges are the entire
/// reason a wobble does not fling a window across the desk, and they are not
/// something to eyeball on a screen.
///
/// Angles are measured **clockwise from 12 o'clock**. Two reasons: view space is
/// y-down and `atan2(dy, dx)` under y-down is already clockwise-positive from
/// 3 o'clock (the house precedent is `AccentWheelMath`, which documents the same
/// trap), and `RingSlot` declares its cases clockwise from the top — so once the
/// zero is moved to the top, index → slot is a plain lookup and the ring never
/// carries a second table that can fall out of step with the enum.
enum RingGeometry {
    /// Radii, outward from the pointer. Inside `deadZone` nothing is selected;
    /// out to `hubRadius` is the hub; out to `outerRadius` are the eight
    /// sectors; past that, nothing again — flicking clear of the ring is how a
    /// user backs out, and the drawn disc is exactly the target area, so what
    /// selects and what is lit are the same shape.
    static let deadZone: CGFloat = 24
    static let hubRadius: CGFloat = 58
    static let outerRadius: CGFloat = 132

    /// The panel is exactly the disc, so the drawn ring and the hit test cannot
    /// drift apart.
    static var side: CGFloat { outerRadius * 2 }

    /// The eight compass slots, clockwise from the top. Taken from `RingSlot`'s
    /// declaration order rather than restated here — `WindowContracts` promises
    /// that order and `RingGeometryTests` pins it, so adding a slot or moving
    /// one fails a test instead of silently rotating the ring.
    static let compass: [RingSlot] = RingSlot.allCases.filter { $0 != .hub }

    /// 45° per compass slot.
    static let sectorWidth: CGFloat = 2 * .pi / 8

    /// The slot under `offset`, measured from the ring's centre in view space
    /// (y-down: +x right, +y down). Nil inside the dead zone and outside the
    /// outer edge.
    static func slot(atOffset offset: CGPoint) -> RingSlot? {
        let distance = (offset.x * offset.x + offset.y * offset.y).squareRoot()
        guard distance >= deadZone, distance < outerRadius else { return nil }
        guard distance >= hubRadius else { return .hub }

        // atan2(dx, -dy) with y-down puts 0 at 12 o'clock and grows through 3,
        // 6 then 9 o'clock — the order the slots are declared in.
        var angle = atan2(offset.x, -offset.y)
        if angle < 0 { angle += 2 * .pi }

        // Half-open sectors, each centred on its compass direction: shifting by
        // a half sector and flooring means a boundary always lands in the
        // clockwise-later sector. Two neighbours can never both claim a point,
        // and none can drop one.
        let index = Int(((angle + sectorWidth / 2) / sectorWidth).rounded(.down))
        return compass[index % compass.count]
    }

    /// The clockwise-from-top angle of a compass slot's centre, or nil for the
    /// hub. Everything drawn takes its bearing from here, so a wedge cannot be
    /// painted somewhere `slot(atOffset:)` disagrees with.
    static func centerAngle(of slot: RingSlot) -> CGFloat? {
        compass.firstIndex(of: slot).map { CGFloat($0) * sectorWidth }
    }

    // MARK: - Drawn shapes

    /// Drawn radii, all derived from the hit-test radii above so the two cannot
    /// drift apart. The `itemGap` either side of `hubRadius` is the moat between
    /// the hub and the band; the hit test hands that moat to whichever side the
    /// pointer is nearer, so there is no sliver of ring where nothing selects.
    /// The 6pt inside `outerRadius` leaves the rim a margin of bare glass.
    static let hubDiscRadius = hubRadius - Theme.itemGap
    static let bandInner = hubRadius + Theme.itemGap
    static let bandOuter = outerRadius - 6
    static let rimRadius = outerRadius - 1
    static var labelRadius: CGFloat { (bandInner + bandOuter) / 2 }

    /// ~0.8° trimmed from each side of a wedge. A constant angle rather than a
    /// constant arc: the hairline gaps splay outward, which is what radial gaps
    /// do, and the wedge sides stay truly radial.
    static let wedgeTrim: CGFloat = 0.014

    /// Every shape below is in a **y-up** space centred on `center` — the space
    /// a non-flipped `NSView`'s layer tree uses, and the one place the y-down
    /// bearings get converted. Kept here with the hit test, not in the view, so
    /// a mirrored or quarter-turned ring fails a test instead of shipping.
    ///
    /// One annular wedge for a compass slot; nil for the hub, which is a disc.
    static func wedgePath(for slot: RingSlot, center: CGPoint) -> CGPath? {
        guard let bearing = centerAngle(of: slot) else { return nil }
        let half = sectorWidth / 2 - wedgeTrim
        // Clockwise-from-top → y-up maths angles (counterclockwise from
        // 3 o'clock): 12 o'clock is π/2, and going clockwise runs the angle down.
        let trailing = CGFloat.pi / 2 - bearing - half
        let leading = CGFloat.pi / 2 - bearing + half

        let path = CGMutablePath()
        path.addArc(
            center: center, radius: bandOuter,
            startAngle: leading, endAngle: trailing, clockwise: true)
        path.addArc(
            center: center, radius: bandInner,
            startAngle: trailing, endAngle: leading, clockwise: false)
        path.closeSubpath()
        return path
    }

    static func hubPath(center: CGPoint) -> CGPath {
        circlePath(center: center, radius: hubDiscRadius)
    }

    static func rimPath(center: CGPoint) -> CGPath {
        circlePath(center: center, radius: rimRadius)
    }

    /// Mid-band on the slot's own bearing; the hub's label sits in the middle.
    static func labelPoint(for slot: RingSlot, center: CGPoint) -> CGPoint {
        guard let bearing = centerAngle(of: slot) else { return center }
        // Clockwise from the top in a y-up space is (sin θ, cos θ).
        return CGPoint(
            x: center.x + labelRadius * sin(bearing),
            y: center.y + labelRadius * cos(bearing))
    }

    private static func circlePath(center: CGPoint, radius: CGFloat) -> CGPath {
        CGPath(
            ellipseIn: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2),
            transform: nil)
    }
}

/// What a slot reads as on the ring.
///
/// A snap borrows the zone's own name, so the ring and the settings list cannot
/// word the same zone differently. Nil — a slot the user cleared — is empty
/// text: the segment is still drawn, just quiet and unlabelled, so an unbound
/// slot reads as deliberately empty rather than as a broken wedge.
enum RingLabel {
    static func text(for action: WindowAction?) -> String {
        switch action {
        case .snap(let zone): zone.name
        case .center: "Center"
        case .restore: "Restore"
        case .minimize: "Minimize"
        case .fullScreen: "Full Screen"
        case .close: "Close"
        case .quitApp: "Quit App"
        case nil: ""
        }
    }
}

/// The radial ring: a frosted disc under the pointer with eight labelled
/// segments around a hub.
///
/// **Coordinate space.** Every point in and out of this type is an AppKit global
/// screen coordinate — y-up, the space `NSEvent.mouseLocation` reports in — so
/// the trigger can hand pointer positions straight through without converting.
///
/// **Pure AppKit on purpose.** A small borderless panel hosting a SwiftUI view
/// with a material can enter a constraint-invalidation runaway on macOS 26 (see
/// `ColorToast`, which is the same shape and cites the crash). This is an
/// `NSVisualEffectView` with an explicit frame and a `CAShapeLayer`/`CATextLayer`
/// tree — no view graph, no `updateConstraints`, and no `layout()` override, so
/// none of the re-entrant-layout family applies either.
@MainActor
final class RingOverlayWindow {
    private var panel: NSPanel?
    private var view: RingOverlayView?

    /// Where the ring is centred, in screen coordinates. Set by `show`, and the
    /// only thing `slot(at:)` measures from — nil while hidden, so a stray
    /// pointer report after the ring closes selects nothing.
    private var center: CGPoint?

    /// Ease-out, both under the 150ms the app allows itself for feedback: the
    /// ring has to be readable before the user has finished flicking.
    private static let appearDuration: CFTimeInterval = 0.12

    /// Opens the ring centred on `point`.
    ///
    /// Rebuilt per press rather than cached, which costs ~17 layers and buys two
    /// things: the labels re-read `WindowSettings` every time, so a rebind
    /// applies with no relaunch, and there is no reused window to leave stale
    /// state behind.
    func show(at point: CGPoint) {
        hide()

        let side = RingGeometry.side
        let view = RingOverlayView(frame: NSRect(x: 0, y: 0, width: side, height: side))

        let panel = NSPanel(
            contentRect: view.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The trigger owns the pointer; the ring is a read-only overlay that
        // must never take a click or key focus away from the window being
        // moved. Borderless + non-activating already refuses key status.
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        // Centred on the pointer and deliberately *not* clamped to the screen.
        // The ring is aimed by direction from where the pointer already is, so
        // nudging the disc inward near an edge would put its centre somewhere
        // the pointer is not — and the ring would open with a sector already
        // selected. Near an edge a wedge or two falls off-screen; the aim, and
        // the muscle memory, still work. The centre is on the pointer's screen
        // by construction, which is the display the ring belongs on.
        panel.setFrameOrigin(NSPoint(x: point.x - side / 2, y: point.y - side / 2))
        center = point

        // Content last: positioned and attached first means the labels resolve
        // against the panel's appearance and rasterise at the backing scale of
        // the display they are about to appear on, not the main one's.
        panel.contentView = view
        view.apply(labels: Self.labels())

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()  // the disc is clipped to a circle, not the frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.appearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        view.playAppearance(duration: Self.appearDuration)

        self.panel = panel
        self.view = view
    }

    /// Lights one slot, or nothing for nil.
    func highlight(_ slot: RingSlot?) {
        view?.highlight(slot)
    }

    /// Closes immediately, with no fade: on a commit the window itself is the
    /// feedback and the ring should be out of the way to show it, and there is
    /// no outgoing animation left to race a ring re-opened a moment later.
    func hide() {
        panel?.orderOut(nil)
        panel = nil
        view = nil
        center = nil
    }

    /// The slot under a screen point, or nil for the dead zone / outside.
    func slot(at point: CGPoint) -> RingSlot? {
        guard let center else { return nil }
        // Screen space is y-up and the geometry is y-down: this is the one place
        // dy is flipped.
        return RingGeometry.slot(atOffset: CGPoint(x: point.x - center.x, y: center.y - point.y))
    }

    /// The live slot → label map. An unbound slot maps to empty text.
    private static func labels() -> [RingSlot: String] {
        RingSlot.allCases.reduce(into: [:]) { result, slot in
            result[slot] = RingLabel.text(for: WindowSettings.action(for: slot))
        }
    }
}
