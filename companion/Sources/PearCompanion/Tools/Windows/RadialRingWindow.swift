// Adapted from Loop (GPL-3.0), https://github.com/MrKai77/Loop
//
// Loop draws its radial menu as a small borderless panel at the point the
// trigger was pressed: a material annulus whose direction selector highlights
// the active sector, filling wholesale for center-ish actions
// (`RadialMenuView` + `RadialMenuViewModel.shouldFillRadialMenu`). We keep
// that shape — material ring, evenly-spaced sectors, center disc — but draw
// with plain SwiftUI shapes and the app's Theme instead of Loop's Luminare
// styling, and drive it from a tiny ObservableObject instead of Loop's
// ResizeContext.

import AppKit
import SwiftUI

/// Owns the cursor-anchored ring panel. Non-activating and click-through:
/// the ring is pure feedback — all input arrives via RadialTrigger's
/// monitors, never through this window.
@MainActor
final class RadialRingController {
    /// Ring diameter (Loop's is 100 pt; ours is roomier per the design brief).
    static let ringDiameter: CGFloat = 180
    /// Panel margin around the ring so the SwiftUI shadow isn't clipped.
    private static let margin: CGFloat = 20
    private static var side: CGFloat { ringDiameter + margin * 2 }

    private var panel: NSPanel?
    private let model = RadialRingModel()

    /// Shows the ring centered on `point` (global AppKit coords), nudged
    /// fully on-screen near edges, with a quick pop-in.
    func show(at point: NSPoint) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        model.selection = nil
        model.visible = false

        var origin = NSPoint(x: point.x - Self.side / 2, y: point.y - Self.side / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            origin.x = min(max(origin.x, screen.frame.minX), screen.frame.maxX - Self.side)
            origin.y = min(max(origin.y, screen.frame.minY), screen.frame.maxY - Self.side)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()

        // Defer one tick so the first frame renders hidden, then pops in.
        Task { @MainActor [model] in
            withAnimation(.easeOut(duration: 0.12)) { model.visible = true }
        }
    }

    func highlight(_ zone: WindowZone?) {
        model.selection = zone
    }

    /// Instant hide — release should feel immediate, so no exit animation.
    func hide() {
        panel?.orderOut(nil)
        model.selection = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver // one above the zone preview
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the view draws its own soft shadow
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: RadialRingView(model: model))
        return panel
    }
}

/// Ring state, separated from the view so the controller can mutate it
/// without rebuilding the hosting view (Loop's ViewModel split).
@MainActor
final class RadialRingModel: ObservableObject {
    @Published var selection: WindowZone?
    @Published var visible = false
}

/// The ring itself: a material annulus of 8 sectors around a center disc.
/// Materials match `.glassCard()`'s pre-26 fallback (`.ultraThinMaterial`);
/// the active sector fills with Theme.accent, `.center` lights the disc, and
/// `.maximize` floods the whole ring (Loop's `shouldFillRadialMenu`).
struct RadialRingView: View {
    @ObservedObject var model: RadialRingModel

    private let outerRadius: CGFloat = RadialRingController.ringDiameter / 2
    private let innerRadius: CGFloat = 58
    private let centerRadius: CGFloat = 24

    var body: some View {
        ZStack {
            // Material annulus.
            Circle()
                .strokeBorder(.ultraThinMaterial, lineWidth: outerRadius - innerRadius)

            // Active sector.
            if let index = model.selection?.radialSectorIndex {
                RingSectorShape(
                    sectorIndex: index,
                    innerRadius: innerRadius,
                    outerRadius: outerRadius
                )
                .fill(Theme.accent.opacity(0.85))
            }

            // Maximize floods the ring.
            if model.selection == .maximize {
                Circle().fill(Theme.accent.opacity(0.35))
            }

            sectorSeparators
            rimStrokes
            centerDisc
        }
        .frame(width: outerRadius * 2, height: outerRadius * 2)
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 10)
        .scaleEffect(model.visible ? 1 : 0.85)
        .opacity(model.visible ? 1 : 0)
        .animation(.easeOut(duration: 0.1), value: model.selection)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Hairlines between sectors, at the boundary angles (compass point
    /// ± 22.5°). View space is y-down, so visual angle = −(y-up angle).
    private var sectorSeparators: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let span = 360.0 / Double(WindowZone.radialSectorCount)
            for index in 0 ..< WindowZone.radialSectorCount {
                let radians = -(Double(index) + 0.5) * span * .pi / 180
                var line = Path()
                line.move(to: CGPoint(
                    x: center.x + innerRadius * cos(radians),
                    y: center.y + innerRadius * sin(radians)
                ))
                line.addLine(to: CGPoint(
                    x: center.x + outerRadius * cos(radians),
                    y: center.y + outerRadius * sin(radians)
                ))
                context.stroke(line, with: .color(.primary.opacity(0.12)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    private var rimStrokes: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                .frame(width: innerRadius * 2, height: innerRadius * 2)
        }
    }

    /// The center disc: the `.center` target, and the tap target for the
    /// center-click → maximize shortcut. Its glyph mirrors the selection.
    private var centerDisc: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            if model.selection == .center {
                Circle().fill(Theme.accent.opacity(0.85))
            }
            Image(systemName: model.selection == .maximize
                ? "arrow.up.left.and.arrow.down.right"
                : "rectangle.center.inset.filled")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.selection == .center ? Color.white : Color.secondary)
        }
        .frame(width: centerRadius * 2, height: centerRadius * 2)
    }
}

/// One annular 45° wedge. Sector centers are y-up compass angles
/// (index × 45°, 0 = East); the view's y axis points down, so the visual
/// angle is negated. `clockwise:` follows CGPath semantics (sweep direction
/// in unflipped space), which with `end = start + 45°` always takes the
/// short 45° arc regardless of the view flip.
private struct RingSectorShape: Shape {
    let sectorIndex: Int
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let span = 360.0 / Double(WindowZone.radialSectorCount)
        let mid = -Double(sectorIndex) * span
        let start = Angle.degrees(mid - span / 2)
        let end = Angle.degrees(mid + span / 2)

        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}
