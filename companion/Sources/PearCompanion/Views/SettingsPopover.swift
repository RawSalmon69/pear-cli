import SwiftUI
import AppKit

/// Settings, split into a few tabs so a dozen tools' worth of controls read
/// as small groups instead of one long scroll. General = look and capture,
/// Tools = per-tool on/off, Menu Bar = the runner, Licence = trial and key.
struct SettingsPopover: View {
    @Environment(AppEnvironment.self) private var env
    @State private var tab: Tab
    @State private var showAccentWheel = false
    @State private var keyField = ""
    @State private var role = CoupleKey.deviceRole
    @State private var keyStatus: String?
    @State private var folder = ScreenshotNaming.folder(
        defaults: .standard,
        home: FileManager.default.homeDirectoryForCurrentUser
    ).path
    @AppStorage(Prefs.soundsKey) private var soundsEnabled = true
    @AppStorage(Prefs.autoSaveKey) private var autoSave = true
    @AppStorage(Prefs.previewAutoDismissKey) private var previewAutoDismiss = false
    @AppStorage(Prefs.previewAutoDismissSecondsKey) private var previewAutoDismissSeconds = 6.0
    @AppStorage(Prefs.previewMaxStackKey) private var previewMaxStack = 5
    @AppStorage(Prefs.panelClosesOnFocusLossKey) private var panelClosesOnFocusLoss = true
    @AppStorage(Prefs.hdBackgroundRemovalKey) private var hdEnabled = false
    @State private var hd = HDBackgroundModelManager.shared

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", tools = "Tools", menuBar = "Menu Bar", licence = "Licence"
        var id: String { rawValue }

        /// The tabs actually offered. Licence is hidden while the app is free:
        /// with `FeatureFlags.paywall` off nothing locks and the trial clock
        /// never starts, so the pane would sit there reporting "14 days left"
        /// forever and inviting people to buy something that is not for sale.
        static var visible: [Tab] {
            allCases.filter { FeatureFlags.paywall || $0 != .licence }
        }
    }

    /// Opens on `tab`. The locked state passes `.licence`, so "I have a licence"
    /// lands on the field instead of on General.
    init(tab: Tab = .general) {
        // A caller asking for a hidden tab gets General rather than a blank pane.
        _tab = State(initialValue: Tab.visible.contains(tab) ? tab : .general)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            Picker("", selection: $tab) {
                ForEach(Tab.visible) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    switch tab {
                    case .general: generalTab
                    case .tools: toolsTab
                    case .menuBar: RunnerSettingsView(runner: env.runner)
                    case .licence:
                        // Unreachable while free (the tab is not offered), but a
                        // stored selection could still name it.
                        if FeatureFlags.paywall { LicenceSettingsView() } else { generalTab }
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 360)
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder private var backgroundRemovalSection: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Background removal")
            Toggle("High-quality mode", isOn: $hdEnabled)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .onChange(of: hdEnabled) { _, _ in hd.prepare() }
            Text(hdEnabled
                ? "On-device AI model for remove.bg-class cutouts (hair, fine edges). One-time \(HDBackgroundModelManager.downloadSizeText) download; fully offline after."
                : "Apple's built-in cutout is instant and needs no download. Turn this on for sharper edges, after a one-time \(HDBackgroundModelManager.downloadSizeText) download.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if hdEnabled { hdStatusRow }
        }
    }

    @ViewBuilder private var hdStatusRow: some View {
        switch hd.state {
        case .absent:
            Button("Download model (\(HDBackgroundModelManager.downloadSizeText))") { hd.download() }
                .font(Theme.caption)
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction).tint(Theme.accent)
                Text(hd.progressText ?? "Downloading…")
                    .font(Theme.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing…").font(Theme.caption).foregroundStyle(.secondary)
            }
        case .ready:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Ready · high quality").font(Theme.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Remove") { hd.remove() }
                    .font(Theme.caption)
                    .help("Delete the model and its compiled copy")
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(Theme.caption).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { hd.download() }.font(Theme.caption)
            }
        }
    }

    @ViewBuilder private var generalTab: some View {
        if FeatureFlags.coupleNote {
            coupleKeySection
        }

        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Accent")
            HStack(spacing: 8) {
                ForEach(AccentPreset.allCases) { preset in
                    AccentSwatch(
                        preset: preset,
                        selected: ThemeStore.shared.custom == nil && ThemeStore.shared.preset == preset
                    ) {
                        ThemeStore.shared.custom = nil
                        ThemeStore.shared.preset = preset
                    }
                }
                // Not a SwiftUI ColorPicker (its NSColorPanel dismisses this
                // transient popover, killing the binding) and not the system
                // color panel either — owner wants one simple wheel, inline.
                Button {
                    showAccentWheel.toggle()
                } label: {
                    Circle()
                        .fill(AngularGradient(
                            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                            center: .center))
                        .frame(width: 20, height: 20)
                        .overlay {
                            if ThemeStore.shared.custom != nil {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Custom color")
            }
            if showAccentWheel {
                AccentWheel { ThemeStore.shared.custom = $0 }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }

        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Panel")
            Toggle("Close when it loses focus", isOn: $panelClosesOnFocusLoss)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)
            Text("When off, the panel stays open until you click the menu-bar icon or press Esc. Drag it by any empty area.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Screenshots")
            Text("Captures are copied to the clipboard and saved here.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Toggle("Save a copy to this folder", isOn: $autoSave)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)
            HStack(spacing: 6) {
                Text(folder)
                    .font(Theme.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(autoSave ? .secondary : .quaternary)
                Spacer()
                Button("Change…") { pickFolder() }
                    .font(Theme.caption)
                    .disabled(!autoSave)
            }
        }

        backgroundRemovalSection

        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Preview stack")
            Text("Previews stack in the corner and stay until you swipe them away.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Stepper(value: $previewMaxStack, in: 1...10) {
                Text("Keep up to \(previewMaxStack) previews")
                    .font(Theme.body)
            }
            Toggle("Auto-dismiss after a delay", isOn: $previewAutoDismiss)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)
            Stepper(value: $previewAutoDismissSeconds, in: 2...60, step: 1) {
                Text("Dismiss after \(Int(previewAutoDismissSeconds))s")
                    .font(Theme.caption)
                    .foregroundStyle(previewAutoDismiss ? .secondary : .quaternary)
            }
            .disabled(!previewAutoDismiss)
        }

        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Feedback")
            Toggle("Sound effects", isOn: $soundsEnabled)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)
        }

        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Startup")
            Toggle("Open at login", isOn: loginItemBinding)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)
        }
    }

    /// Reads/writes the login-item state straight from `SMAppService` (its
    /// status is the source of truth), so the toggle reflects reality even if
    /// login items were changed in System Settings.
    private var loginItemBinding: Binding<Bool> {
        Binding(get: { LoginItem.isEnabled }, set: { LoginItem.setEnabled($0) })
    }

    private var toolsTab: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            Text("A tool you turn off does not load at all. Changes apply immediately.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            ForEach(env.tools.known, id: \.id) { tool in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: toolBinding(tool.id)) {
                        Label(tool.title, systemImage: tool.icon)
                            .font(Theme.body)
                    }
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    HotkeyRecorderRow(id: tool.id)
                        .padding(.leading, 24)
                    if tool.id == CleanModeTool.toolID {
                        CleanModeSettingsView()
                            .padding(.leading, 24)
                    }
                }
            }
        }
    }

    private func toolBinding(_ id: String) -> Binding<Bool> {
        Binding(
            // Observable, not a raw UserDefaults read: see KnownTool.isEnabled.
            get: { env.tools.isEnabled(id) },
            set: { env.tools.setEnabled(id, $0) }
        )
    }

    private var coupleKeySection: some View {
            VStack(alignment: .leading, spacing: Theme.itemGap) {
                SectionLabel(text: "Couple key")
                Text("Generate on one Mac, paste it on the other, then relaunch.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    SecureField("Paste key…", text: $keyField)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.body)
                    Button("Save") {
                        if CoupleKey.store(base64Key: keyField.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            keyStatus = "Saved. Relaunch Pear to connect."
                            keyField = ""
                        } else {
                            keyStatus = "That doesn't look like a valid key"
                        }
                    }
                    .disabled(keyField.isEmpty)
                }
                Button("Generate new key (copies to clipboard)") {
                    let key = CoupleKey.generate()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                    if CoupleKey.store(base64Key: key) {
                        keyStatus = "Generated + saved here. Paste it on the other Mac."
                    }
                }
                .font(Theme.caption)
                if let keyStatus {
                    Text(keyStatus)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.accent)
                }
                Picker("I am", selection: $role) {
                    Text("raws").tag("raws")
                    Text("Pear 🍐").tag("pear")
                }
                .pickerStyle(.segmented)
                .onChange(of: role) { _, newRole in CoupleKey.store(role: newRole) }
            }
    }

    /// The inline hue/saturation wheel behind the custom-accent swatch: tap or
    /// drag anywhere on the disc, the accent recolors live as you move. Angle
    /// is hue, distance from center is saturation, brightness stays vivid —
    /// the math lives in `AccentWheelMath` (pure, tested).
    private struct AccentWheel: View {
        let onPick: (Color) -> Void

        private static let diameter: CGFloat = 140

        var body: some View {
            Circle()
                .fill(AngularGradient(
                    colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) },
                    center: .center))
                .overlay(
                    Circle().fill(RadialGradient(
                        colors: [.white, .white.opacity(0)], center: .center,
                        startRadius: 0, endRadius: Self.diameter / 2)))
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { apply(at: $0.location) }
                        .onEnded { apply(at: $0.location) }
                )
        }

        private func apply(at point: CGPoint) {
            let size = CGSize(width: Self.diameter, height: Self.diameter)
            guard let pick = AccentWheelMath.pick(at: point, in: size) else { return }
            onPick(Color(hue: pick.hue, saturation: pick.saturation, brightness: 1))
        }
    }

    private struct AccentSwatch: View {
        let preset: AccentPreset
        let selected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Circle()
                    .fill(preset.color)
                    .frame(width: 20, height: 20)
                    .overlay {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(preset.name)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "screenshotFolder")
            folder = url.path
        }
    }
}
