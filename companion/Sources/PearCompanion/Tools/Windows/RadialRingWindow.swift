// Adapted from Loop (GPL-3.0), https://github.com/MrKai77/Loop, commit 3b632db5
// Original files: Loop/Window Action Indicators/Radial Menu/RadialMenuController.swift,
//                 Loop/Window Action Indicators/Radial Menu/RadialMenuViewModel.swift
//
// The ring is now drawn by Loop's `RadialMenuView` (see Vendor/). This file
// keeps Pear's window plumbing (a reused, click-through, non-activating panel
// centered on the cursor) and provides the thin viewmodel that seam: it maps a
// `WindowZone?` selection to the published surface `RadialMenuView` reads
// (angle, fill/hide flags, center image), replacing Loop's 90-case
// WindowAction-driven `RadialMenuViewModel`. The `show`/`highlight`/`hide`
// surface RadialTrigger calls is unchanged.

import AppKit
import SwiftUI

/// Owns the cursor-anchored ring panel. Non-activating and click-through:
/// the ring is pure feedback — all input arrives via RadialTrigger's
/// monitors, never through this window.
@MainActor
final class RadialRingController {
    /// Panel side: Loop's 100 pt ring plus its 40 pt padding on each edge
    /// (`RadialMenuView` is `.fixedSize()` at 180×180, leaving room for the
    /// soft shadow the view draws itself).
    private static let side: CGFloat = 180

    private var panel: NSPanel?
    private let model = RadialRingModel()

    /// Shows the ring centered on `point` (global AppKit coords), nudged
    /// fully on-screen near edges, with Loop's quick pop-in.
    func show(at point: NSPoint) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        model.reset()

        var origin = NSPoint(x: point.x - Self.side / 2, y: point.y - Self.side / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            origin.x = min(max(origin.x, screen.frame.minX), screen.frame.maxX - Self.side)
            origin.y = min(max(origin.y, screen.frame.minY), screen.frame.maxY - Self.side)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()

        // Defer one tick so the first frame renders hidden, then pops in.
        Task { @MainActor [model] in
            model.setShown(true)
        }
    }

    func highlight(_ zone: WindowZone?) {
        model.update(selection: zone)
    }

    /// Instant hide — release should feel immediate, so no exit animation.
    func hide() {
        panel?.orderOut(nil)
        model.reset()
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
        panel.contentView = NSHostingView(rootView: RadialMenuView(viewModel: model))
        return panel
    }
}

/// Ring state, separated from the view so the controller can mutate it without
/// rebuilding the hosting view. Exposes exactly the surface Loop's
/// `RadialMenuView` reads; `update(selection:)` is the seam that maps a
/// `WindowZone?` into that surface (Loop derives it from a `WindowAction`).
@MainActor
final class RadialRingModel: ObservableObject {
    /// View-space wedge angle in degrees (SwiftUI Path space: 0° = East,
    /// positive = clockwise). Animated along the shortest path between sectors.
    @Published private(set) var angle: Double = 0
    @Published private(set) var selection: WindowZone?
    @Published private(set) var isShown = false
    @Published private(set) var isShadowShown = false
    /// Fill the whole annulus (the maximize gesture), instead of one wedge.
    @Published private(set) var shouldFillRadialMenu = false
    /// Hide the direction wedge (no directional selection yet, or `.center`).
    @Published private(set) var shouldHideDirectionSelector = true
    /// The glyph shown at the ring's center, mirroring the pending action.
    @Published private(set) var radialMenuImage: Image?

    /// Ring pop-in, mirroring Loop's `setIsShown` (shadow trails the scale
    /// slightly). Honors the Instant speed by skipping the animation.
    func setShown(_ shown: Bool) {
        let speed = WindowSettings.animationSpeed()
        guard speed.animateRadialMenuAppearance else {
            isShown = shown
            isShadowShown = shown
            return
        }

        let duration = 0.1
        withAnimation(.smooth(duration: duration)) {
            isShown = shown
        }
        let shadowTrim = 0.05
        withAnimation(.smooth(duration: duration - shadowTrim).delay(shown ? shadowTrim : 0)) {
            isShadowShown = shown
        }
    }

    /// Map a `WindowZone?` selection into the ring's published surface. For a
    /// directional zone the wedge rotates (shortest path) to that sector; the
    /// maximize gesture fills the ring; everything else hides the wedge.
    func update(selection newSelection: WindowZone?) {
        guard selection != newSelection else { return }
        selection = newSelection

        switch newSelection {
        case .maximize:
            shouldFillRadialMenu = true
            shouldHideDirectionSelector = true
            radialMenuImage = Image(systemName: "arrow.up.left.and.arrow.down.right")
        case .center:
            shouldFillRadialMenu = false
            shouldHideDirectionSelector = true
            radialMenuImage = Image(systemName: "rectangle.center.inset.filled")
        case let .some(zone) where zone.radialSectorIndex != nil:
            shouldFillRadialMenu = false
            shouldHideDirectionSelector = false
            radialMenuImage = zone.ringSymbol.map { Image(systemName: $0) }
            rotate(toSectorIndex: zone.radialSectorIndex!)
        default:
            shouldFillRadialMenu = false
            shouldHideDirectionSelector = true
            radialMenuImage = nil
        }
    }

    /// Clear all selection state (on show/hide), keeping the wedge hidden.
    func reset() {
        selection = nil
        isShown = false
        isShadowShown = false
        shouldFillRadialMenu = false
        shouldHideDirectionSelector = true
        radialMenuImage = nil
    }

    /// Rotate the highlight to a sector. Our sector index is a y-up compass
    /// angle (index × 45°, 0 = East, counter-clockwise); SwiftUI Path space is
    /// y-down, so the view-space angle negates it. Takes the shortest path via
    /// Loop's `Angle.angleDifference`.
    private func rotate(toSectorIndex index: Int) {
        let target = Angle.degrees(-Double(index) * 360.0 / Double(WindowZone.radialSectorCount))
        let diff = Angle.degrees(angle).angleDifference(to: target)
        withAnimation(WindowSettings.animationSpeed().radialMenuAngle) {
            angle += diff.degrees
        }
    }
}
