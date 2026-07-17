import SwiftUI

/// Clean Mode's live settings, shown under its row in the Tools tab. Both
/// controls persist under a `cleanmode.*` key and are read at use time (on the
/// next entry), so a change applies with no relaunch.
struct CleanModeSettingsView: View {
    @AppStorage(CleanModeSettings.Key.timeout)
    private var timeout = CleanModeSettings.defaultTimeout.rawValue
    @AppStorage(CleanModeSettings.Key.lockKeyboard)
    private var lockKeyboard = CleanModeSettings.defaultLockKeyboard

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            Picker("Auto-exit after", selection: $timeout) {
                ForEach(CleanModeTimeout.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .font(Theme.body)

            Toggle("Lock keyboard", isOn: $lockKeyboard)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)

            Text("The mouse always stays live — click Done or wait for the timer to exit.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
