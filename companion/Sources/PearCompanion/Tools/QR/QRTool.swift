import SwiftUI
import Carbon.HIToolbox

/// Region capture → QR/barcode decode → clipboard (⌃⇧Q), plus the reverse:
/// a QR card generated from whatever is on the clipboard.
@MainActor
final class QRTool: Tool {
    let id = "qr"
    let title = "QR"
    let icon = "qrcode.viewfinder"
    let category = ToolCategory.capture
    let summary = "Read a QR code off the screen, or turn your clipboard into one."
    let hotkey: HotKeyChord? = HotKeyChord(
        keyCode: kVK_ANSI_Q, modifiers: controlKey | shiftKey, label: "⌃⇧Q")

    private var service: QRService?

    func start() {
        QRService.registerNotificationCategory()
    }

    var entry: ToolEntry {
        .popover { [weak self] in
            AnyView(QRPopoverView(
                onScan: { self?.scan() },
                onGenerate: { self?.resolveService().generateFromClipboard() }))
        }
    }

    func hotkeyFired() {
        scan()
    }

    private func scan() {
        let service = resolveService()
        Task { await service.scanFromScreen() }
    }

    private func resolveService() -> QRService {
        if let service { return service }
        let created = QRService()
        service = created
        return created
    }
}

/// Matches the shared popover style used by `ColorPickerView` / `MenuBarSettingsView`
/// (`Theme` tokens, a `SectionLabel` header, 300pt width) rather than the ad hoc
/// bordered-buttons layout: a prominent CTA for the hotkey-bound primary action
/// (scan), a plain bordered button for the secondary one (generate).
private struct QRPopoverView: View {
    let onScan: () -> Void
    let onGenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "QR Code")
            scanButton
            generateButton
        }
        .padding(Theme.heroPadding)
        .frame(width: 300)
    }

    private var scanButton: some View {
        Button(action: onScan) {
            Label("Scan screen", systemImage: "qrcode.viewfinder")
                .font(Theme.emphasis)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
    }

    private var generateButton: some View {
        Button(action: onGenerate) {
            Label("QR from clipboard", systemImage: "qrcode")
                .font(Theme.body)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}
