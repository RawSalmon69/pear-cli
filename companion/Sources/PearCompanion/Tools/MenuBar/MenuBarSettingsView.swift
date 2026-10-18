import AppKit
import SwiftUI

/// Menu-bar hider popover: the reveal/hide toggle, a short explanation of the
/// ⌘-drag arrangement the tool can't do for you, and a link to its Settings
/// page, where the options live (`MenuBarOptionsView`).
struct MenuBarSettingsView: View {
    let manager: MenuBarManager

    /// Only surface the notch workaround on a notched Mac. macOS exposes the
    /// notch as a positive top safe-area inset; the pure decision lives on the
    /// manager so it can be tested without a live screen.
    private var hasNotch: Bool {
        MenuBarManager.displaysIncludeNotch(topSafeAreaInsets: NSScreen.screens.map(\.safeAreaInsets.top))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.large) {
            PopoverHeader(title: "Menu Bar", settingsToolID: MenuBarTool.toolID)
            toggleButton
            howToCard
        }
        .padding(Theme.edgePadding)
        .frame(width: 300)
    }

    /// macOS exposes no way to list or pick other apps' menu-bar icons, so
    /// choosing what hides is a ⌘-drag the user does themselves. Spell it out
    /// — this is the step people miss.
    private var howToCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            SectionLabel(text: "Choosing what hides")
            step("1.", "The chevron is the boundary; it always stays visible.")
            step("2.", "Hold ⌘ and drag any menu-bar icon across it.")
            step("3.", "Left of the chevron hides on collapse; right always shows.")
            if manager.alwaysHiddenEnabled {
                step("4.", "Past the second divider stays hidden until ⌥-click.")
            }
            Text("macOS does not let apps move each other's icons, so you drag this one yourself. Once is enough.")
                .font(Theme.Typography.small(.semibold))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Space.xSmall)
            Label("Can't see the Pear icon? Press ⌃⇧P to open this panel anytime.", systemImage: "keyboard")
                .font(Theme.Typography.small(.semibold))
                .foregroundStyle(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Space.xSmall)
            if hasNotch { notchTip }
        }
        .padding(Theme.Space.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A flat fill, not glass: the card sits on the popover's own glass.
        .flatSurface()
    }

    /// An icon overflowing behind the notch can't be grabbed to drag it across
    /// the chevron. Pear can't reach it — no public API moves another app's
    /// status item — but macOS reflows the bar when the frontmost app's menu
    /// titles shrink, which frees the icon. Spell out that manual reflow.
    private var notchTip: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xSmall) {
            Label("Stuck under the notch?", systemImage: "lightbulb")
                .font(Theme.Typography.small(.semibold))
                .foregroundStyle(.secondary)
            Text("Pear can't reach an icon hidden by the notch. Click the desktop or an app with fewer menus (like Finder) so the bar reflows and the icon clears the notch, then ⌘-drag it across the chevron.")
                .font(Theme.Typography.small(.semibold))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Space.xSmall)
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
            Text(n).font(Theme.Typography.small(.semibold)).foregroundStyle(Theme.accent).monospacedDigit()
            Text(text).font(Theme.Typography.small(.semibold)).foregroundStyle(.secondary)
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
                .font(Theme.Typography.large(.medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
    }
}

/// The menu-bar hider's options, on its Settings page: the auto-rehide
/// interval, the always-hidden zone, ⌥-reveal and the divider line. Bound to
/// the tool's live manager, so each applies at once.
struct MenuBarOptionsView: View {
    let manager: MenuBarManager

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.large) {
            rehideSection
            zonesSection
        }
    }

    private var rehideSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            SectionLabel(text: "Auto-hide after")
            Picker("Auto-hide after", selection: rehideBinding) {
                ForEach(MenuBarManager.autoRehideOptions, id: \.self) { seconds in
                    Text(label(for: seconds)).tag(seconds)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
        }
    }

    private var zonesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            SectionLabel(text: "Zones")
            switchRow("Always-hidden zone", alwaysHiddenBinding)
            switchRow("Reveal all with ⌥-click", optionRevealBinding)
            switchRow("Show divider line", dividerLineBinding)
        }
        .frame(maxWidth: 320)
    }

    /// A switch whose whole row toggles — a plain `Toggle("text", isOn:)` leaves
    /// the gap between the label and the switch un-tappable, so a click there
    /// does nothing. The expanding label + `contentShape` makes anywhere in the
    /// row a hit target.
    private func switchRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Text(title)
                .font(Theme.Typography.body())
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
