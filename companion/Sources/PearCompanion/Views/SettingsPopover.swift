import SwiftUI
import AppKit

/// Settings, split into a few tabs so a dozen tools' worth of controls read
/// as small groups instead of one long scroll. General = look and capture,
/// Tools = per-tool on/off, Menu Bar = the runner.
struct SettingsPopover: View {
    @Environment(AppEnvironment.self) private var env
    @State private var tab: Tab = .general
    @State private var keyField = ""
    @State private var role = CoupleKey.deviceRole
    @State private var keyStatus: String?
    @State private var folder = ScreenshotNaming.folder(
        defaults: .standard,
        home: FileManager.default.homeDirectoryForCurrentUser
    ).path
    @AppStorage(Prefs.soundsKey) private var soundsEnabled = true
    @AppStorage(Prefs.autoSaveKey) private var autoSave = true

    private enum Tab: String, CaseIterable, Identifiable {
        case general = "General", tools = "Tools", menuBar = "Menu Bar"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    switch tab {
                    case .general: generalTab
                    case .tools: toolsTab
                    case .menuBar: RunnerSettingsView(runner: env.runner)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 360)
        }
        .padding(16)
        .frame(width: 300)
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
                        selected: ThemeStore.shared.preset == preset
                    ) {
                        ThemeStore.shared.preset = preset
                    }
                }
            }
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

        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Feedback")
            Toggle("Sound effects", isOn: $soundsEnabled)
                .font(Theme.body)
                .toggleStyle(.switch)
                .tint(Theme.accent)
        }
    }

    private var toolsTab: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            Text("Turn off any tool you don't use — it won't load at all. Takes effect after relaunch.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            ForEach(env.tools.known, id: \.id) { tool in
                Toggle(isOn: toolBinding(tool.id)) {
                    Label(tool.title, systemImage: tool.icon)
                        .font(Theme.body)
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)
            }
        }
    }

    private func toolBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { Prefs.isToolEnabled(id) },
            set: { Prefs.setToolEnabled(id, $0) }
        )
    }

    private var coupleKeySection: some View {
            VStack(alignment: .leading, spacing: Theme.itemGap) {
                SectionLabel(text: "Couple key")
                Text("Generate on one Mac, paste on the other. Relaunch after saving.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    SecureField("Paste key…", text: $keyField)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.body)
                    Button("Save") {
                        if CoupleKey.store(base64Key: keyField.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            keyStatus = "Saved — relaunch Pear to connect"
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
