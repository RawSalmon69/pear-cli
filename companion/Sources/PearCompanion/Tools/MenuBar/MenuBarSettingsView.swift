import AppKit
import SwiftUI

/// Menu-bar hider popover: reveal/hide toggle, the auto-rehide interval, the
/// always-hidden zone and ⌥-reveal switches, and a short explanation of the
/// ⌘-drag arrangement the tool can't do for you.
struct MenuBarSettingsView: View {
    let manager: MenuBarManager

    /// Only surface the notch workaround on a notched Mac. macOS exposes the
    /// notch as a positive top safe-area inset; the pure decision lives on the
    /// manager so it can be tested without a live screen.
    private var hasNotch: Bool {
        MenuBarManager.displaysIncludeNotch(topSafeAreaInsets: NSScreen.screens.map(\.safeAreaInsets.top))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            SectionLabel(text: "Menu Bar")
            toggleButton
            rehideCard
            zonesCard
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
            step("1.", "The chevron is the boundary; it always stays visible.")
            step("2.", "Hold ⌘ and drag any menu-bar icon across it.")
            step("3.", "Left of the chevron hides on collapse; right always shows.")
            if manager.alwaysHiddenEnabled {
                step("4.", "Past the second divider stays hidden until ⌥-click.")
            }
            Text("macOS doesn't let apps move each other's icons, so this drag is manual — you only do it once.")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            Label("Can't see the Pear icon? Press ⌃⇧P to open this panel anytime.", systemImage: "keyboard")
                .font(Theme.caption)
                .foregroundStyle(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            if hasNotch { notchTip }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    /// An icon overflowing behind the notch can't be grabbed to drag it across
    /// the chevron. Pear can't reach it — no public API moves another app's
    /// status item — but macOS reflows the bar when the frontmost app's menu
    /// titles shrink, which frees the icon. Spell out that manual reflow.
    private var notchTip: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Stuck under the notch?", systemImage: "lightbulb")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Text("Pear can't reach an icon hidden by the notch. Click the desktop or an app with fewer menus (like Finder) so the bar reflows and the icon clears the notch, then ⌘-drag it across the chevron.")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
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

    private var zonesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            switchRow("Always-hidden zone", alwaysHiddenBinding)
            switchRow("Reveal all with ⌥-click", optionRevealBinding)
            switchRow("Show divider line", dividerLineBinding)
        }
        .padding(Theme.cardPadding)
        .glassCard()
    }

    /// A switch whose whole row toggles — a plain `Toggle("text", isOn:)` leaves
    /// the gap between the label and the switch un-tappable, so a click there
    /// does nothing. The expanding label + `contentShape` makes anywhere in the
    /// row a hit target.
    private func switchRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Text(title)
                .font(Theme.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .toggleStyle(.switch)
        .tint(Theme.accent)
        .focusable(false)
    }

    private var rehideBinding: Binding<Int> {
        Binding(get: { manager.autoRehideSeconds }, set: { manager.setAutoRehide($0) })
    }

    private var alwaysHiddenBinding: Binding<Bool> {
        Binding(get: { manager.alwaysHiddenEnabled }, set: { manager.setAlwaysHiddenEnabled($0) })
    }

    private var optionRevealBinding: Binding<Bool> {
        Binding(get: { manager.optionRevealEnabled }, set: { manager.setOptionReveal($0) })
    }

    private var dividerLineBinding: Binding<Bool> {
        Binding(get: { manager.dividerLineVisible }, set: { manager.setDividerLineVisible($0) })
    }

    private func label(for seconds: Int) -> String {
        seconds == 0 ? "Never" : "\(seconds)s"
    }
}
