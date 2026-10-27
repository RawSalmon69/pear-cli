import SwiftUI

/// The Switches popover: a grid of quick system toggles and a link to the
/// tool's Settings page, which holds the per-switch show/hide list (Rule B,
/// `SwitchesVisibilityView`). State is read live on open; visibility is
/// `@AppStorage`, so hiding a switch drops its tile with no relaunch.
struct SwitchesView: View {
    @Bindable var model: SwitchesModel

    // Per-switch visibility, live via @AppStorage.
    @AppStorage(SwitchesSettings.showKey(.keepAwake))
    private var showKeepAwake = SystemSwitch.keepAwake.defaultVisible
    @AppStorage(SwitchesSettings.showKey(.lidClosed))
    private var showLidClosed = SystemSwitch.lidClosed.defaultVisible
    @AppStorage(SwitchesSettings.showKey(.screenSaver))
    private var showScreenSaver = SystemSwitch.screenSaver.defaultVisible
    @AppStorage(SwitchesSettings.showKey(.lockScreen))
    private var showLockScreen = SystemSwitch.lockScreen.defaultVisible
    @AppStorage(SwitchesSettings.showKey(.displayOff))
    private var showDisplayOff = SystemSwitch.displayOff.defaultVisible
    @AppStorage(SwitchesSettings.showKey(.hideDesktop))
    private var showHideDesktop = SystemSwitch.hideDesktop.defaultVisible
    @AppStorage(SwitchesSettings.showKey(.showHidden))
    private var showShowHidden = SystemSwitch.showHidden.defaultVisible
    @AppStorage(SwitchesSettings.showKey(.showExtensions))
    private var showShowExtensions = SystemSwitch.showExtensions.defaultVisible

    private let columns = [GridItem(.flexible(), spacing: Theme.Space.medium),
                           GridItem(.flexible(), spacing: Theme.Space.medium)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            PopoverHeader(title: "Switches", settingsToolID: SwitchesTool.toolID)
            grid
        }
        .padding(Theme.edgePadding)
        .frame(width: 300)
        // The popover otherwise hands first-responder to the first control,
        // drawing a focus ring on its toggle ("preselected") — same fix as the
        // Mac-row focus box.
        .focusEffectDisabled()
        .task { await model.refresh() }
    }

    // MARK: - Grid

    @ViewBuilder private var grid: some View {
        let shown = SystemSwitch.allCases.filter(isShown)
        if shown.isEmpty {
            Text("No switches shown. Choose some in Settings.")
                .font(Theme.Typography.small(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Space.medium)
        } else {
            LazyVGrid(columns: columns, spacing: Theme.Space.medium) {
                ForEach(shown) { toggle in
                    SwitchTile(toggle: toggle, model: model)
                }
            }
            if isShown(.lidClosed) {
                LidClosedPanel(model: model)
            }
        }
    }

    private func isShown(_ toggle: SystemSwitch) -> Bool {
        switch toggle {
        case .keepAwake: showKeepAwake
        case .lidClosed: showLidClosed
        case .screenSaver: showScreenSaver
        case .lockScreen: showLockScreen
        case .displayOff: showDisplayOff
        case .hideDesktop: showHideDesktop
        case .showHidden: showShowHidden
        case .showExtensions: showShowExtensions
        }
    }
}

/// Which switches show in the grid, on the tool's Settings page. Each row owns
/// its `switches.show.*` key through `@AppStorage`, so the grid follows live.
struct SwitchesVisibilityView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            SectionLabel(text: "Show in grid")
            Text("System-changing switches start hidden. Turn on the ones you want.")
                .font(Theme.Typography.small(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(SystemSwitch.allCases) { VisibilityRow(toggle: $0) }
        }
    }

    private struct VisibilityRow: View {
        let toggle: SystemSwitch
        @AppStorage private var shown: Bool

        init(toggle: SystemSwitch) {
            self.toggle = toggle
            _shown = AppStorage(wrappedValue: toggle.defaultVisible, SwitchesSettings.showKey(toggle))
        }

        var body: some View {
            Toggle(isOn: $shown) {
                Label(toggle.title, systemImage: toggle.icon)
                    .font(Theme.Typography.body())
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
        }
    }
}

/// Everything about Lid Closed that will not fit in a tile: the standing
/// warning, the auto-sleep deadline, and the one-time grant. Rendered only when
/// the tile is visible, which it is not on a fresh install.
private struct LidClosedPanel: View {
    @Bindable var model: SwitchesModel
    @State private var showsCustom = false
    /// Starts at the last custom duration (`Prefs`), saved again on Start.
    @State private var customMinutes = Prefs.lidCustomMinutes()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            Text(warning)
                .font(Theme.Typography.small(.semibold))
                .foregroundStyle(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)

            if let end = model.lidSessionEnd {
                HStack(spacing: Theme.Space.small) {
                    Text("Sleeps at \(end.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.Typography.small(.semibold))
                    Spacer()
                    Button("Cancel timer") { model.cancelLidSession() }
                        .font(Theme.Typography.small(.semibold))
                        .buttonStyle(.link)
                }
            } else {
                HStack(spacing: Theme.Space.small) {
                    Text("Sleep after")
                        .font(Theme.Typography.small(.semibold))
                        .foregroundStyle(.secondary)
                    Button("5 hours") { Task { await model.startLidSession(hours: 5) } }
                        .controlSize(.mini)
                    Button("12 hours") { Task { await model.startLidSession(hours: 12) } }
                        .controlSize(.mini)
                    Button("Custom…") { showsCustom.toggle() }
                        .controlSize(.mini)
                    Spacer()
                }
                if showsCustom {
                    // A stepper over quarter-hours cannot hold an invalid value.
                    HStack(spacing: Theme.Space.small) {
                        Stepper(LidTimer.label(minutes: customMinutes), value: $customMinutes,
                                in: LidTimer.range, step: LidTimer.step)
                            .font(Theme.Typography.small(.semibold))
                            .controlSize(.mini)
                        Spacer()
                        Button("Start") {
                            let minutes = customMinutes
                            Prefs.setLidCustomMinutes(minutes)
                            showsCustom = false
                            Task { await model.startLidSession(hours: Double(minutes) / 60) }
                        }
                        .controlSize(.mini)
                    }
                }
            }

            if model.lidRuleInstalled {
                Button("Remove password-free permission") {
                    Task { await model.removeLidPermission() }
                }
                .font(Theme.Typography.small(.semibold))
                .buttonStyle(.link)
            } else {
                Button("Grant permission once, skip the prompts") {
                    Task { await model.installLidPermission() }
                }
                .font(Theme.Typography.small(.semibold))
                .buttonStyle(.link)
            }
        }
        .padding(.top, Theme.Space.xSmall)
    }

    /// Says less once the two escape hatches are in place, because with a
    /// deadline set and the grant installed the machine really does put itself
    /// back. What survives in every case is the crash.
    private var warning: String {
        if model.lidRuleInstalled {
            return "Lid Closed turns off sleep for the whole system, so a closed lid keeps running warm"
                + " and draining. Quitting Pear and the timer above both restore it; a crash cannot."
        }
        return "Lid Closed asks for your admin password and turns off sleep for the whole system, so a"
            + " closed lid keeps running warm and draining. It stays off after Pear quits unless you"
            + " grant permission below. Turn it back off when you are done."
    }
}

/// One grid cell. Stateful switches show a switch control; momentary ones a
/// button. Icon tints to the accent while a toggle is on.
private struct SwitchTile: View {
    let toggle: SystemSwitch
    @Bindable var model: SwitchesModel

    var body: some View {
        VStack(spacing: Theme.Space.small) {
            Image(systemName: toggle.icon)
                .font(Theme.Typography.title())
                .foregroundStyle(isOn ? Theme.accent : .secondary)
                .frame(height: 24)
            Text(toggle.title)
                .font(Theme.Typography.small(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            control
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.medium)
        // A flat fill, not glass: the tile sits on the popover's own glass.
        .flatSurface()
    }

    @ViewBuilder private var control: some View {
        switch toggle.kind {
        case .toggle:
            Toggle(toggle.title, isOn: stateBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.accent)
                .focusable(false)
        case .momentary:
            Button(toggle.actionLabel) { activate() }
                .font(Theme.Typography.small(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focusable(false)
        }
    }

    private var isOn: Bool {
        switch toggle {
        case .keepAwake: model.keepAwakeOn
        case .lidClosed: model.lidClosedOn
        case .hideDesktop: model.hideDesktopOn
        case .showHidden: model.showHiddenOn
        case .showExtensions: model.showExtensionsOn
        case .screenSaver, .lockScreen, .displayOff: false
        }
    }

    private var stateBinding: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { newValue in
                switch toggle {
                case .keepAwake: model.setKeepAwake(newValue)
                case .lidClosed: Task { await model.setLidClosed(newValue) }
                case .hideDesktop: Task { await model.setHideDesktop(newValue) }
                case .showHidden: Task { await model.setShowHidden(newValue) }
                case .showExtensions: Task { await model.setShowExtensions(newValue) }
                case .screenSaver, .lockScreen, .displayOff: break
                }
            }
        )
    }

    private func activate() {
        switch toggle {
        case .screenSaver: Task { await model.launchScreenSaver() }
        case .lockScreen: model.lockScreen()
        case .displayOff: Task { await model.displayOff() }
        default: break
        }
    }
}
