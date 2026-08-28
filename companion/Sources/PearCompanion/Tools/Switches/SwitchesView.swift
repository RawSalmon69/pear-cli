import SwiftUI

/// The Switches popover: a grid of quick system toggles, plus a gear that flips
/// to a per-switch show/hide list (Rule B). State is read live on open; the
/// visibility list is `@AppStorage`, so hiding a switch drops its tile with no
/// relaunch.
struct SwitchesView: View {
    @Bindable var model: SwitchesModel

    @State private var editingVisibility = false

    // Per-switch visibility, live via @AppStorage.
    @AppStorage(SwitchesSettings.showKey(.keepAwake))
    private var showKeepAwake = SystemSwitch.keepAwake.defaultVisible
    @AppStorage(SwitchesSettings.showKey(.lidClosed))
    private var showLidClosed = SystemSwitch.lidClosed.defaultVisible
    @AppStorage(SwitchesSettings.showKey(.screenSaver))
    private var showScreenSaver = SystemSwitch.screenSaver.defaultVisible
    @AppStorage(SwitchesSettings.showKey(.lockScreen))
    private var showLockScreen = SystemSwitch.lockScreen.defaultVisible
    @AppStorage(SwitchesSettings.showKey(.hideDesktop))
    private var showHideDesktop = SystemSwitch.hideDesktop.defaultVisible
    @AppStorage(SwitchesSettings.showKey(.showHidden))
    private var showShowHidden = SystemSwitch.showHidden.defaultVisible
    @AppStorage(SwitchesSettings.showKey(.bigCursor))
    private var showBigCursor = SystemSwitch.bigCursor.defaultVisible

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            header
            if editingVisibility {
                visibilityList
            } else {
                grid
            }
        }
        .padding(14)
        .frame(width: 300)
        // The popover otherwise hands first-responder to the first control,
        // drawing a focus ring on its toggle ("preselected") — same fix as the
        // Mac-row focus box.
        .focusEffectDisabled()
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack {
            Text(editingVisibility ? "Show in grid" : "Switches")
                .font(Theme.emphasis)
            Spacer()
            GlyphButton(
                symbol: editingVisibility ? "checkmark" : "gearshape",
                help: editingVisibility ? "Done" : "Choose which switches show"
            ) {
                editingVisibility.toggle()
            }
        }
    }

    // MARK: - Grid

    @ViewBuilder private var grid: some View {
        let shown = SystemSwitch.allCases.filter(isShown)
        if shown.isEmpty {
            Text("No switches shown. Tap the gear to add some.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
        } else {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(shown) { toggle in
                    SwitchTile(toggle: toggle, model: model)
                }
            }
            if isShown(.lidClosed) {
                LidClosedPanel(model: model)
            }
            if isShown(.bigCursor) {
                Text("Big Cursor writes an Accessibility setting that may need a nudge in System Settings › Accessibility › Pointer to take effect.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Visibility editor

    private var visibilityList: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            Text("System-changing switches start hidden. Turn on the ones you want.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(SystemSwitch.allCases) { toggle in
                Toggle(isOn: visibilityBinding(toggle)) {
                    Label(toggle.title, systemImage: toggle.icon)
                        .font(Theme.body)
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)
            }
        }
    }

    private func isShown(_ toggle: SystemSwitch) -> Bool {
        switch toggle {
        case .keepAwake: showKeepAwake
        case .lidClosed: showLidClosed
        case .screenSaver: showScreenSaver
        case .lockScreen: showLockScreen
        case .hideDesktop: showHideDesktop
        case .showHidden: showShowHidden
        case .bigCursor: showBigCursor
        }
    }

    private func visibilityBinding(_ toggle: SystemSwitch) -> Binding<Bool> {
        switch toggle {
        case .keepAwake: $showKeepAwake
        case .lidClosed: $showLidClosed
        case .screenSaver: $showScreenSaver
        case .lockScreen: $showLockScreen
        case .hideDesktop: $showHideDesktop
        case .showHidden: $showShowHidden
        case .bigCursor: $showBigCursor
        }
    }
}

/// Everything about Lid Closed that will not fit in a tile: the standing
/// warning, the auto-sleep deadline, and the one-time grant. Rendered only when
/// the tile is visible, which it is not on a fresh install.
private struct LidClosedPanel: View {
    @Bindable var model: SwitchesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(warning)
                .font(Theme.caption)
                .foregroundStyle(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)

            if let end = model.lidSessionEnd {
                HStack(spacing: 8) {
                    Text("Sleeps at \(end.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.caption)
                    Spacer()
                    Button("Cancel timer") { model.cancelLidSession() }
                        .font(Theme.caption)
                        .buttonStyle(.link)
                }
            } else {
                HStack(spacing: 8) {
                    Text("Sleep after")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                    Button("5 hours") { Task { await model.startLidSession(hours: 5) } }
                        .controlSize(.mini)
                    Button("12 hours") { Task { await model.startLidSession(hours: 12) } }
                        .controlSize(.mini)
                    Spacer()
                }
            }

            if model.lidRuleInstalled {
                Button("Remove password-free permission") {
                    Task { await model.removeLidPermission() }
                }
                .font(Theme.caption)
                .buttonStyle(.link)
            } else {
                Button("Grant permission once, skip the prompts") {
                    Task { await model.installLidPermission() }
                }
                .font(Theme.caption)
                .buttonStyle(.link)
            }
        }
        .padding(.top, 2)
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
        VStack(spacing: 6) {
            Image(systemName: toggle.icon)
                .font(.system(size: 20))
                .foregroundStyle(isOn ? Theme.accent : .secondary)
                .frame(height: 24)
            Text(toggle.title)
                .font(Theme.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            control
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 12)
    }

    @ViewBuilder private var control: some View {
        switch toggle.kind {
        case .toggle:
            Toggle("", isOn: stateBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.accent)
                .focusable(false)
        case .momentary:
            Button(toggle.actionLabel) { activate() }
                .font(Theme.caption)
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
        case .bigCursor: model.bigCursorOn
        case .screenSaver, .lockScreen: false
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
                case .bigCursor: Task { await model.setBigCursor(newValue) }
                case .screenSaver, .lockScreen: break
                }
            }
        )
    }

    private func activate() {
        switch toggle {
        case .screenSaver: Task { await model.launchScreenSaver() }
        case .lockScreen: model.lockScreen()
        default: break
        }
    }
}
