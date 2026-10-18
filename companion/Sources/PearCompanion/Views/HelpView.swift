import SwiftUI

/// Every tool, grouped by category, plus the
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
        Extra(icon: "hare", title: "Menu-bar runner", hotkey: nil,
              summary: "25 runners that speed up as the CPU gets busier. Pick one in Settings › Appearance.",
              category: .system),
        Extra(icon: "keyboard", title: "Custom shortcuts", hotkey: nil,
              summary: "Change any shortcut, including the Windows snaps, in Settings › Shortcuts. Click it and press the new keys; Esc cancels, Delete removes it. Changes apply immediately.",
              category: .utilities),
        Extra(icon: "escape", title: "Esc closes anything", hotkey: "esc",
              summary: "Esc closes any Pear panel or window.",
              category: .utilities),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            HStack {
                Text("What Pear can do")
                    .font(Theme.Typography.large(.semibold))
                Spacer()
                GlyphButton(symbol: "xmark", help: "Close", tint: .secondary, action: onClose)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.large) {
                    ForEach(ToolCategory.allCases, id: \.self) { category in
                        let rows = entries(in: category)
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: Theme.Space.small) {
                                SectionLabel(text: category.title)
                                ForEach(rows.indices, id: \.self) { HelpRow(entry: rows[$0]) }
                            }
                        }
                    }
                }
                .padding(.bottom, Theme.Space.xSmall)
            }
            .frame(maxHeight: 380)
        }
        .padding(Theme.edgePadding)
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
        HStack(alignment: .top, spacing: Theme.Space.small) {
            Image(systemName: entry.icon)
                .font(.system(size: Theme.Typography.Size.large))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 20)
            VStack(alignment: .leading, spacing: 1) {  // 1 pt: the summary sits on its title, below the 4 pt step
                HStack(spacing: Theme.Space.small) {
                    Text(entry.title).font(Theme.Typography.large(.medium))
                    if let hotkey = entry.hotkey {
                        Text(hotkey)
                            .font(Theme.Typography.tiny())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.Space.xSmall)
                            .padding(.vertical, 1)  // 1 pt: the key label hugs its text, below the 4 pt step
                            .background(Capsule().fill(.quaternary.opacity(0.5)))
                    }
                }
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(Theme.Typography.small(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A flat fill, not `.glassCard`: a translucent material per row samples
        // whatever sits behind the popover (desktop, windows), so stacked rows
        // rendered at visibly different "blackness". A solid fill is identical
        // for every row and matches the app's list-row idiom (ZoneButton, ClipRow).
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}
