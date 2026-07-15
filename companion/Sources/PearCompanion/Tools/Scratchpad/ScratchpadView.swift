import SwiftUI

/// Antinote-style quick-note editor: chevrons (or ⌘[ / ⌘]) cycle notes, "+"
/// creates one, trash deletes the current one. Deleting an empty note is
/// instant; deleting one with text needs a second tap to confirm.
struct ScratchpadView: View {
    let store: ScratchpadStore
    let onClose: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            header
            editor
        }
        .padding(Theme.cardPadding)
        .frame(width: 320, height: 300)
        .glassCard(cornerRadius: 16)
    }

    private var header: some View {
        HStack(spacing: 6) {
            GlyphButton(symbol: "chevron.left", help: "Previous note (⌘[)") {
                confirmingDelete = false
                store.previous()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(store.notes.count < 2)

            Text("\(store.currentIndex + 1)/\(store.notes.count)")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 28)

            GlyphButton(symbol: "chevron.right", help: "Next note (⌘])") {
                confirmingDelete = false
                store.next()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(store.notes.count < 2)

            Spacer()

            GlyphButton(symbol: "plus", help: "New note") {
                confirmingDelete = false
                store.createNote()
            }

            GlyphButton(
                symbol: confirmingDelete ? "trash.fill" : "trash",
                help: confirmingDelete ? "Tap again to delete" : "Delete note",
                tint: confirmingDelete ? Theme.warn : .primary
            ) {
                deleteTapped()
            }

            GlyphButton(symbol: "xmark", help: "Close") {
                onClose()
            }
        }
    }

    private var editor: some View {
        TextEditor(text: textBinding)
            .font(Theme.body)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .onChange(of: store.currentIndex) { _, _ in confirmingDelete = false }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { store.currentNote.text },
            set: { store.updateText($0) }
        )
    }

    private func deleteTapped() {
        let isEmpty = store.currentNote.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEmpty || confirmingDelete {
            store.deleteCurrentNote()
            confirmingDelete = false
        } else {
            confirmingDelete = true
        }
    }
}
