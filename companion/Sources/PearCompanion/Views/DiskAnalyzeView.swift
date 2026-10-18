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
        VStack(alignment: .leading, spacing: Theme.Space.small) {
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
        .padding(Theme.Space.large)
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
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            HStack(spacing: Theme.Space.xSmall) {
                SectionLabel(text: "Pending deletion")
                Spacer(minLength: Theme.Space.xSmall)
                Text("\(staging.count) · \(ByteFormat.si(staging.totalSize))")
                    .font(Theme.Typography.small(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ScrollView {
                VStack(spacing: Theme.Space.xSmall) {
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
        .padding(Theme.Space.medium)
        .glassCard(cornerRadius: Theme.Radius.medium)
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
        HStack(spacing: Theme.Space.small) {
            Image(systemName: "trash")
                .font(Theme.Typography.tiny())
                .foregroundStyle(Theme.warn)
            Text(item.name)
                .font(Theme.Typography.body())
                .strikethrough(true, color: .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.xSmall)
            Text(ByteFormat.si(item.size))
                .font(Theme.Typography.small(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            GlyphButton(symbol: "magnifyingglass", help: "Reveal in Finder", tint: .secondary) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
            GlyphButton(symbol: "arrow.uturn.backward", help: "Restore", tint: .secondary) {
                staging.restore(path: item.path)
            }
        }
        .padding(.horizontal, Theme.Space.small)
        .padding(.vertical, Theme.Space.xSmall)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Restore") { staging.restore(path: item.path) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
        }
    }
}
