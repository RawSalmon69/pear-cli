import SwiftUI
import AppKit

/// Popover list of recent clipboard entries; click one to put it back on the
/// clipboard. Text and image clips, newest first.
struct ClipboardHistoryView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var copiedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            HStack {
                SectionLabel(text: "Clipboard")
                Spacer()
                if !env.clipboard.items.isEmpty {
                    Button("Clear") { env.clipboard.clear() }
                        .buttonStyle(.plain)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if env.clipboard.items.isEmpty {
                Text("Nothing copied yet. Anything you copy shows up here.")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(env.clipboard.items) { item in
                            ClipRow(item: item, copied: copiedID == item.id) {
                                env.clipboard.copy(item)
                                withAnimation { copiedID = item.id }
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let copied: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let data = item.imageData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable().scaledToFill()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Text("Image").font(Theme.body).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 30)
                    Text(item.text ?? "")
                        .font(Theme.body)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: copied ? "checkmark" : "arrow.up.doc.on.clipboard")
                    .font(.system(size: 10))
                    .foregroundStyle(copied ? Theme.accent : (hovering ? .secondary : .clear))
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovering ? Theme.accentSoft : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
