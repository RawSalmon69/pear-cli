import AppKit
import SwiftUI

/// Color picker popover: native eyedropper button, the picked color as a
/// swatch with one-click-copy formats, WCAG contrast against white/black,
/// and a small history strip. The store is created here (`@State`), so
/// nothing about the tool exists until this view is first built. The format
/// a pick copies is chosen on the tool's Settings page (`ColorFormatPicker`).
struct ColorPickerView: View {
    @State private var store = ColorStore()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.large) {
            PopoverHeader(title: "Color Picker", settingsToolID: ColorPickerTool.toolID)
            pickButton

            if let current = store.current {
                swatch(for: current)
                formatCard(for: current)
                contrastCard(for: current)
            } else {
                Text("Pick a color to see its formats and contrast.")
                    .font(Theme.Typography.body())
                    .foregroundStyle(.secondary)
            }

            if !store.history.isEmpty {
                historySection
            }
        }
        .padding(Theme.edgePadding)
        .frame(width: 300)
    }

    private var pickButton: some View {
        Button {
            store.pickColor(copy: true)
        } label: {
            Label("Pick color", systemImage: "eyedropper")
                .font(Theme.Typography.large(.medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
    }

    private func swatch(for color: PickedColor) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.medium)
            .fill(color.swiftUIColor)
            .frame(height: 64)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .strokeBorder(.black.opacity(0.08), lineWidth: 1)
            )
    }

    private func formatCard(for color: PickedColor) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            FormatRow(label: "HEX", value: color.hexString, onCopy: { copy(color.hexString) })
            FormatRow(label: "RGB", value: color.rgbString, onCopy: { copy(color.rgbString) })
            FormatRow(label: "HSL", value: color.hslString, onCopy: { copy(color.hslString) })
            FormatRow(label: "SwiftUI", value: color.swiftUIString, onCopy: { copy(color.swiftUIString) })
        }
        .padding(Theme.Space.medium)
        // A flat fill, not glass: the card sits on the popover's own glass.
        .flatSurface()
    }

    private func contrastCard(for color: PickedColor) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            SectionLabel(text: "Contrast")
            ContrastRow(label: "On White", result: color.contrast(against: .white))
            ContrastRow(label: "On Black", result: color.contrast(against: .black))
        }
        .padding(Theme.Space.medium)
        // A flat fill, not glass: the card sits on the popover's own glass.
        .flatSurface()
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            SectionLabel(text: "History")
            HStack(spacing: Theme.Space.small) {
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

/// Which format the eyedropper copies to the clipboard, on the tool's Settings
/// page. Live — the pick button and the global hotkey both read `Prefs.colorFormat`.
struct ColorFormatPicker: View {
    @AppStorage(Prefs.colorFormatKey) private var copyFormat = ColorFormat.hex.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            SectionLabel(text: "Pick copies")
            Picker("Pick copies", selection: $copyFormat) {
                ForEach(ColorFormat.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
        }
    }
}

/// One format value with a trailing copy button.
private struct FormatRow: View {
    let label: String
    let value: String
    let onCopy: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {  // 1 pt: the label sits on its value, below the 4 pt step
                Text(label)
                    .font(Theme.Typography.small(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(Theme.Typography.body())
                    .monospaced()
            }
            Spacer(minLength: Theme.Space.small)
            GlyphButton(symbol: "doc.on.doc", help: "Copy \(label)", action: onCopy)
        }
    }
}

/// One contrast ratio plus its AA/AAA pass badges.
private struct ContrastRow: View {
    let label: String
    let result: ContrastResult

    var body: some View {
        HStack(spacing: Theme.Space.small) {
            Text(label)
                .font(Theme.Typography.small(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.2f", result.ratio))
                .font(Theme.Typography.body())
                .monospaced()
            badge("AA", pass: result.passesAA)
            badge("AAA", pass: result.passesAAA)
        }
    }

    private func badge(_ text: String, pass: Bool) -> some View {
        Text(text)
            .font(Theme.Typography.small(.semibold))
            .padding(.horizontal, Theme.Space.small)
            .padding(.vertical, 2)  // 2 pt: the badge hugs its text, below the 4 pt step
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
            RoundedRectangle(cornerRadius: Theme.Radius.small)
                .fill(color.swiftUIColor)
                .frame(width: 28, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.small)
                        .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2)
                )
                .onTapGesture(perform: onSelect)

            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Typography.small())
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)  // 6 pt: centres the remove badge on the swatch corner
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Remove", role: .destructive, action: onRemove)
        }
        .help(color.hexString)
    }
}
