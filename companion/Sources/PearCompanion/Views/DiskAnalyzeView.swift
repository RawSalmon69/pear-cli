import SwiftUI
import AppKit

/// Disk tool popover: a two-mode explorer.
///
/// Both modes — sunburst and treemap — are drawn from one native, off-main disk
/// scan (`Tools/Disk`, engine vendored from Radix). Nothing here shells out.
/// Fits a ~380 pt menu-bar panel.
struct DiskAnalyzeView: View {
    /// Treemap first: its tiles are labelled with name and size, so it is the
    /// one mode you can read numbers off without hovering.
    @State private var mode: DiskViewMode = .treemap
    /// The two-phase deletion pile, shared across both modes so the pending
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

            DiskChartView(style: mode == .treemap ? .treemap : .sunburst,
                          staging: staging, model: scanModel)

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

/// The view modes offered by the Disk tool.
enum DiskViewMode: String, CaseIterable, Identifiable {
    case treemap
    case sunburst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .treemap: return "Treemap"
        case .sunburst: return "Sunburst"
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
