import AppKit
import QuartzCore
import SwiftUI

/// The ring itself: a frosted disc, eight annular wedges around a hub, and one
/// text layer per bound slot.
///
/// Everything is a layer with an explicit frame — no SwiftUI, no Auto Layout, no
/// `layout()` override. The panel is created at a fixed size and never resized,
/// so there is no layout pass to gate work on and nothing that could resize a
/// window mid-layout; both of the app's re-entrant-layout hazards are absent by
/// construction rather than by care.
///
/// The glass is this view; the marks live in one layer-backed subview on top of
/// it. `NSVisualEffectView` owns its own backdrop layers, so a sublayer added
/// straight to it can end up behind the blur — the same "effect view as
/// container, layer-backed subviews on top" shape `ColorToast` uses.
@MainActor
final class RingOverlayView: NSVisualEffectView {
    /// Wide enough for "Bottom Right" on one line inside a wedge, narrow enough
    /// that "Left Two Thirds" stacks instead of spilling into its neighbour.
    private static let labelWidth: CGFloat = 72
    private static let crossfade: CFTimeInterval = 0.09

    /// `Theme.caption` — 11pt semibold rounded — reached through AppKit, since
    /// there is no SwiftUI here to hand a `Font` to.
    private static let labelFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 11, weight: .semibold)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: 11) ?? base
    }()

    /// Black or white on a lit segment, whichever WCAG prefers. The seven accent
    /// presets run from pale olive to graphite, so a fixed white label would
    /// disappear on half of them.
    private static var onAccent: NSColor {
        guard let accent = PickedColor(sampled: NSColor(Theme.accent)) else { return .white }
        return accent.contrast(against: .black).ratio >= accent.contrast(against: .white).ratio
            ? .black : .white
    }

    private let marks = NSView()
    /// Wraps the marks so the appearance animation scales about the centre — a
    /// view's own backing layer is anchored at its corner in AppKit.
    private let ring = CALayer()
    private var wedges: [RingSlot: CAShapeLayer] = [:]
    private var labelLayers: [RingSlot: CATextLayer] = [:]
    /// Slots with an action on them. The rest are drawn quiet and unlabelled.
    private var bound: Set<RingSlot> = []
    private var highlighted: RingSlot?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        // The panel's backing is a square and the ring is a disc: clipping the
        // glass to the circle is what stops a 1px rectangular ghost border
        // leaking past the rounded edge. Same `clipToCard` idiom every
        // borderless panel here uses, at the radius that makes it a full circle.
        clipToCard(radius: frameRect.width / 2)

        marks.frame = bounds
        marks.wantsLayer = true
        addSubview(marks)

        ring.frame = bounds  // anchorPoint stays (0.5, 0.5)
        marks.layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Content

    /// Builds the ring for one press. `labels` is slot → text, empty for a slot
    /// the user cleared.
    func apply(labels: [RingSlot: String]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // the appearance is the only motion on show

        ring.sublayers?.forEach { $0.removeFromSuperlayer() }
        wedges.removeAll()
        labelLayers.removeAll()
        bound = Set(labels.filter { !$0.value.isEmpty }.keys)
        highlighted = nil

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.addSublayer(rimLayer(center))

        // Wedges first, then every label, so a label can never be buried under
        // a neighbouring wedge.
        for slot in RingSlot.allCases {
            let wedge = CAShapeLayer()
            wedge.path = slot == .hub
                ? RingGeometry.hubPath(center: center)
                : RingGeometry.wedgePath(for: slot, center: center)
            wedge.fillColor = fill(for: slot)
            ring.addSublayer(wedge)
            wedges[slot] = wedge
        }
        for slot in RingSlot.allCases where bound.contains(slot) {
            guard let string = labels[slot] else { continue }
            let label = labelLayer(string, at: RingGeometry.labelPoint(for: slot, center: center))
            label.foregroundColor = ink(for: slot)
            ring.addSublayer(label)
            labelLayers[slot] = label
        }

        CATransaction.commit()
        applyBackingScale()
    }

    /// Lights one slot and dims the rest, crossfading in 90ms.
    func highlight(_ slot: RingSlot?) {
        // The trigger reports the slot under the pointer on every move; only a
        // change is worth animating.
        guard slot != highlighted else { return }
        highlighted = slot

        CATransaction.begin()
        CATransaction.setDisableActions(false)
        CATransaction.setAnimationDuration(Self.crossfade)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for (key, wedge) in wedges { wedge.fillColor = fill(for: key) }
        for (key, label) in labelLayers { label.foregroundColor = ink(for: key) }
        CATransaction.commit()
    }

    /// The marks settle from 96% as the panel fades in — one ease-out, no
    /// spring, done before the user has finished flicking.
    func playAppearance(duration: CFTimeInterval) {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.96
        scale.toValue = 1
        scale.duration = duration
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(scale, forKey: "appear")
    }

    /// Text layers rasterise at whatever `contentsScale` they hold, so an unset
    /// one is visibly soft on a Retina display.
    func applyBackingScale() {
        let scale = window?.backingScaleFactor ?? 2
        for label in labelLayers.values { label.contentsScale = scale }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale()
    }

    // MARK: - Layers

    /// A hairline at the outer edge so the disc reads against a busy desktop.
    private func rimLayer(_ center: CGPoint) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = RingGeometry.rimPath(center: center)
        layer.fillColor = nil
        layer.strokeColor = resolved(NSColor.labelColor.withAlphaComponent(0.10))
        layer.lineWidth = 1
        return layer
    }

    private func labelLayer(_ string: String, at point: CGPoint) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = string
        layer.font = Self.labelFont
        layer.fontSize = Self.labelFont.pointSize
        layer.alignmentMode = .center
        layer.isWrapped = true  // "Bottom Right" stacks rather than truncating
        layer.truncationMode = .end

        // A text layer fills its box downward from the top, so the box is sized
        // to the wrapped text and then centred on the label point.
        let height = (string as NSString).boundingRect(
            with: CGSize(width: Self.labelWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: Self.labelFont]
        ).height.rounded(.up)
        layer.frame = CGRect(
            x: point.x - Self.labelWidth / 2, y: point.y - height / 2,
            width: Self.labelWidth, height: height)
        return layer
    }

    // MARK: - Colour

    /// A bound segment carries the accent and takes it solid when lit. An
    /// unbound one is a faint neutral instead: clearly part of the ring, clearly
    /// empty, which is not the same as broken.
    private func fill(for slot: RingSlot) -> CGColor {
        let lit = slot == highlighted
        guard bound.contains(slot) else {
            return resolved(NSColor.labelColor.withAlphaComponent(lit ? 0.14 : 0.06))
        }
        return resolved(NSColor(lit ? Theme.accent : Theme.accentSoft))
    }

    private func ink(for slot: RingSlot) -> CGColor {
        resolved(slot == highlighted ? Self.onAccent : .labelColor)
    }

    /// Dynamic colours resolve against whatever appearance is current when
    /// `.cgColor` is read, and a layer keeps the `CGColor` it was handed. Read
    /// them against this view's appearance so a dark-mode ring gets dark-mode
    /// ink; the ring is rebuilt per press, so there is nothing to re-resolve.
    private func resolved(_ color: NSColor) -> CGColor {
        var cg = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        return cg
    }
}
