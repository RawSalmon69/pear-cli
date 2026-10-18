import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The shelf's contents: a drop zone that holds files until you drag them
/// out. Files dropped anywhere on the card are copied into the shelf; rows
/// drag out as the real stored file, click to reveal in Finder, Quick Look
/// via the eye button (or Space, handled by the window controller), convert
/// images, and remove with ✕.
struct ShelfView: View {
    let store: ShelfStore
    let onClose: () -> Void
    /// Toggles the system Quick Look panel for an entry.
    let onPreview: (ShelfEntry) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            header
            if store.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .padding(Theme.edgePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Behind the content, in front of the glass: presses that no row or
        // button claims fall through to here and drag the whole panel.
        .background { ShelfWindowMoveOverlay() }
        .glassCard()
        .overlay {
            // Accent ring while a drag hovers the card.
            RoundedRectangle(cornerRadius: Theme.Radius.large)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .opacity(isTargeted ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: isTargeted)
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.small) {
            SectionLabel(text: "Shelf")
            if !store.items.isEmpty {
                Text("\(store.items.count)")
                    .font(Theme.Typography.small(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            GlyphButton(symbol: "doc.on.clipboard", help: "Paste from clipboard") {
                Task { await store.ingest(from: .general) }
            }
            GlyphButton(symbol: "xmark", help: "Close", action: onClose)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.medium) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 30, weight: .light))  // 30 pt: an illustration glyph, not text
                .foregroundStyle(.secondary)
            Text("Drop files here")
                .font(Theme.Typography.large(.medium))
                .foregroundStyle(.secondary)
            Text("They stay put until you drag them out.")
                .font(Theme.Typography.small(.semibold))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: Theme.Space.xSmall) {
                ForEach(store.items) { entry in
                    ShelfRow(
                        entry: entry,
                        hovering: store.hoveredID == entry.id,
                        onReveal: { reveal(entry) },
                        onPreview: { onPreview(entry) },
                        onCopy: { store.copy(entry) },
                        onRemoveBackground: { store.removeBackground(entry) },
                        onConvert: { kind in Task { await store.convert(entry, to: kind) } },
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
                Task { @MainActor in await store.add(url) }
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
    let onRemoveBackground: () -> Void
    let onConvert: (ShelfConversion) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.small) {
            HStack(spacing: Theme.Space.small) {
                thumbnail
                Text(entry.originalName)
                    .font(Theme.Typography.body())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay { ShelfDragOverlay(provider: { entry.url }, onClick: onReveal) }

            if hovering {
                GlyphButton(symbol: "doc.on.doc", help: "Copy", action: onCopy)
                if entry.isImage {
                    GlyphButton(
                        symbol: "person.and.background.dotted",
                        help: "Remove background", action: onRemoveBackground)
                    GlyphButton(symbol: "arrow.triangle.2.circlepath", help: "Convert") {
                        ConvertMenu.pop(for: entry.url, convert: onConvert)
                    }
                    .accessibilityLabel("Convert")
                }
                GlyphButton(symbol: "eye", help: "Quick Look", action: onPreview)
                GlyphButton(symbol: "xmark", help: "Remove", action: onRemove)
            }
        }
        .padding(Theme.Space.small)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small)
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
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
    }
}

/// The Convert choices as a native menu at the pointer. `popUp` blocks until
/// the menu closes, so the row hiding its hover buttons meanwhile can't drop
/// the pick (a SwiftUI `Menu` would vanish with them).
@MainActor
private final class ConvertMenu: NSObject {
    private let kinds: [ShelfConversion]
    private let convert: (ShelfConversion) -> Void

    private init(kinds: [ShelfConversion], convert: @escaping (ShelfConversion) -> Void) {
        self.kinds = kinds
        self.convert = convert
    }

    static func pop(for url: URL, convert: @escaping (ShelfConversion) -> Void) {
        let target = ConvertMenu(kinds: ShelfConversion.available(for: url), convert: convert)
        let menu = NSMenu()
        for (index, kind) in target.kinds.enumerated() {
            let item = NSMenuItem(title: kind.title, action: #selector(fire(_:)), keyEquivalent: "")
            item.target = target
            item.tag = index
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func fire(_ sender: NSMenuItem) {
        convert(kinds[sender.tag])
    }
}
