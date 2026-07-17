import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// Overlays the frontmost app's keyboard shortcuts. ⌃⇧K. Read-only: it reads
/// the target app's menu bar via Accessibility and shows it; it never touches
/// the app. Re-press or app-switch dismisses.
@MainActor
final class KeyCluTool: Tool {
    let id = "keyclu"
    let title = "Shortcuts"
    let icon = "keyboard"
    let category = ToolCategory.utilities
    let summary = "Peek at the frontmost app's keyboard shortcuts."
    let hotkey: HotKeyChord? = HotKeyChord(
        keyCode: kVK_ANSI_K, modifiers: controlKey | shiftKey, label: "⌃⇧K")

    private let overlay = KeyCluOverlayController()
    private let reader = MenuShortcutReader(provider: LiveMenuAXProvider())

    var entry: ToolEntry {
        .action { [weak self] in self?.show() }
    }

    func hotkeyFired() { show() }

    private func show() {
        if overlay.isVisible {
            overlay.hide()
            return
        }
        guard AXIsProcessTrusted() else {
            // Same prompt the Windows tool uses; the string key avoids the
            // Swift 6 non-Sendable global `kAXTrustedCheckOptionPrompt`.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let groups = reader.groups(forPID: app.processIdentifier)
        overlay.present(
            appName: app.localizedName ?? "App", appIcon: app.icon, groups: groups)
    }
}
