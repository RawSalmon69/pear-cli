import SwiftUI
import AppKit

/// Disk tool popover: a three-mode explorer.
///
/// All three modes — sunburst, treemap and bars — are drawn from one native,
/// off-main disk scan (`Tools/Disk`, engine vendored from Radix). Nothing here
/// shells out. Fits a ~380 pt menu-bar panel.
struct DiskAnalyzeView: View {
    @State private var mode: DiskViewMode = .bars
    /// The two-phase deletion pile, shared across all three modes so the pending
    /// section and "Delete all" stay consistent as the user switches views.
    @State private var staging = DiskStagingModel()
    /// Passed in by the window controller, which cancels it on window close.
    let scanModel: DiskScanModel

    init(scanModel: DiskScanModel) {
        self.scanModel = scanModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            Picker("View", selection: $mode) {
                ForEach(DiskViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .focusable(false)

            switch mode {
            case .bars:
                DiskBarsView(staging: staging, model: scanModel)
            case .sunburst, .treemap:
                DiskChartView(style: mode == .treemap ? .treemap : .sunburst,
                              staging: staging, model: scanModel)
            }

            Spacer(minLength: 0)

            if !staging.isEmpty {
                PendingDeletionSection(staging: staging)
            }
        }
        .padding(16)
        // Hosted in a resizable window: fill it, with a floor so the dense
        // layout never collapses.
        .frame(minWidth: 380, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.18), value: staging.isEmpty)
    }
}

/// The three view modes offered by the Disk tool.
enum DiskViewMode: String, CaseIterable, Identifiable {
    case sunburst
    case treemap
    case bars

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sunburst: return "Sunburst"
        case .treemap: return "Treemap"
        case .bars: return "Bars"
        }
    }
}

// MARK: - Bars mode

/// Disk usage as a proportional bar list, reading the same native scan tree the
/// charts draw. Opens on the scanned root and drills into directories one level
/// at a time, with a Back stack.
private struct DiskBarsView: View {
    let staging: DiskStagingModel
    /// Owned by `DiskWindowController` and shared with the chart modes, so
    /// switching view mode never rescans.
    let model: DiskScanModel

    /// Directories drilled into, deepest last, held as path ids rather than
    /// node copies: pruning a trashed path rewrites the tree, and an id
    /// re-resolves against the new one where a copied node would go stale.
    @State private var stack: [String] = []

    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    /// The node the bars are showing, plus the levels of `stack` that still
    /// resolve against the current tree (a pruned level drops off the end).
    private var resolved: (node: DiskNode, stack: [String])? {
        guard let root = model.root else { return nil }
        var node = root
        var alive: [String] = []
        for id in stack {
            guard let next = node.children.first(where: { $0.id == id }) else { break }
            node = next
            alive.append(id)
        }
        return (node, alive)
    }

    private var entries: [DiskNode] { resolved?.node.children ?? [] }
    private var totalSize: Int64 { resolved?.node.size ?? 0 }
    private var maxEntrySize: Int64 { entries.map(\.size).max() ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            header
            content
        }
        .task { model.scanIfNeeded(path: Self.homePath) }
        .onChange(of: staging.trashGeneration) { _, _ in
            for path in staging.lastTrashed { model.remove(pathID: path) }
            stack = resolved?.stack ?? []
        }
        // Keyed on ids, not the nodes: `DiskNode` equality walks the whole
        // subtree, and this runs on every layout pass.
        .animation(.easeOut(duration: 0.2), value: entries.map(\.id))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.itemGap) {
            if !stack.isEmpty {
                GlyphButton(symbol: "chevron.left", help: "Back", tint: .secondary) {
                    goBack()
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            GlyphButton(symbol: "arrow.clockwise", help: "Rescan", tint: .secondary) {
                rescan()
            }
            .disabled(model.isScanning)
        }
    }

    private var title: String {
        stack.isEmpty ? "Home" : (resolved?.node.name ?? "Home")
    }

    private var subtitle: String {
        guard let node = resolved?.node else { return "Measuring…" }
        return "\(ByteFormat.si(node.size)) · \(displayPath(node.id))"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let node = resolved?.node {
            if node.children.isEmpty {
                emptyCard
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.sectionGap) {
                        VStack(spacing: 6) {
                            ForEach(entries) { entry in
                                EntryBar(
                                    entry: entry,
                                    maxSize: maxEntrySize,
                                    totalSize: totalSize,
                                    canDrill: entry.isDirectory && entry.hasChildren,
                                    staging: staging,
                                    onDrill: { drill(into: entry) }
                                )
                            }
                        }

                        // Measured once per scan against the scan root, so it
                        // belongs to the root level and not to a drilled-in one.
                        if stack.isEmpty, !model.largeFiles.isEmpty {
                            largestFiles(model.largeFiles)
                        }
                    }
                    .padding(.bottom, 2)
                }
                .frame(maxHeight: 420)
                .opacity(model.isScanning ? 0.5 : 1)
            }
        } else if let message = model.errorMessage {
            errorCard(message)
        } else {
            loadingCard
        }
    }

    private func largestFiles(_ files: [DiskNode]) -> some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Largest files")
            VStack(spacing: 4) {
                ForEach(files) { file in
                    LargeFileRow(file: file, staging: staging)
                }
            }
        }
    }

    // MARK: States

    private var loadingCard: some View {
        VStack(spacing: Theme.itemGap) {
            ProgressView()
                .controlSize(.small)
            Text("Measuring disk usage…")
                .font(Theme.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(Theme.heroPadding)
        .glassCard(cornerRadius: 16)
    }

    private var emptyCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "internaldrive")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("Nothing to show here")
                .font(Theme.emphasis)
            Text("This location is empty or too small to measure.")
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(Theme.heroPadding)
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
                .focusable(false)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.heroPadding)
        .glassCard(cornerRadius: 16)
    }

    // MARK: Navigation

    /// Drilling is a move within the already-measured tree — no rescan.
    private func drill(into entry: DiskNode) {
        guard entry.isDirectory, entry.hasChildren else { return }
        stack.append(entry.id)
    }

    private func goBack() {
        guard !stack.isEmpty else { return }
        stack.removeLast()
    }

    private func rescan() {
        stack = []
        model.scan(path: Self.homePath)
    }

    private func displayPath(_ path: String) -> String {
        guard !Self.homePath.isEmpty, path.hasPrefix(Self.homePath) else { return path }
        let tail = path.dropFirst(Self.homePath.count)
        return tail.isEmpty ? "~" : "~" + tail
    }
}

// MARK: - Entry bar

/// A proportional horizontal bar for one entry: name, human size, share of
/// total, and a width proportional to size. Warn-tinted when it dominates the
/// total; directories are tappable to drill in.
private struct EntryBar: View {
    let entry: DiskNode
    let maxSize: Int64
    let totalSize: Int64
    let canDrill: Bool
    let staging: DiskStagingModel
    let onDrill: () -> Void

    @State private var hovering = false

    private var isStaged: Bool { staging.isStaged(entry.id) }

    private var fractionOfMax: Double {
        guard maxSize > 0 else { return 0 }
        return min(1, Double(entry.size) / Double(maxSize))
    }

    private var shareOfTotal: Double {
        guard totalSize > 0 else { return 0 }
        return Double(entry.size) / Double(totalSize)
    }

    private var isVeryLarge: Bool { shareOfTotal >= 0.5 }

    private var barColor: Color {
        isVeryLarge ? Theme.warn : Theme.accent
    }

    private var percentText: String {
        let percent = shareOfTotal * 100
        if percent > 0 && percent < 0.1 { return "< 0.1%" }
        return String(format: "%.1f%%", percent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(barColor)
                Text(entry.name)
                    .font(Theme.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(ByteFormat.si(entry.size))
                    .font(Theme.rounded(12, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.5))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(3, geo.size.width * fractionOfMax))
                }
            }
            .frame(height: 6)

            HStack(spacing: 4) {
                Text(percentText)
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                GlyphButton(symbol: "magnifyingglass", help: "Reveal in Finder", tint: .secondary) {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: entry.id)]
                    )
                }
                if DiskDeletion.canTrash(path: entry.id) {
                    if isStaged {
                        GlyphButton(symbol: "arrow.uturn.backward", help: "Restore", tint: .secondary) {
                            staging.restore(path: entry.id)
                        }
                    } else {
                        GlyphButton(symbol: "trash", help: "Delete", tint: Theme.warn) {
                            staging.stage(name: entry.name, path: entry.id, size: entry.size)
                        }
                    }
                }
                if canDrill {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(Theme.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(hovering && canDrill ? Theme.accentSoft : .clear)
        )
        .glassCard(cornerRadius: 12)
        .opacity(isStaged ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if canDrill && !isStaged { onDrill() } }
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder
    private var menuItems: some View {
        if DiskDeletion.canTrash(path: entry.id) {
            if isStaged {
                Button("Restore") { staging.restore(path: entry.id) }
            } else {
                Button("Delete", role: .destructive) {
                    staging.stage(name: entry.name, path: entry.id, size: entry.size)
                }
            }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.id)])
        }
    }
}

// MARK: - Large file row

private struct LargeFileRow: View {
    let file: DiskNode
    let staging: DiskStagingModel

    private var isStaged: Bool { staging.isStaged(file.id) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(file.name)
                .font(Theme.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(ByteFormat.si(file.size))
                .font(Theme.rounded(12, .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            GlyphButton(symbol: "magnifyingglass", help: "Reveal in Finder", tint: .secondary) {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: file.id)]
                )
            }
            if DiskDeletion.canTrash(path: file.id) {
                if isStaged {
                    GlyphButton(symbol: "arrow.uturn.backward", help: "Restore", tint: .secondary) {
                        staging.restore(path: file.id)
                    }
                } else {
                    GlyphButton(symbol: "trash", help: "Delete", tint: Theme.warn) {
                        staging.stage(name: file.name, path: file.id, size: file.size)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 10)
        .opacity(isStaged ? 0.5 : 1)
        .contextMenu {
            if DiskDeletion.canTrash(path: file.id) {
                if isStaged {
                    Button("Restore") { staging.restore(path: file.id) }
                } else {
                    Button("Delete", role: .destructive) {
                        staging.stage(name: file.name, path: file.id, size: file.size)
                    }
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.id)])
            }
        }
    }
}

// MARK: - Pending deletion

/// The two-phase pile: everything staged for deletion, its running total, a
/// per-item restore (button + right-click), and the one "Delete all" button
/// that actually touches disk — funneling each staged path through
/// `DiskDeletion`'s single Trash sink.
private struct PendingDeletionSection: View {
    let staging: DiskStagingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            HStack(spacing: 4) {
                SectionLabel(text: "Pending deletion")
                Spacer(minLength: 4)
                Text("\(staging.count) · \(ByteFormat.si(staging.totalSize))")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(staging.items) { item in
                        PendingRow(item: item, staging: staging)
                    }
                }
            }
            .frame(maxHeight: 160)

            Button(role: .destructive) {
                Task { await deleteAll() }
            } label: {
                Label(deleteAllTitle, systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(Theme.warn)
            .focusable(false)
        }
        .padding(Theme.cardPadding)
        .glassCard(cornerRadius: 12)
    }

    private var deleteAllTitle: String {
        let itemWord = staging.count == 1 ? "item" : "items"
        return "Delete all (\(staging.count) \(itemWord), \(ByteFormat.si(staging.totalSize)))"
    }

    private func deleteAll() async {
        let trashed = await DiskTrashPrompt.confirmAndTrashAll(
            count: staging.count,
            totalSize: staging.totalSize,
            paths: staging.orderedPaths
        )
        staging.removeTrashed(trashed)
    }
}

/// One row of the pending pile: struck-through name, size, reveal, and restore
/// (button, plus a right-click Restore / Reveal menu).
private struct PendingRow: View {
    let item: DiskStagingModel.StagedItem
    let staging: DiskStagingModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "trash")
                .font(.system(size: 10))
                .foregroundStyle(Theme.warn)
            Text(item.name)
                .font(Theme.body)
                .strikethrough(true, color: .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(ByteFormat.si(item.size))
                .font(Theme.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            GlyphButton(symbol: "magnifyingglass", help: "Reveal in Finder", tint: .secondary) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
            GlyphButton(symbol: "arrow.uturn.backward", help: "Restore", tint: .secondary) {
                staging.restore(path: item.path)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Restore") { staging.restore(path: item.path) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
        }
    }
}
