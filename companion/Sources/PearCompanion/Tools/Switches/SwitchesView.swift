import SwiftUI

/// The Switches popover: a grid of quick system toggles, plus a gear that flips
/// to a per-switch show/hide list (Rule B). State is read live on open; the
/// visibility list is `@AppStorage`, so hiding a switch drops its tile with no
/// relaunch.
struct SwitchesView: View {
    @Bindable var model: SwitchesModel

    @State private var editingVisibility = false

    // Per-switch visibility, live via @AppStorage (DockDoor pattern).
    @AppStorage(SwitchesSettings.showKey(.keepAwake))
    private var showKeepAwake = SystemSwitch.keepAwake.defaultVisible
    @AppStorage(SwitchesSettings.showKey(.mute))
    private var showMute = SystemSwitch.mute.defaultVisible
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
        case .mute: showMute
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
        case .mute: $showMute
        case .screenSaver: $showScreenSaver
        case .lockScreen: $showLockScreen
        case .hideDesktop: $showHideDesktop
        case .showHidden: $showShowHidden
        case .bigCursor: $showBigCursor
        }
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
        case .mute: model.muteOn
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
                case .mute: model.setMute(newValue)
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
