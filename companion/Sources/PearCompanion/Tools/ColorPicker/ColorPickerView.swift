import AppKit
import SwiftUI

/// Color picker popover: native eyedropper button, the picked color as a
/// swatch with one-click-copy formats, WCAG contrast against white/black,
/// and a small history strip. The store is created here (`@State`), so
/// nothing about the tool exists until this view is first built.
struct ColorPickerView: View {
    @State private var store = ColorStore()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            SectionLabel(text: "Color Picker")
            pickButton

            if let current = store.current {
                swatch(for: current)
                formatCard(for: current)
                contrastCard(for: current)
            } else {
                Text("Pick a color to see its formats and contrast.")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
            }

            if !store.history.isEmpty {
                historySection
            }
        }
        .padding(Theme.heroPadding)
        .frame(width: 300)
    }

    private var pickButton: some View {
        Button {
            store.pickColor()
        } label: {
            Label("Pick color", systemImage: "eyedropper")
                .font(Theme.emphasis)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
    }

    private func swatch(for color: PickedColor) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(color.swiftUIColor)
            .frame(height: 64)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.black.opacity(0.08), lineWidth: 1)
            )
    }

    private func formatCard(for color: PickedColor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FormatRow(label: "HEX", value: color.hexString, onCopy: { copy(color.hexString) })
            FormatRow(label: "RGB", value: color.rgbString, onCopy: { copy(color.rgbString) })
            FormatRow(label: "HSL", value: color.hslString, onCopy: { copy(color.hslString) })
            FormatRow(label: "SwiftUI", value: color.swiftUIString, onCopy: { copy(color.swiftUIString) })
        }
        .padding(Theme.cardPadding)
        .glassCard()
    }

    private func contrastCard(for color: PickedColor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Contrast")
            ContrastRow(label: "On White", result: color.contrast(against: .white))
            ContrastRow(label: "On Black", result: color.contrast(against: .black))
        }
        .padding(Theme.cardPadding)
        .glassCard()
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "History")
            HStack(spacing: 6) {
                ForEach(store.history) { color in
                    HistorySwatch(
                        color: color,
                        isSelected: store.current?.hexString == color.hexString,
                        onSelect: { store.select(color) },
                        onRemove: { store.remove(color) }
                    )
                }
            }
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        SoundEffects.play(.copy)
    }
}

/// One format value with a trailing copy button.
private struct FormatRow: View {
    let label: String
    let value: String
    let onCopy: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(Theme.body)
                    .monospaced()
            }
            Spacer(minLength: 8)
            GlyphButton(symbol: "doc.on.doc", help: "Copy \(label)", action: onCopy)
        }
    }
}

/// One contrast ratio plus its AA/AAA pass badges.
private struct ContrastRow: View {
    let label: String
    let result: ContrastResult

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.2f", result.ratio))
                .font(Theme.body)
                .monospaced()
            badge("AA", pass: result.passesAA)
            badge("AAA", pass: result.passesAAA)
        }
    }

    private func badge(_ text: String, pass: Bool) -> some View {
        Text(text)
            .font(Theme.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(pass ? Theme.accentSoft : Color.secondary.opacity(0.12))
            )
            .foregroundStyle(pass ? Theme.accent : .secondary)
    }
}

/// One history swatch: click re-selects, hover reveals a ✕ to remove,
/// right-click offers the same removal via context menu.
private struct HistorySwatch: View {
    let color: PickedColor
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.swiftUIColor)
                .frame(width: 28, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2)
                )
                .onTapGesture(perform: onSelect)

            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Remove", role: .destructive, action: onRemove)
        }
        .help(color.hexString)
    }
}
