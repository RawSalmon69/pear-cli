import SwiftUI
import AppKit

/// Disk tool popover: a three-mode explorer.
///
/// Sunburst and treemap are drawn from a native, off-main disk scan
/// (`Tools/Disk`, engine vendored from Radix); bars keeps the existing
/// `pear analyze` overview + one-level drill. The chart scan runs lazily, only
/// when a chart mode is on screen. Fits a ~380 pt menu-bar panel.
struct DiskAnalyzeView: View {
    // Defaults to bars so the popover paints instantly with the fast
    // `pear analyze` overview; the native home-folder scan behind sunburst and
    // treemap runs only when the user selects one of those modes.
    @State private var mode: DiskViewMode = .bars
    /// The two-phase deletion pile, shared across all three modes so the pending
    /// section and "Delete all" stay consistent as the user switches views.
    @State private var staging = DiskStagingModel()

    init() {}

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
                DiskBarsView(staging: staging)
            case .sunburst, .treemap:
                DiskChartView(style: mode == .treemap ? .treemap : .sunburst, staging: staging)
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

/// Disk usage as a proportional bar list, backed by `pear analyze --json`.
/// Opens on the storage overview and drills into directories one level at a
/// time, with a Back path stack.
private struct DiskBarsView: View {
    let staging: DiskStagingModel

    @State private var service = DiskAnalyzeService()
    /// Directories drilled into, deepest last. Empty == the overview.
    @State private var pathStack: [String] = []

    private var maxEntrySize: Int64 {
        service.entries.map(\.size).max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            header
            content
        }
        .task {
            if service.entries.isEmpty && service.errorMessage == nil {
                await service.scan(path: nil)
            }
        }
        .onChange(of: staging.trashGeneration) { _, _ in
            service.remove(paths: staging.lastTrashed)
        }
        .animation(.easeOut(duration: 0.2), value: service.entries)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.itemGap) {
            if !pathStack.isEmpty {
                GlyphButton(symbol: "chevron.left", help: "Back", tint: .secondary) {
                    goBack()
                }
                .disabled(service.isLoading)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(pathStack.isEmpty ? "Storage" : locationTitle)
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
                Task { await service.scan(path: pathStack.last) }
            }
            .disabled(service.isLoading)
        }
    }

    private var locationTitle: String {
        guard let path = service.currentPath else { return "Storage" }
        return (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
    }

    private var subtitle: String {
        if service.isOverview {
            return "\(ByteFormat.si(service.totalSize)) across top categories"
        }
        if let path = service.currentPath {
            return "\(ByteFormat.si(service.totalSize)) · \(displayPath(path))"
        }
        return ByteFormat.si(service.totalSize)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if service.isLoading && service.entries.isEmpty {
            loadingCard
        } else if let message = service.errorMessage {
            errorCard(message)
        } else if service.entries.isEmpty {
            emptyCard
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    VStack(spacing: 6) {
                        ForEach(service.entries) { entry in
                            EntryBar(
                                entry: entry,
                                maxSize: maxEntrySize,
                                totalSize: service.totalSize,
                                canDrill: entry.isDir && !service.isLoading,
                                staging: staging,
                                onDrill: { drill(into: entry) }
                            )
                        }
                    }

                    if !service.largeFiles.isEmpty {
                        largestFiles
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(maxHeight: 420)
            .opacity(service.isLoading ? 0.5 : 1)
        }
    }

    private var largestFiles: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Largest files")
            VStack(spacing: 4) {
                ForEach(service.largeFiles) { file in
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
            Label("Can't analyze right now", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.emphasis)
                .foregroundStyle(Theme.warn)
            Text(message)
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") {
                Task { await service.scan(path: pathStack.last) }
            }
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

    private func drill(into entry: DiskEntry) {
        guard entry.isDir, !service.isLoading else { return }
        pathStack.append(entry.path)
        Task { await service.scan(path: entry.path) }
    }

    private func goBack() {
        guard !pathStack.isEmpty else { return }
        pathStack.removeLast()
        Task { await service.scan(path: pathStack.last) }
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty, path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Entry bar

/// A proportional horizontal bar for one entry: name, human size, share of
/// total, and a width proportional to size. Warn-tinted when very large or
/// cleanable; directories are tappable to drill in.
private struct EntryBar: View {
    let entry: DiskEntry
    let maxSize: Int64
    let totalSize: Int64
    let canDrill: Bool
    let staging: DiskStagingModel
    let onDrill: () -> Void

    @State private var hovering = false

    private var isStaged: Bool { staging.isStaged(entry.path) }

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
        (entry.cleanable || isVeryLarge) ? Theme.warn : Theme.accent
    }

    private var percentText: String {
        let percent = shareOfTotal * 100
        if percent > 0 && percent < 0.1 { return "< 0.1%" }
        return String(format: "%.1f%%", percent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: entry.isDir ? "folder.fill" : "doc.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(barColor)
                Text(entry.name)
                    .font(Theme.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if entry.cleanable {
                    CleanableBadge()
                }
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
                        [URL(fileURLWithPath: entry.path)]
                    )
                }
                if DiskDeletion.canTrash(path: entry.path) {
                    if isStaged {
                        GlyphButton(symbol: "arrow.uturn.backward", help: "Restore", tint: .secondary) {
                            staging.restore(path: entry.path)
                        }
                    } else {
                        GlyphButton(symbol: "trash", help: "Delete", tint: Theme.warn) {
                            staging.stage(name: entry.name, path: entry.path, size: entry.size)
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
        if DiskDeletion.canTrash(path: entry.path) {
            if isStaged {
                Button("Restore") { staging.restore(path: entry.path) }
            } else {
                Button("Delete", role: .destructive) {
                    staging.stage(name: entry.name, path: entry.path, size: entry.size)
                }
            }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
        }
    }
}

/// Small "cleanable" pill, warm so it advances against the glass.
private struct CleanableBadge: View {
    var body: some View {
        Text("cleanable")
            .font(Theme.rounded(9, .semibold))
            .kerning(0.3)
            .foregroundStyle(Theme.warn)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.warn.opacity(0.16)))
    }
}

// MARK: - Large file row

private struct LargeFileRow: View {
    let file: DiskFile
    let staging: DiskStagingModel

    private var isStaged: Bool { staging.isStaged(file.path) }

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
                    [URL(fileURLWithPath: file.path)]
                )
            }
            if DiskDeletion.canTrash(path: file.path) {
                if isStaged {
                    GlyphButton(symbol: "arrow.uturn.backward", help: "Restore", tint: .secondary) {
                        staging.restore(path: file.path)
                    }
                } else {
                    GlyphButton(symbol: "trash", help: "Delete", tint: Theme.warn) {
                        staging.stage(name: file.name, path: file.path, size: file.size)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 10)
        .opacity(isStaged ? 0.5 : 1)
        .contextMenu {
            if DiskDeletion.canTrash(path: file.path) {
                if isStaged {
                    Button("Restore") { staging.restore(path: file.path) }
                } else {
                    Button("Delete", role: .destructive) {
                        staging.stage(name: file.name, path: file.path, size: file.size)
                    }
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
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
