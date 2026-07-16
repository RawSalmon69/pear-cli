import SwiftUI

// Treemap layout + rendering.
//
// Geometry adapted from Radix (MIT), https://github.com/colinvkim/Radix
// (TreemapGeometry.swift): the squarified treemap algorithm (Bruls–Huizing–van
// Wijk) — pack each row so tiles stay near-square by minimizing the worst
// aspect ratio — plus nested containers with a header strip, tiny tiles folded
// into a "smaller items" tile, and a bucketed hit test. Reworked to walk our
// value `DiskNode` tree and to use our palette instead of Radix's color tokens.

/// One tile in the treemap. `rect` is normalized (0…1) in both axes; the
/// renderer scales it to the current canvas.
struct TreemapSegment: Identifiable, Hashable, Sendable {
    let id: String
    let path: String?
    let label: String
    let rect: CGRect
    let depth: Int
    let branchIndex: Int
    let branchCount: Int
    let size: Int64
    let isDirectory: Bool
    let isAggregate: Bool
    /// Whether this tile hosts nested children beneath a header strip.
    let showsContainerHeader: Bool
    /// Share of the whole chart, for warn escalation.
    let fraction: Double

    var isDrillable: Bool { isDirectory && path != nil }
}

enum TreemapLayout {
    private static let containerInset: CGFloat = 2
    private static let containerHeaderHeight: CGFloat = 16
    private static let minimumContainerWidth: CGFloat = 56
    private static let minimumContainerHeight: CGFloat = 48

    /// Builds tiles for `root`'s subtree at the given pixel `size`, nesting down
    /// to `depthLimit`. `minimumTileArea` (points²) is the smallest tile drawn
    /// before children fold into a "smaller items" tile.
    static func segments(
        root: DiskNode,
        depthLimit: Int,
        size: CGSize,
        minimumTileArea: CGFloat = 160
    ) -> [TreemapSegment] {
        guard depthLimit > 0, size.width > 0, size.height > 0 else { return [] }
        let topChildren = root.children.isEmpty ? [root] : root.children
        let wholeTotal = max(Double(root.size), 1)

        var segments: [TreemapSegment] = []
        appendSegments(
            children: topChildren,
            bounds: CGRect(origin: .zero, size: size),
            rootSize: size,
            depth: 0,
            depthLimit: depthLimit,
            branchIndex: nil,
            branchCount: max(topChildren.count, 1),
            wholeTotal: wholeTotal,
            minimumTileArea: max(minimumTileArea, 1),
            into: &segments
        )
        return segments
    }

    private static func appendSegments(
        children: [DiskNode],
        bounds: CGRect,
        rootSize: CGSize,
        depth: Int,
        depthLimit: Int,
        branchIndex: Int?,
        branchCount: Int,
        wholeTotal: Double,
        minimumTileArea: CGFloat,
        into segments: inout [TreemapSegment]
    ) {
        guard depth < depthLimit, bounds.width > 0, bounds.height > 0 else { return }

        let entries = groupedChildren(children, bounds: bounds, minimumTileArea: minimumTileArea)
        let tiles = squarifiedTiles(for: entries, in: bounds)

        for (index, tile) in tiles.enumerated() {
            let entry = tile.entry
            let branch = branchIndex ?? index

            let childNodes: [DiskNode]
            if let node = entry.node, node.isDirectory, node.hasChildren, depth + 1 < depthLimit {
                childNodes = node.children
            } else {
                childNodes = []
            }
            let childBounds = childContentBounds(in: tile.rect)
            let showsHeader = !childNodes.isEmpty && childBounds != nil

            segments.append(TreemapSegment(
                id: entry.id,
                path: entry.node?.id,
                label: entry.label,
                rect: normalized(tile.rect, in: rootSize),
                depth: depth,
                branchIndex: branch,
                branchCount: branchCount,
                size: entry.size,
                isDirectory: entry.node?.isDirectory ?? false,
                isAggregate: entry.isAggregate,
                showsContainerHeader: showsHeader,
                fraction: Double(entry.size) / wholeTotal
            ))

            if !childNodes.isEmpty, let childBounds {
                appendSegments(
                    children: childNodes,
                    bounds: childBounds,
                    rootSize: rootSize,
                    depth: depth + 1,
                    depthLimit: depthLimit,
                    branchIndex: branch,
                    branchCount: branchCount,
                    wholeTotal: wholeTotal,
                    minimumTileArea: minimumTileArea,
                    into: &segments
                )
            }
        }
    }

    // MARK: Grouping

    private struct Entry {
        let id: String
        let label: String
        let size: Int64
        let isAggregate: Bool
        let node: DiskNode?

        init(node: DiskNode) {
            id = node.id
            label = node.name
            size = max(node.size, 0)
            isAggregate = false
            self.node = node
        }

        init(id: String, label: String, size: Int64) {
            self.id = id
            self.label = label
            self.size = max(size, 0)
            isAggregate = true
            node = nil
        }
    }

    private static func groupedChildren(
        _ children: [DiskNode],
        bounds: CGRect,
        minimumTileArea: CGFloat
    ) -> [Entry] {
        guard children.count > 1 else { return children.map(Entry.init(node:)) }

        let totalWeight = children.reduce(0.0) { $0 + Double(max($1.size, 1)) }
        let availableArea = max(bounds.width * bounds.height, 1)
        var visible: [Entry] = []
        var groupedSize: Int64 = 0
        var groupedCount = 0
        var lastGrouped: DiskNode?

        for child in children {
            let weight = Double(max(child.size, 1))
            let projectedArea = availableArea * CGFloat(weight / max(totalWeight, 1))
            if projectedArea < minimumTileArea {
                groupedSize = groupedSize.addingReportingOverflow(max(child.size, 0)).partialValue
                groupedCount += 1
                lastGrouped = child
            } else {
                visible.append(Entry(node: child))
            }
        }

        if groupedCount > 1 {
            let anchor = children.first?.id ?? "root"
            visible.append(Entry(
                id: "treemap-more:\(anchor)",
                label: "\(groupedCount) smaller items",
                size: groupedSize
            ))
        } else if let only = lastGrouped {
            visible.append(Entry(node: only))
        }

        return visible.sorted {
            $0.size == $1.size ? $0.id < $1.id : $0.size > $1.size
        }
    }

    // MARK: Squarify

    private struct WeightedEntry {
        let entry: Entry
        let area: CGFloat
    }

    private struct Tile {
        let entry: Entry
        let rect: CGRect
    }

    private static func squarifiedTiles(for entries: [Entry], in bounds: CGRect) -> [Tile] {
        guard !entries.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }

        let totalWeight = entries.reduce(0.0) { $0 + Double(max($1.size, 1)) }
        let scale = Double(bounds.width * bounds.height) / max(totalWeight, 1)
        let weighted = entries.map {
            WeightedEntry(entry: $0, area: CGFloat(Double(max($0.size, 1)) * scale))
        }

        var next = 0
        var remaining = bounds
        var row: [WeightedEntry] = []
        var result: [Tile] = []

        while next < weighted.count {
            let candidate = weighted[next]
            let shortSide = min(remaining.width, remaining.height)
            if row.isEmpty
                || worstAspectRatio(for: row + [candidate], shortSide: shortSide)
                    <= worstAspectRatio(for: row, shortSide: shortSide) {
                row.append(candidate)
                next += 1
            } else {
                remaining = layoutRow(row, in: remaining, into: &result)
                row.removeAll(keepingCapacity: true)
            }
        }
        if !row.isEmpty { _ = layoutRow(row, in: remaining, into: &result) }
        return result
    }

    private static func worstAspectRatio(for row: [WeightedEntry], shortSide: CGFloat) -> CGFloat {
        guard !row.isEmpty, shortSide > 0 else { return .infinity }
        let sum = row.reduce(CGFloat(0)) { $0 + $1.area }
        let maximum = row.reduce(CGFloat(0)) { max($0, $1.area) }
        let minimum = row.reduce(CGFloat.greatestFiniteMagnitude) { min($0, $1.area) }
        guard sum > 0, minimum > 0 else { return .infinity }
        let sumSquared = sum * sum
        let sideSquared = shortSide * shortSide
        return max((sideSquared * maximum) / sumSquared, sumSquared / (sideSquared * minimum))
    }

    @discardableResult
    private static func layoutRow(_ row: [WeightedEntry], in bounds: CGRect, into result: inout [Tile]) -> CGRect {
        guard !row.isEmpty, bounds.width > 0, bounds.height > 0 else { return bounds }
        let rowArea = row.reduce(CGFloat(0)) { $0 + $1.area }

        if bounds.width >= bounds.height {
            let columnWidth = min(rowArea / bounds.height, bounds.width)
            var cursorY = bounds.minY
            for (index, weighted) in row.enumerated() {
                let height = index == row.count - 1
                    ? max(bounds.maxY - cursorY, 0)
                    : min(weighted.area / max(columnWidth, .leastNonzeroMagnitude), bounds.maxY - cursorY)
                result.append(Tile(entry: weighted.entry,
                                   rect: CGRect(x: bounds.minX, y: cursorY, width: columnWidth, height: height)))
                cursorY += height
            }
            return CGRect(x: bounds.minX + columnWidth, y: bounds.minY,
                          width: max(bounds.width - columnWidth, 0), height: bounds.height)
        }

        let rowHeight = min(rowArea / bounds.width, bounds.height)
        var cursorX = bounds.minX
        for (index, weighted) in row.enumerated() {
            let width = index == row.count - 1
                ? max(bounds.maxX - cursorX, 0)
                : min(weighted.area / max(rowHeight, .leastNonzeroMagnitude), bounds.maxX - cursorX)
            result.append(Tile(entry: weighted.entry,
                               rect: CGRect(x: cursorX, y: bounds.minY, width: width, height: rowHeight)))
            cursorX += width
        }
        return CGRect(x: bounds.minX, y: bounds.minY + rowHeight,
                      width: bounds.width, height: max(bounds.height - rowHeight, 0))
    }

    private static func childContentBounds(in rect: CGRect) -> CGRect? {
        guard rect.width >= minimumContainerWidth, rect.height >= minimumContainerHeight else { return nil }
        var content = rect.insetBy(dx: containerInset, dy: containerInset)
        content.origin.y += containerHeaderHeight
        content.size.height -= containerHeaderHeight
        guard content.width > 0, content.height > 0 else { return nil }
        return content
    }

    private static func normalized(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.minX / size.width, y: rect.minY / size.height,
               width: rect.width / size.width, height: rect.height / size.height)
    }
}

/// Scales a normalized tile to points, with a hairline inset so tiles read as
/// separate. Adapted from Radix's TreemapRenderer.
enum TreemapRenderer {
    private static let displayInset: CGFloat = 0.75

    static func rect(for segment: TreemapSegment, in size: CGSize) -> CGRect {
        CGRect(x: segment.rect.minX * size.width, y: segment.rect.minY * size.height,
               width: segment.rect.width * size.width, height: segment.rect.height * size.height)
    }

    static func displayRect(for segment: TreemapSegment, in size: CGSize) -> CGRect {
        let rect = rect(for: segment, in: size)
        let inset = min(displayInset, min(rect.width, rect.height) * 0.12)
        return rect.insetBy(dx: inset, dy: inset)
    }
}

/// Bucketed hit test: index tiles into a coarse grid, then prefer the deepest
/// (topmost) tile under the point. Adapted from Radix's TreemapHitTestIndex.
struct TreemapHitTestIndex: Sendable {
    private static let columnCount = 32
    private static let rowCount = 24

    private let segments: [TreemapSegment]
    private let buckets: [[Int]]

    init(segments: [TreemapSegment]) {
        self.segments = segments
        var buckets = Array(repeating: [Int](), count: Self.columnCount * Self.rowCount)
        for (segmentIndex, segment) in segments.enumerated() {
            let columns = Self.bucketRange(min: segment.rect.minX, max: segment.rect.maxX, count: Self.columnCount)
            let rows = Self.bucketRange(min: segment.rect.minY, max: segment.rect.maxY, count: Self.rowCount)
            for row in rows {
                for column in columns {
                    buckets[row * Self.columnCount + column].append(segmentIndex)
                }
            }
        }
        for bucketIndex in buckets.indices {
            buckets[bucketIndex].sort { lhs, rhs in
                segments[lhs].depth == segments[rhs].depth
                    ? lhs > rhs
                    : segments[lhs].depth > segments[rhs].depth
            }
        }
        self.buckets = buckets
    }

    func segment(at point: CGPoint, in size: CGSize) -> TreemapSegment? {
        guard size.width > 0, size.height > 0 else { return nil }
        let unit = CGPoint(x: point.x / size.width, y: point.y / size.height)
        guard unit.x >= 0, unit.x <= 1, unit.y >= 0, unit.y <= 1 else { return nil }

        let column = min(Int(unit.x * CGFloat(Self.columnCount)), Self.columnCount - 1)
        let row = min(Int(unit.y * CGFloat(Self.rowCount)), Self.rowCount - 1)
        for index in buckets[row * Self.columnCount + column] {
            let segment = segments[index]
            if TreemapRenderer.displayRect(for: segment, in: size).contains(point) {
                return segment
            }
        }
        return nil
    }

    private static func bucketRange(min minimum: CGFloat, max maximum: CGFloat, count: Int) -> ClosedRange<Int> {
        let lower = Swift.min(Swift.max(Int(floor(minimum * CGFloat(count))), 0), count - 1)
        let adjustedMax = Swift.max(maximum - CGFloat.ulpOfOne, minimum)
        let upper = Swift.min(Swift.max(Int(floor(adjustedMax * CGFloat(count))), 0), count - 1)
        return lower...Swift.max(lower, upper)
    }
}

// MARK: - View

/// Theme-skinned treemap. Hover highlights a tile and reports it upward and
/// into a floating tooltip that follows the pointer; a click on a directory
/// tile drills in. Small tiles hide their inline label, so the tooltip is often
/// the only way to read them — its placement is edge-avoiding (vendored
/// `TreemapTooltipPlacement`) so it never clips off the chart.
struct TreemapChartView: View {
    let root: DiskNode
    let depthLimit: Int
    /// Paths staged for deletion; their tiles render dimmed with a dashed warn
    /// outline so the pending pile is visible in the chart.
    let stagedPaths: Set<String>
    let onHover: (DiskChartHover?) -> Void
    let onDrill: (DiskNode) -> Void
    /// Right-click actions for the tile under the pointer.
    let contextActions: (DiskChartHover) -> [DiskChartContextAction]

    @State private var hoveredID: String?
    @State private var hovered: DiskChartHover?
    @State private var tooltip: Tooltip?

    /// Upper bound the placement math reserves so a long name wrapping onto a
    /// second line still can't push the tooltip off the chart.
    private static let tooltipSize = CGSize(width: 208, height: 48)

    /// A hovered tile's readout plus where the pointer was, for the tooltip.
    private struct Tooltip: Equatable {
        let name: String
        let size: Int64
        let location: CGPoint
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let segments = TreemapLayout.segments(root: root, depthLimit: depthLimit, size: size)
            let index = TreemapHitTestIndex(segments: segments)

            Canvas { context, _ in
                for segment in segments {
                    draw(segment, in: &context, size: size)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    let hit = index.segment(at: point, in: size)
                    hoveredID = hit?.id
                    let readout = hit.map { DiskChartHover(name: $0.label, size: $0.size, path: $0.path) }
                    hovered = readout
                    onHover(readout)
                    tooltip = hit.map { Tooltip(name: $0.label, size: $0.size, location: point) }
                case .ended:
                    hoveredID = nil
                    hovered = nil
                    onHover(nil)
                    tooltip = nil
                }
            }
            .contextMenu {
                if let hovered, hovered.path != nil {
                    ForEach(Array(contextActions(hovered).enumerated()), id: \.offset) { _, action in
                        Button(action.title, role: action.isDestructive ? .destructive : nil) {
                            action.handler()
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if let tooltip {
                    TreemapTooltipView(name: tooltip.name, size: tooltip.size)
                        .frame(width: Self.tooltipSize.width, alignment: .leading)
                        .offset(tooltipOffset(for: tooltip.location, in: size))
                        .allowsHitTesting(false)
                }
            }
            .gesture(
                SpatialTapGesture(coordinateSpace: .local).onEnded { value in
                    guard let hit = index.segment(at: value.location, in: size),
                          hit.isDrillable,
                          let node = root.firstDescendant(id: hit.path ?? "") else { return }
                    onDrill(node)
                }
            )
        }
    }

    private func tooltipOffset(for location: CGPoint, in size: CGSize) -> CGSize {
        let origin = TreemapTooltipPlacement.origin(
            for: location,
            tooltipSize: Self.tooltipSize,
            in: CGRect(origin: .zero, size: size)
        )
        return CGSize(width: origin.x, height: origin.y)
    }

    private func draw(_ segment: TreemapSegment, in context: inout GraphicsContext, size: CGSize) {
        let rect = TreemapRenderer.displayRect(for: segment, in: size)
        guard rect.width > 1, rect.height > 1 else { return }

        let color = DiskChartPalette.color(
            depth: segment.depth,
            branchIndex: segment.branchIndex,
            branchCount: segment.branchCount,
            fraction: segment.fraction,
            isAggregate: segment.isAggregate
        )
        let isHovered = segment.id == hoveredID
        let isStaged = segment.path.map(stagedPaths.contains) ?? false
        let shape = Path(roundedRect: rect, cornerRadius: 3)

        // Container tiles get a translucent header band so their children read
        // as nested; leaf tiles fill solid. Staged tiles fade back under a
        // dashed warn outline regardless of kind.
        if isStaged {
            context.fill(shape, with: .color(color.opacity(0.22)))
        } else if segment.showsContainerHeader {
            context.fill(shape, with: .color(color.opacity(0.28)))
            let header = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(16, rect.height))
            context.fill(Path(roundedRect: header, cornerRadius: 3), with: .color(color.opacity(0.85)))
        } else {
            context.fill(shape, with: .color(color.opacity(isHovered ? 1 : 0.9)))
        }
        context.stroke(shape, with: .color(.black.opacity(0.18)), lineWidth: 0.5)
        if isStaged {
            context.stroke(shape, with: .color(Theme.warn.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        } else if isHovered {
            context.stroke(shape, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
        }

        drawLabel(for: segment, rect: rect, in: &context)
    }

    private func drawLabel(for segment: TreemapSegment, rect: CGRect, in context: inout GraphicsContext) {
        // Only label tiles with room; container labels sit in the header band.
        let labelHeight: CGFloat = segment.showsContainerHeader ? 16 : rect.height
        guard rect.width >= 46, labelHeight >= 14 else { return }

        let resolved = context.resolve(
            Text(segment.label)
                .font(Theme.rounded(9, .semibold))
                .foregroundStyle(.white)
        )
        // Skip labels that would overflow their tile rather than clip mid-glyph.
        let measured = resolved.measure(in: CGSize(width: rect.width - 6, height: labelHeight))
        guard measured.width <= rect.width - 4 else { return }
        context.draw(resolved, at: CGPoint(x: rect.minX + 4, y: rect.minY + 3), anchor: .topLeading)

        // Size on a second line when the tile is tall enough and not a header.
        if !segment.showsContainerHeader, rect.height >= 30 {
            let sizeText = context.resolve(
                Text(ByteFormat.si(segment.size))
                    .font(Theme.rounded(9))
                    .foregroundStyle(.white.opacity(0.85))
            )
            context.draw(sizeText, at: CGPoint(x: rect.minX + 4, y: rect.minY + 15), anchor: .topLeading)
        }
    }
}

/// Compact at-cursor readout for the treemap: the hovered tile's name and size.
/// Positioned by `TreemapTooltipPlacement` so it stays inside the chart.
private struct TreemapTooltipView: View {
    let name: String
    let size: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(Theme.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(ByteFormat.si(size))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCard(cornerRadius: 10)
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}
