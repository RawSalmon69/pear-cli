import ApplicationServices
import SwiftUI

/// The Dock Preview popover: an Accessibility onboarding card until Pear is
/// trusted, then the live settings — hover delay, preview size, and titles.
/// Every control persists under a `dockdoor.*` key and is read at use time, so
/// changes apply with no relaunch.
struct DockDoorSettingsView: View {
    /// Fired whenever a trust check comes back positive, so the tool can start
    /// its Dock observer live — the tool is enabled by default, and on a fresh
    /// install Accessibility is usually granted after launch.
    var onTrusted: () -> Void = {}
    /// Fired when the ⌥-tab switcher toggle flips, so the tool can register or
    /// tear down its hotkeys without a relaunch.
    var onSwitcherChanged: (Bool) -> Void = { _ in }

    // A plain, non-isolated C read — safe to seed @State and re-poll on appear.
    @State private var trusted = AXIsProcessTrusted()

    @AppStorage(DockDoorSettings.Key.hoverDelay)
    private var hoverDelay = DockDoorSettings.defaultHoverDelay
    @AppStorage(DockDoorSettings.Key.previewSize)
    private var previewSize = DockDoorSettings.defaultPreviewSize.rawValue
    @AppStorage(DockDoorSettings.Key.showTitles)
    private var showTitles = DockDoorSettings.defaultShowTitles
    @AppStorage(DockDoorSettings.Key.switcherEnabled)
    private var switcherEnabled = DockDoorSettings.defaultSwitcherEnabled
    @AppStorage(DockDoorSettings.Key.switcherScope)
    private var switcherScope = DockDoorSettings.defaultSwitcherScope.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            if trusted {
                settings
            } else {
                PermissionCard { recheck() }
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { recheck() }
    }

    private func recheck() {
        trusted = AXIsProcessTrusted()
        if trusted { onTrusted() }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Hover delay")
                        .font(Theme.body)
                    Spacer()
                    Text("\(Int(hoverDelay.rounded())) ms")
                        .font(Theme.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $hoverDelay, in: DockDoorSettings.hoverDelayRange, step: 10)
            }

            VStack(alignment: .leading, spacing: Theme.itemGap) {
                SectionLabel(text: "Preview")
                Picker("Size", selection: $previewSize) {
                    ForEach(DockPreviewSize.allCases) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .font(Theme.body)
                Toggle("Show window titles", isOn: $showTitles)
                    .font(Theme.body)
            }

            VStack(alignment: .leading, spacing: Theme.itemGap) {
                SectionLabel(text: "Switcher")
                Toggle("⌥-tab window switcher", isOn: $switcherEnabled)
                    .font(Theme.body)
                    .onChange(of: switcherEnabled) { _, enabled in onSwitcherChanged(enabled) }
                if switcherEnabled {
                    Picker("Scope", selection: $switcherScope) {
                        ForEach(DockSwitcherScope.allCases) { scope in
                            Text(scope.label).tag(scope.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .font(Theme.body)
                }
            }
        }
    }
}

/// Shown until Pear is trusted for Accessibility. Explains why, deep-links to
/// the settings pane, and can re-issue the system prompt. Mirrors the Windows
/// tool's onboarding card.
private struct PermissionCard: View {
    /// Called after the user acts, so the parent can re-read trust state.
    let onRecheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                Text("Accessibility access needed")
                    .font(Theme.emphasis)
            }
            Text(
                "Dock Preview reads which icon you hover and lists that app's "
                    + "windows, which macOS gates behind Accessibility. Grant Pear "
                    + "access, then hover a Dock icon to see its windows."
            )
            .font(Theme.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.itemGap) {
                Button("Open Accessibility Settings") { openSettings() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                Button("Prompt Again") { promptForTrust() }
                    .buttonStyle(.bordered)
            }
            .font(Theme.body)
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12)
    }

    private func openSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
            NSWorkspace.shared.open(url)
        }
        onRecheck()
    }

    private func promptForTrust() {
        // The SDK imports `kAXTrustedCheckOptionPrompt` as a mutable global,
        // which Swift 6 rejects as not concurrency-safe. Its value is the stable
        // string "AXTrustedCheckOptionPrompt"; use that directly for the key.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        onRecheck()
    }
}
