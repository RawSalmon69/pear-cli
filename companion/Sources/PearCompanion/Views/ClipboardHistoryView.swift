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
                            ClipRow(
                                item: item,
                                copied: copiedID == item.id,
                                onCopy: {
                                    env.clipboard.copy(item)
                                    withAnimation { copiedID = item.id }
                                },
                                onDiscard: {
                                    SoundEffects.play(.discard)
                                    withAnimation { env.clipboard.remove(item) }
                                }
                            )
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
    let onCopy: () -> Void
    let onDiscard: () -> Void

    @State private var hovering = false
    @State private var dragX: CGFloat = 0

    private let discardThreshold: CGFloat = 80

    var body: some View {
        ZStack(alignment: .trailing) {
            // Revealed as the row slides right: a discard hint.
            HStack {
                Spacer()
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warn)
                    .padding(.trailing, 12)
                    .opacity(min(dragX / discardThreshold, 1))
            }

            Button(action: onCopy) {
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
                    if copied {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10)).foregroundStyle(Theme.accent)
                    } else if hovering {
                        Button {
                            onDiscard()
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(hovering ? Theme.accentSoft : .clear)
                )
            }
            .buttonStyle(.plain)
            .offset(x: dragX)
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        dragX = max(0, value.translation.width)
                    }
                    .onEnded { value in
                        if value.translation.width > discardThreshold {
                            withAnimation(.easeOut(duration: 0.18)) { dragX = 400 }
                            onDiscard()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { dragX = 0 }
                        }
                    }
            )
        }
        .onHover { hovering = $0 }
    }
}
