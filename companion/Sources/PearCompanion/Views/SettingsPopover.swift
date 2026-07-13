import SwiftUI
import AppKit

/// One small surface for the two things the app needs configured:
/// the couple key (once, on both Macs) and the screenshot folder.
struct SettingsPopover: View {
    @EnvironmentObject private var env: AppEnvironment

    @State private var keyField = ""
    @State private var role = CoupleKey.deviceRole
    @State private var keyStatus: String?
    @State private var folder = ScreenshotNaming.folder(
        defaults: .standard,
        home: FileManager.default.homeDirectoryForCurrentUser
    ).path

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
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
                .onChange(of: role) { CoupleKey.store(role: $0) }
            }

            VStack(alignment: .leading, spacing: Theme.itemGap) {
                SectionLabel(text: "Screenshots")
                Text("Captures are copied to the clipboard and saved here.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(folder)
                        .font(Theme.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Change…") { pickFolder() }
                        .font(Theme.caption)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
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
