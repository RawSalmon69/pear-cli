import SwiftUI

/// Clean Mode's live settings, shown under its row in the Tools tab. The
/// control persists under a `cleanmode.*` key and is read at use time (on the
/// next entry), so a change applies with no relaunch.
struct CleanModeSettingsView: View {
    @AppStorage(CleanModeSettings.Key.lockKeyboard)
    private var lockKeyboard = CleanModeSettings.defaultLockKeyboard

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            Toggle("Lock keyboard", isOn: $lockKeyboard)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)

            Text("The mouse always stays live — click Done to exit.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
