import SwiftUI

/// Settings surface for the menu-bar runner. A single toggle bound to the
/// live `RunnerModel`, so flipping it starts/stops the animation immediately
/// (and persists to UserDefaults through the model's `isEnabled` setter).
///
/// Drop this into `SettingsPopover` as its own section. It takes the model so
/// there is one source of truth — the same instance the menu-bar label reads.
struct RunnerSettingsView: View {
    @Bindable var runner: RunnerModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Menu bar")
            Text("A little cat runs in the menu bar — faster as the CPU heats up.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Toggle("Running cat in the menu bar", isOn: $runner.isEnabled)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)
        }
    }
}
