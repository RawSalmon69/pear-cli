import SwiftUI

/// Settings surface for the menu-bar runner: the on/off toggle, a picker for the
/// runner style, and an optional CPU-percentage readout. All bound to the live
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

            Picker("Runner", selection: $runner.style) {
                ForEach(RunnerStyle.allCases) { style in
                    Text(style.name).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Theme.accent)
            .disabled(!runner.isEnabled)

            Toggle("Show CPU %", isOn: $runner.showsCPU)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .disabled(!runner.isEnabled)
        }
    }
}
