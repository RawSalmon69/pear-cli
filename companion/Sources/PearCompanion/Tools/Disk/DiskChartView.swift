import SwiftUI
import AppKit

/// Hosts the native sunburst/treemap charts: owns the scan, a drill breadcrumb,
/// and the hover readout, and swaps between the two chart styles without
/// rescanning (both read the same tree). Scans the user's home folder lazily on
/// first appearance and cancels on disappear.
struct DiskChartView: View {
    let style: DiskChartStyle

    @State private var model = DiskScanModel()
    /// Directories drilled into, deepest last. Empty == the scan root.
    @State private var stack: [DiskNode] = []
    @State private var hover: DiskChartHover?

    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    private static let sunburstDepth = 5
    private static let treemapDepth = 4
    private static let chartHeight: CGFloat = 320

    private var displayedRoot: DiskNode? { stack.last ?? model.root }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            header
            chartArea
        }
        .task { model.scanIfNeeded(path: Self.homePath) }
        .onDisappear { model.cancel() }
        .animation(.easeOut(duration: 0.18), value: stack)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.itemGap) {
            if !stack.isEmpty {
                GlyphButton(symbol: "chevron.left", help: "Back", tint: .secondary) { goUp() }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(Theme.caption)
                    .foregroundStyle(hover == nil ? Color.secondary : Theme.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            GlyphButton(symbol: "arrow.clockwise", help: "Rescan", tint: .secondary) { rescan() }
                .disabled(model.isScanning)
        }
    }

    private var title: String {
        stack.isEmpty ? "Home" : (displayedRoot?.name ?? "Home")
    }

    private var subtitle: String {
        if let hover {
            return "\(hover.name) · \(ByteFormat.si(hover.size))"
        }
        guard let root = displayedRoot else { return "Measuring…" }
        return "\(ByteFormat.si(root.size)) · \(displayPath(root.id))"
    }

    // MARK: Chart area

    @ViewBuilder
    private var chartArea: some View {
        if let root = displayedRoot {
            chart(for: root)
                .frame(height: Self.chartHeight)
                .frame(maxWidth: .infinity)
                .opacity(model.isScanning ? 0.5 : 1)
        } else if let message = model.errorMessage {
            errorCard(message)
        } else {
            loadingCard
        }
    }

    @ViewBuilder
    private func chart(for root: DiskNode) -> some View {
        switch style {
        case .sunburst:
            SunburstChartView(
                root: root,
                depthLimit: Self.sunburstDepth,
                onHover: { hover = $0 },
                onDrill: { drill(into: $0) },
                onGoUp: { goUp() }
            )
            .padding(4)
        case .treemap:
            TreemapChartView(
                root: root,
                depthLimit: Self.treemapDepth,
                onHover: { hover = $0 },
                onDrill: { drill(into: $0) }
            )
            .glassCard(cornerRadius: 12)
        }
    }

    private var loadingCard: some View {
        VStack(spacing: Theme.itemGap) {
            ProgressView().controlSize(.small)
            Text("Scanning your home folder…")
                .font(Theme.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: Self.chartHeight)
        .glassCard(cornerRadius: 16)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            Label("Can't scan right now", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.emphasis)
                .foregroundStyle(Theme.warn)
            Text(message)
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { rescan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, minHeight: Self.chartHeight, alignment: .topLeading)
        .padding(Theme.heroPadding)
        .glassCard(cornerRadius: 16)
    }

    // MARK: Navigation

    private func drill(into node: DiskNode) {
        guard node.isDirectory, node.hasChildren else { return }
        hover = nil
        stack.append(node)
    }

    private func goUp() {
        guard !stack.isEmpty else { return }
        hover = nil
        stack.removeLast()
    }

    private func rescan() {
        hover = nil
        stack = []
        model.scan(path: Self.homePath)
    }

    private func displayPath(_ path: String) -> String {
        if !Self.homePath.isEmpty, path.hasPrefix(Self.homePath) {
            let tail = path.dropFirst(Self.homePath.count)
            return tail.isEmpty ? "~" : "~" + tail
        }
        return path
    }
}
