import SwiftUI

/// "What can this thing do?" — every tool, grouped by category, plus the
/// always-on actions that aren't tiles. Rows come from the tool registry so
/// this can't drift from what's actually installed; the extras are the
/// handful of features that live outside the Tools grid.
struct HelpView: View {
    let known: [ToolRegistry.KnownTool]
    let onClose: () -> Void

    private struct Extra {
        let icon: String
        let title: String
        let hotkey: String?
        let summary: String
        let category: ToolCategory
    }

    // Features that aren't registry tools (no tile of their own).
    private let extras: [Extra] = [
        Extra(icon: "sparkles", title: "Clean", hotkey: nil,
              summary: "Remove caches and junk, with a live progress log.",
              category: .system),
        Extra(icon: "wind", title: "Optimize", hotkey: nil,
              summary: "Run bounded maintenance tasks.",
              category: .system),
        Extra(icon: "hare", title: "Menu-bar runner", hotkey: nil,
              summary: "A cat that runs faster as the CPU heats up. Turn it on in Settings.",
              category: .system),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            HStack {
                Text("Everything Pear can do")
                    .font(Theme.title)
                Spacer()
                GlyphButton(symbol: "xmark", help: "Close", tint: .secondary, action: onClose)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    ForEach(ToolCategory.allCases, id: \.self) { category in
                        let rows = entries(in: category)
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                SectionLabel(text: category.title)
                                ForEach(rows.indices, id: \.self) { HelpRow(entry: rows[$0]) }
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 380)
        }
        .padding(16)
        .frame(width: 340)
    }

    /// One display row, unifying registry tools and the extras.
    fileprivate struct Row: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let hotkey: String?
        let summary: String
    }

    private func entries(in category: ToolCategory) -> [Row] {
        let tools = known
            .filter { $0.category == category }
            .map { Row(icon: $0.icon, title: $0.title, hotkey: $0.hotkeyLabel, summary: $0.summary) }
        let more = extras
            .filter { $0.category == category }
            .map { Row(icon: $0.icon, title: $0.title, hotkey: $0.hotkey, summary: $0.summary) }
        return tools + more
    }
}

private struct HelpRow: View {
    let entry: HelpView.Row

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.title).font(Theme.emphasis)
                    if let hotkey = entry.hotkey {
                        Text(hotkey)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary.opacity(0.5)))
                    }
                }
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 10)
    }
}
