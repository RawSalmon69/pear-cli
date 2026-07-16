import SwiftUI

// Chart behavior adapted from Stats (MIT), https://github.com/exelban/stats,
// commit 81afabad — reimplemented in SwiftUI.
//
// Stats' whole meter/graph layer is AppKit (`NSView`/`NSBezierPath`/`CATransaction`),
// so nothing was copied. What is adapted is the *approach* of three concrete
// classes in `Kit/plugins/Charts.swift`:
//   • `LineChartView`  — a fixed ring buffer of samples, drawn as a line with a
//     gradient fill down to a baseline (`TrendChart` below).
//   • `NetworkChartView` — two line charts mirrored around a center line, one
//     per direction (`NetworkTrendChart` below).
// The ring buffer mirrors `LineChartView.points`/`head`/`addValue`; the fill and
// scale mirror its `draw(_:)`. Everything here is pure SwiftUI `Canvas` drawing.

// MARK: - Ring buffer

/// A fixed-capacity ring buffer of samples, oldest → newest. Overwrites the
/// oldest sample once full; never grows past `capacity`. A pure `Sendable` value
/// type so `MonitorModel` can hold one per section and the wrap/clear behavior is
/// unit-testable. Mirrors `LineChartView.points`/`head` from Stats' `Charts.swift`.
struct HistoryBuffer<Element: Sendable>: Sendable {
    let capacity: Int
    private var storage: [Element] = []
    /// Index of the oldest sample (== next write slot once full).
    private var head = 0
    private var wrapped = false

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    /// Number of samples currently held (0…capacity).
    var count: Int { wrapped ? capacity : head }

    var isEmpty: Bool { count == 0 }

    /// Appends a sample, evicting the oldest once at capacity.
    mutating func append(_ value: Element) {
        if storage.count < capacity {
            storage.append(value)
        } else {
            storage[head] = value
        }
        head = (head + 1) % capacity
        if head == 0 { wrapped = true }
    }

    /// Drops every sample so a re-shown section starts fresh rather than
    /// resuming an old trend across a gap.
    mutating func clear() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        wrapped = false
    }

    /// Samples in chronological order, oldest first. Before the buffer wraps
    /// this is just what was appended; after, it reads from `head` around.
    var values: [Element] {
        guard wrapped else { return storage }
        var result = [Element]()
        result.reserveCapacity(capacity)
        for i in 0..<capacity {
            result.append(storage[(head + i) % capacity])
        }
        return result
    }
}

// MARK: - Geometry

enum ChartGeometry {
    /// Normalizes oldest → newest values to 0…1 against `maxValue`, clamped into
    /// range. Fewer than two values yields `[]` (nothing to draw); a non-positive
    /// `maxValue` is treated as 1 so a flat/empty series never divides by zero.
    /// This is the one piece of chart math worth testing on its own.
    static func normalized(_ values: [Double], maxValue: Double) -> [Double] {
        guard values.count >= 2 else { return [] }
        let denom = maxValue > 0 ? maxValue : 1
        return values.map { min(1, max(0, $0 / denom)) }
    }
}

/// Builds the stroked line and the filled-to-baseline area for one series.
/// `points` are screen coordinates oldest → newest; `baselineY` is the edge the
/// fill closes back to. Returns nil for degenerate (< 2 point) series.
private func seriesPaths(points: [CGPoint], baselineY: CGFloat) -> (line: Path, fill: Path)? {
    guard points.count >= 2 else { return nil }
    var line = Path()
    line.move(to: points[0])
    for p in points.dropFirst() { line.addLine(to: p) }
    var fill = line
    fill.addLine(to: CGPoint(x: points[points.count - 1].x, y: baselineY))
    fill.addLine(to: CGPoint(x: points[0].x, y: baselineY))
    fill.closeSubpath()
    return (line, fill)
}

// MARK: - Line trend chart (CPU, memory)

/// A scrolling line chart with a gradient fill under it, for a single 0…1 series
/// (CPU load, memory used fraction). Newest sample is at the right edge, so the
/// trace scrolls left as history fills — the `LineChartView` behavior from Stats,
/// drawn with a SwiftUI `Canvas`.
struct TrendChart: View {
    /// Oldest → newest, each already a 0…1 fraction.
    let values: [Double]
    let tint: Color
    var height: CGFloat = 34

    var body: some View {
        Canvas { context, size in
            let fractions = ChartGeometry.normalized(values, maxValue: 1)
            guard fractions.count >= 2 else { return }
            let dx = size.width / CGFloat(fractions.count - 1)
            let points = fractions.enumerated().map { i, f in
                CGPoint(x: CGFloat(i) * dx, y: size.height * (1 - f))
            }
            guard let paths = seriesPaths(points: points, baselineY: size.height) else { return }
            context.fill(
                paths.fill,
                with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.35), tint.opacity(0.04)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(paths.line, with: .color(tint), lineWidth: 1.5)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Network trend chart (download / upload)

/// Two mirrored line traces around a center line — download growing down, upload
/// growing up — each auto-scaled to its own peak, matching Stats' `NetworkChartView`
/// (default, non-reversed order). The instant rows carry the exact numbers; this
/// carries the shape of recent traffic.
struct NetworkTrendChart: View {
    /// Oldest → newest bytes/sec.
    let download: [Double]
    let upload: [Double]
    let downTint: Color
    let upTint: Color
    var height: CGFloat = 44

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            // Each direction scales to its own recent peak (floor of 1 B/s keeps a
            // silent link a flat line at center instead of dividing by zero). The
            // gradient fades from the outer edge in to the shared center baseline.
            drawHalf(
                &context, series: upload, size: size,
                yFor: { frac in mid * (1 - frac) }, baselineY: mid, outerEdgeY: 0, tint: upTint)
            drawHalf(
                &context, series: download, size: size,
                yFor: { frac in mid + mid * frac }, baselineY: mid, outerEdgeY: size.height,
                tint: downTint)
            // Faint center rule to anchor the mirror.
            var center = Path()
            center.move(to: CGPoint(x: 0, y: mid))
            center.addLine(to: CGPoint(x: size.width, y: mid))
            context.stroke(center, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func drawHalf(
        _ context: inout GraphicsContext,
        series: [Double],
        size: CGSize,
        yFor: (CGFloat) -> CGFloat,
        baselineY: CGFloat,
        outerEdgeY: CGFloat,
        tint: Color
    ) {
        let peak = max(series.max() ?? 0, 1)
        let fractions = ChartGeometry.normalized(series, maxValue: peak)
        guard fractions.count >= 2 else { return }
        let dx = size.width / CGFloat(fractions.count - 1)
        let points = fractions.enumerated().map { i, f in
            CGPoint(x: CGFloat(i) * dx, y: yFor(CGFloat(f)))
        }
        guard let paths = seriesPaths(points: points, baselineY: baselineY) else { return }
        context.fill(
            paths.fill,
            with: .linearGradient(
                Gradient(colors: [tint.opacity(0.30), tint.opacity(0.04)]),
                startPoint: CGPoint(x: 0, y: outerEdgeY),
                endPoint: CGPoint(x: 0, y: baselineY)))
        context.stroke(paths.line, with: .color(tint), lineWidth: 1.5)
    }
}
