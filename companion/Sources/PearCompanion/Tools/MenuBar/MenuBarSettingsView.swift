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
            howToCard
        }
        .padding(Theme.heroPadding)
        .frame(width: 300)
    }

    /// macOS exposes no way to list or pick other apps' menu-bar icons, so
    /// choosing what hides is a ⌘-drag the user does themselves. Spell it out
    /// — this is the step people miss.
    private var howToCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Choosing what hides")
            step("1.", "The chevron divider is the boundary.")
            step("2.", "Hold ⌘ and drag any menu-bar icon across it.")
            step("3.", "Left of the chevron hides; right of it always shows.")
            Text("macOS doesn't let apps move each other's icons, so this drag is manual — you only do it once.")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(n).font(Theme.caption).foregroundStyle(Theme.accent).monospacedDigit()
            Text(text).font(Theme.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
