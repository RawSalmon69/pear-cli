import SwiftUI

// Sunburst layout + rendering.
//
// Geometry adapted from Radix (MIT), https://github.com/colinvkim/Radix
// (SunburstGeometry.swift): concentric rings from an inner hole outward, each
// child's arc proportional to its size, tiny slices folded into a "smaller
// items" wedge, plus the ring/binary-search hit test. Reworked to walk our
// value `DiskNode` tree directly and to drop Radix's color-token and
// free-space machinery — coloring here is ours (DiskChartPalette).

/// One wedge in the sunburst. Radii are normalized (0…1) against the chart's
/// half-extent; the renderer scales them to points.
struct SunburstSegment: Identifiable, Hashable, Sendable {
    let id: String
    /// The node's path, or nil for a folded "smaller items" wedge.
    let path: String?
    let label: String
    let startAngle: Angle
    let endAngle: Angle
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let depth: Int
    /// Index of the top-level ancestor → hue family.
    let branchIndex: Int
    let branchCount: Int
    let size: Int64
    let isDirectory: Bool
    /// Share of the whole chart, for warn escalation.
    let fraction: Double

    var isAggregate: Bool { path == nil }
    var isDrillable: Bool { isDirectory && path != nil }
}

enum SunburstLayout {
    /// Radius (normalized) of the empty center hole.
    static let centerRadius: CGFloat = 0.24

    /// Builds the wedges for `root`'s subtree down to `depthLimit` rings.
    /// `minimumAngle` (radians) is the smallest arc drawn before children fold
    /// into a single "smaller items" wedge.
    static func segments(
        root: DiskNode,
        depthLimit: Int,
        minimumAngle: Double = .pi / 90
    ) -> [SunburstSegment] {
        guard depthLimit > 0 else { return [] }
        let topChildren = root.children.isEmpty ? [root] : root.children
        let ringStart = centerRadius
        let ringWidth = (0.98 - ringStart) / CGFloat(max(depthLimit, 1))
        let wholeTotal = max(Double(root.size), 1)

        var segments: [SunburstSegment] = []
        appendSegments(
            children: topChildren,
            startAngle: 0,
            endAngle: 2 * .pi,
            depth: 0,
            depthLimit: depthLimit,
            ringStart: ringStart,
            ringWidth: ringWidth,
            branchIndex: nil,
            branchCount: max(topChildren.count, 1),
            wholeTotal: wholeTotal,
            minimumAngle: minimumAngle,
            into: &segments
        )
        return segments
    }

    private static func appendSegments(
        children: [DiskNode],
        startAngle: Double,
        endAngle: Double,
        depth: Int,
        depthLimit: Int,
        ringStart: CGFloat,
        ringWidth: CGFloat,
        branchIndex: Int?,
        branchCount: Int,
        wholeTotal: Double,
        minimumAngle: Double,
        into segments: inout [SunburstSegment]
    ) {
        guard depth < depthLimit else { return }

        let totalAngle = endAngle - startAngle
        // Fill the parent's arc exactly by dividing over the children's own sum.
        let denominator = max(children.reduce(0.0) { $0 + Double(max($1.size, 1)) }, 1)
        let grouped = groupedChildren(
            children,
            denominator: denominator,
            totalAngle: totalAngle,
            minimumAngle: minimumAngle
        )

        var cursor = startAngle
        for (index, entry) in grouped.enumerated() {
            let proportion = Double(entry.size) / denominator
            let segmentEnd = cursor + totalAngle * proportion
            // Top-level wedges seed a hue family; descendants inherit it.
            let branch = branchIndex ?? index

            segments.append(SunburstSegment(
                id: entry.id,
                path: entry.node?.id,
                label: entry.label,
                startAngle: .radians(cursor),
                endAngle: .radians(segmentEnd),
                innerRadius: ringStart + CGFloat(depth) * ringWidth,
                outerRadius: ringStart + CGFloat(depth + 1) * ringWidth - 0.006,
                depth: depth,
                branchIndex: branch,
                branchCount: branchCount,
                size: entry.size,
                isDirectory: entry.node?.isDirectory ?? false,
                fraction: Double(entry.size) / wholeTotal
            ))

            if let node = entry.node,
               node.isDirectory,
               node.hasChildren,
               node.size > 0,
               depth + 1 < depthLimit {
                appendSegments(
                    children: node.children,
                    startAngle: cursor,
                    endAngle: segmentEnd,
                    depth: depth + 1,
                    depthLimit: depthLimit,
                    ringStart: ringStart,
                    ringWidth: ringWidth,
                    branchIndex: branch,
                    branchCount: branchCount,
                    wholeTotal: wholeTotal,
                    minimumAngle: minimumAngle,
                    into: &segments
                )
            }

            cursor = segmentEnd
        }
    }

    private struct GroupEntry {
        let id: String
        let label: String
        let size: Int64
        let node: DiskNode?
    }

    private static func groupedChildren(
        _ children: [DiskNode],
        denominator: Double,
        totalAngle: Double,
        minimumAngle: Double
    ) -> [GroupEntry] {
        guard children.count > 1 else {
            return children.map { GroupEntry(id: $0.id, label: $0.name, size: max($0.size, 1), node: $0) }
        }

        var visible: [GroupEntry] = []
        var groupedSize: Int64 = 0
        var groupedCount = 0
        var lastGrouped: DiskNode?

        for child in children {
            let size = max(child.size, 1)
            let angle = totalAngle * (Double(size) / denominator)
            if angle < minimumAngle {
                groupedSize = groupedSize.addingReportingOverflow(size).partialValue
                groupedCount += 1
                lastGrouped = child
            } else {
                visible.append(GroupEntry(id: child.id, label: child.name, size: size, node: child))
            }
        }

        if groupedCount > 1 {
            let anchor = children.first?.id ?? "root"
            visible.append(GroupEntry(
                id: "sunburst-more:\(anchor)",
                label: "\(groupedCount) smaller items",
                size: groupedSize,
                node: nil
            ))
        } else if let only = lastGrouped {
            visible.append(GroupEntry(id: only.id, label: only.name, size: max(only.size, 1), node: only))
        }

        return visible
    }
}

/// Turns a normalized wedge into a drawable `Path` for a given canvas size.
enum SunburstRenderer {
    static func path(for segment: SunburstSegment, in size: CGSize) -> Path {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) / 2
        let innerRadius = maxRadius * segment.innerRadius
        let outerRadius = maxRadius * segment.outerRadius

        // Rotate so 0 rad points up (12 o'clock).
        let start = segment.startAngle.radians - (.pi / 2)
        let end = segment.endAngle.radians - (.pi / 2)

        var path = Path()
        path.addArc(center: center, radius: outerRadius,
                    startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        path.addArc(center: center, radius: innerRadius,
                    startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// Ring-bucketed hit test: pick the ring by radius, then binary-search the arc.
/// Adapted from Radix's SunburstHitTestIndex.
struct SunburstHitTestIndex: Sendable {
    private let rings: [Ring]

    init(segments: [SunburstSegment]) {
        var byDepth: [Int: [SunburstSegment]] = [:]
        for segment in segments { byDepth[segment.depth, default: []].append(segment) }
        rings = byDepth
            .map { Ring(segments: $0.value) }
            .sorted { $0.minInnerRadius < $1.minInnerRadius }
    }

    func segment(at point: CGPoint, in size: CGSize) -> SunburstSegment? {
        guard !rings.isEmpty else { return nil }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) / 2
        guard maxRadius > 0 else { return nil }

        let dx = point.x - center.x
        let dy = point.y - center.y
        let normalized = sqrt(dx * dx + dy * dy) / maxRadius
        guard let ring = rings.first(where: { $0.contains(normalized) }) else { return nil }

        var radians = atan2(dy, dx) + (.pi / 2)
        if radians < 0 { radians += 2 * .pi }
        return ring.segment(containing: radians)
    }

    /// True when the point is inside the empty center hole (used for "go up").
    static func isCenter(_ point: CGPoint, in size: CGSize, radius: CGFloat = SunburstLayout.centerRadius) -> Bool {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) / 2
        guard maxRadius > 0 else { return false }
        let dx = point.x - center.x
        let dy = point.y - center.y
        return (sqrt(dx * dx + dy * dy) / maxRadius) < radius
    }

    private struct Ring: Sendable {
        let minInnerRadius: CGFloat
        let maxOuterRadius: CGFloat
        let segments: [SunburstSegment]

        init(segments: [SunburstSegment]) {
            self.segments = segments.sorted { $0.startAngle.radians < $1.startAngle.radians }
            var minInner = CGFloat.greatestFiniteMagnitude
            var maxOuter: CGFloat = 0
            for segment in segments {
                minInner = min(minInner, segment.innerRadius)
                maxOuter = max(maxOuter, segment.outerRadius)
            }
            minInnerRadius = minInner == .greatestFiniteMagnitude ? 0 : minInner
            maxOuterRadius = maxOuter
        }

        func contains(_ normalized: CGFloat) -> Bool {
            normalized >= minInnerRadius && normalized <= maxOuterRadius
        }

        func segment(containing radians: Double) -> SunburstSegment? {
            guard !segments.isEmpty else { return nil }
            var lower = 0
            var upper = segments.count
            while lower < upper {
                let mid = lower + (upper - lower) / 2
                if segments[mid].startAngle.radians <= radians { lower = mid + 1 } else { upper = mid }
            }
            let candidate = segments[max(lower - 1, 0)]
            guard radians >= candidate.startAngle.radians, radians <= candidate.endAngle.radians else { return nil }
            return candidate
        }
    }
}

// MARK: - View

/// Theme-skinned sunburst. Hover highlights a wedge and reports it upward; a
/// click on a directory wedge drills in; a click in the center hole goes up.
/// Pinch or ⌘/⌥-scroll zooms the ring (1×–4×); scroll or drag pans once zoomed.
/// All pointer input is routed through `SunburstInteractionOverlay` so the
/// scroll-wheel and pinch gestures AppKit provides are available; the vendored
/// `SunburstViewportTransform` maps container points into the scaled canvas.
struct SunburstChartView: View {
    let root: DiskNode
    let depthLimit: Int
    /// Paths staged for deletion; their wedges render dimmed with a dashed warn
    /// outline so the pending pile is visible in the chart.
    let stagedPaths: Set<String>
    let onHover: (DiskChartHover?) -> Void
    let onDrill: (DiskNode) -> Void
    let onGoUp: () -> Void

    @State private var hoveredID: String?
    @State private var viewport = SunburstViewportTransform.identity

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let baseFrame = CGRect(origin: .zero, size: size)
            let frame = viewport.frame(for: baseFrame)
            let segments = SunburstLayout.segments(root: root, depthLimit: depthLimit)
            let index = SunburstHitTestIndex(segments: segments)

            Canvas { context, canvasSize in
                for segment in segments {
                    let path = SunburstRenderer.path(for: segment, in: canvasSize)
                    let color = DiskChartPalette.color(
                        depth: segment.depth,
                        branchIndex: segment.branchIndex,
                        branchCount: segment.branchCount,
                        fraction: segment.fraction,
                        isAggregate: segment.isAggregate
                    )
                    let isHovered = segment.id == hoveredID
                    let isStaged = segment.path.map(stagedPaths.contains) ?? false
                    context.fill(path, with: .color(color.opacity(isStaged ? 0.22 : (isHovered ? 1 : 0.9))))
                    context.stroke(path, with: .color(.black.opacity(0.18)), lineWidth: 0.5)
                    if isStaged {
                        context.stroke(path, with: .color(Theme.warn.opacity(0.9)),
                                       style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    } else if isHovered {
                        context.stroke(path, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
                    }
                }
            }
            .frame(width: frame.width, height: frame.height)
            .overlay { centerLabel }
            .position(x: frame.midX, y: frame.midY)
            .clipped()
            .contentShape(Rectangle())
            .overlay {
                SunburstInteractionOverlay(
                    onHover: { updateHover($0, index: index, baseFrame: baseFrame) },
                    onClick: { handleClick($0, index: index, baseFrame: baseFrame) },
                    onPan: { viewport = viewport.panned(by: $0, in: baseFrame) },
                    onMagnify: { location, factor in
                        viewport = viewport.zoomed(by: factor, anchor: location, in: baseFrame)
                    },
                    canStartPan: { canStartPan($0, index: index, baseFrame: baseFrame) },
                    isPanEnabled: viewport.isZoomed
                )
            }
            .onChange(of: size) { _, newSize in
                viewport = viewport.constrained(to: CGRect(origin: .zero, size: newSize))
            }
            .onChange(of: root.id) { _, _ in
                // A new subtree is a new chart — drop any zoom and stale hover.
                viewport = .identity
                hoveredID = nil
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func updateHover(_ location: CGPoint?, index: SunburstHitTestIndex, baseFrame: CGRect) {
        guard let location,
              let chart = viewport.localChartPoint(for: location, in: baseFrame) else {
            hoveredID = nil
            onHover(nil)
            return
        }
        let hit = index.segment(at: chart.point, in: chart.size)
        hoveredID = hit?.id
        onHover(hit.map { DiskChartHover(name: $0.label, size: $0.size, path: $0.path) })
    }

    private func handleClick(_ location: CGPoint, index: SunburstHitTestIndex, baseFrame: CGRect) {
        guard let chart = viewport.localChartPoint(for: location, in: baseFrame) else { return }
        if SunburstHitTestIndex.isCenter(chart.point, in: chart.size) {
            onGoUp()
            return
        }
        guard let hit = index.segment(at: chart.point, in: chart.size),
              hit.isDrillable,
              let node = root.firstDescendant(id: hit.path ?? "") else { return }
        onDrill(node)
    }

    /// Pan starts only on empty space (outside any wedge and off-center), so a
    /// drag over a wedge still reads as hover/click rather than a pan.
    private func canStartPan(_ location: CGPoint, index: SunburstHitTestIndex, baseFrame: CGRect) -> Bool {
        guard let chart = viewport.localChartPoint(for: location, in: baseFrame) else { return true }
        if SunburstHitTestIndex.isCenter(chart.point, in: chart.size) { return false }
        return index.segment(at: chart.point, in: chart.size) == nil
    }

    private var centerLabel: some View {
        VStack(spacing: 1) {
            Text(root.name)
                .font(Theme.rounded(11, .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(ByteFormat.si(root.size))
                .font(Theme.rounded(13, .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: 110)
        .allowsHitTesting(false)
    }
}
