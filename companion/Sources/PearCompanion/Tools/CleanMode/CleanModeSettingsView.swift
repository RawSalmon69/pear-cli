import SwiftUI

/// Clean Mode's live settings, shown on its Settings page. The
/// control persists under a `cleanmode.*` key and is read at use time (on the
/// next entry), so a change applies with no relaunch.
struct CleanModeSettingsView: View {
    @AppStorage(CleanModeSettings.Key.lockKeyboard)
    private var lockKeyboard = CleanModeSettings.defaultLockKeyboard

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            Toggle("Lock keyboard", isOn: $lockKeyboard)
                .font(Theme.Typography.body())
                .toggleStyle(.switch)
                .tint(Theme.accent)

            Text("The mouse stays live. Click Done to exit.")
                .font(Theme.Typography.small(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
