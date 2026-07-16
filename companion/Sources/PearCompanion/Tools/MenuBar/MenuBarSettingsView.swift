import SwiftUI

/// Menu-bar hider popover: reveal/hide toggle, the auto-rehide interval, and a
/// one-line explanation of the ⌘-drag positioning the tool can't do for you.
struct MenuBarSettingsView: View {
    let manager: MenuBarManager

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            SectionLabel(text: "Menu Bar")
            toggleButton
            rehideCard
            Text("⌘-drag menu bar icons to the divider's left to hide them, or to its right to keep them showing.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.heroPadding)
        .frame(width: 280)
    }

    private var toggleButton: some View {
        Button {
            manager.toggle()
        } label: {
            Label(
                manager.isCollapsed ? "Reveal icons" : "Hide icons",
                systemImage: manager.isCollapsed ? "eye" : "eye.slash")
                .font(Theme.emphasis)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
    }

    private var rehideCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Auto-hide after")
            Picker("", selection: rehideBinding) {
                ForEach(MenuBarManager.autoRehideOptions, id: \.self) { seconds in
                    Text(label(for: seconds)).tag(seconds)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .padding(Theme.cardPadding)
        .glassCard()
    }

    private var rehideBinding: Binding<Int> {
        Binding(get: { manager.autoRehideSeconds }, set: { manager.setAutoRehide($0) })
    }

    private func label(for seconds: Int) -> String {
        seconds == 0 ? "Never" : "\(seconds)s"
    }
}
