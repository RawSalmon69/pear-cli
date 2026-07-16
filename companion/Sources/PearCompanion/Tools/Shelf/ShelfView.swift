import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The shelf's contents: a drop zone that holds files until you drag them
/// out. Files dropped anywhere on the card are copied into the shelf; rows
/// drag out as the real stored file, click to reveal in Finder, Quick Look
/// via the eye button (or space over a hovered row), and remove with ✕.
struct ShelfView: View {
    let store: ShelfStore
    let onClose: () -> Void

    @State private var isTargeted = false
    @State private var previewURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            header
            if store.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Behind the content, in front of the glass: presses that no row or
        // button claims fall through to here and drag the whole panel.
        .background { ShelfWindowMoveOverlay() }
        .glassCard(cornerRadius: 16)
        .overlay {
            // Accent ring while a drag hovers the card.
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .opacity(isTargeted ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: isTargeted)
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
        .quickLookPreview($previewURL)
    }

    private var header: some View {
        HStack(spacing: 6) {
            SectionLabel(text: "Shelf")
            if !store.items.isEmpty {
                Text("\(store.items.count)")
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            GlyphButton(symbol: "doc.on.clipboard", help: "Paste from clipboard") {
                store.ingest(from: .general)
            }
            GlyphButton(symbol: "xmark", help: "Close", action: onClose)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop files here")
                .font(Theme.emphasis)
                .foregroundStyle(.secondary)
            Text("They stay put until you drag them out.")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(store.items) { entry in
                    ShelfRow(
                        entry: entry,
                        hovering: store.hoveredID == entry.id,
                        onReveal: { reveal(entry) },
                        onPreview: { previewURL = entry.url },
                        onCopy: { store.copy(entry) },
                        onRemove: {
                            SoundEffects.play(.discard)
                            withAnimation { store.remove(entry) }
                        }
                    )
                    .onHover { store.hoveredID = $0 ? entry.id : (store.hoveredID == entry.id ? nil : store.hoveredID) }
                }
            }
        }
        .frame(maxHeight: .infinity)
        // Best-effort space-to-preview over the hovered row; the eye button is
        // the guaranteed path (space needs the panel to hold key focus).
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            let target = store.items.first { $0.id == store.hoveredID } ?? store.items.first
            guard let target else { return .ignored }
            previewURL = target.url
            return .handled
        }
    }

    private func reveal(_ entry: ShelfEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { [store] url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in store.add(url) }
            }
        }
        return handled
    }
}

/// One held file. The leading icon + name is the drag/click surface (an
/// AppKit overlay — SwiftUI `.onDrag` fails in a non-activating panel); the
/// trailing eye/✕ stay ordinary SwiftUI buttons outside that overlay.
private struct ShelfRow: View {
    let entry: ShelfEntry
    let hovering: Bool
    let onReveal: () -> Void
    let onPreview: () -> Void
    let onCopy: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                thumbnail
                Text(entry.originalName)
                    .font(Theme.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay { ShelfDragOverlay(provider: { entry.url }, onClick: onReveal) }

            if hovering {
                GlyphButton(symbol: "doc.on.doc", help: "Copy", action: onCopy)
                GlyphButton(symbol: "eye", help: "Quick Look", action: onPreview)
                GlyphButton(symbol: "xmark", help: "Remove", action: onRemove)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Theme.accentSoft : .clear)
        )
    }

    private var thumbnail: some View {
        Group {
            if let image = entry.thumbnail {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                    .resizable().scaledToFit()
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
