import SwiftUI

/// Settings surface for the menu-bar runner: the on/off toggle, a grid to pick
/// the runner, and an optional CPU-percentage readout. All bound to the live
/// `RunnerModel`, so changes take effect immediately and persist through the
/// model's setters.
///
/// Drop this into `SettingsPopover` as its own section. It takes the model so
/// there is one source of truth — the same instance the menu-bar label reads.
struct RunnerSettingsView: View {
    @Bindable var runner: RunnerModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Menu bar")
            Text("A little runner in the menu bar — faster as the CPU heats up.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)

            Toggle("Show a runner in the menu bar", isOn: $runner.isEnabled)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)

            RunnerGrid(selection: runner.style) { runner.style = $0 }
                .disabled(!runner.isEnabled)
                .opacity(runner.isEnabled ? 1 : 0.5)

            Toggle("Show CPU %", isOn: $runner.showsCPU)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .disabled(!runner.isEnabled)
        }
    }
}

/// A compact, scrollable grid of every discovered runner — one cell per runner
/// showing its first frame and name, the selected one ringed in the accent.
/// Sized to fit the ~300 pt settings popover: small cells, three per row, with
/// its own bounded scroll so a full 25-runner gallery never blows out the sheet.
private struct RunnerGrid: View {
    let selection: RunnerStyle
    let onSelect: (RunnerStyle) -> Void

    /// Discovered once; the list is stable for the app's lifetime.
    private let styles = RunnerStyle.all
    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(styles) { style in
                    RunnerCell(style: style, selected: style == selection) {
                        onSelect(style)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 180)
    }
}

/// One runner in the picker grid: its first frame drawn as a template image (so
/// it tints to the menu-bar look) above the runner's name, wrapped in a tappable
/// tile that rings itself in the accent when selected.
private struct RunnerCell: View {
    let style: RunnerStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(nsImage: style.previewFrame())
                    .renderingMode(.template)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 56, maxHeight: 22)
                    .foregroundStyle(.primary)
                Text(style.name)
                    .font(Theme.caption)
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Theme.accentSoft : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(style.name)
    }
}
