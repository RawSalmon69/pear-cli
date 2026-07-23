import AppKit
import UserNotifications

/// QR from anywhere: region capture → Vision barcode decode → clipboard, with
/// a notification that grows an "Open Link" button when the code is a URL.
/// Also the reverse: clipboard text → QR card (via the preview stack).
/// Global hotkey ⌃⇧Q or the panel tile. A cancelled capture is a no-op.
@MainActor
final class QRService {
    // nonisolated: read from the AppDelegate's nonisolated notification
    // callback; immutable Sendable constants are safe off-actor.
    nonisolated static let categoryIdentifier = "pear.qr.url"
    nonisolated static let openActionIdentifier = "pear.qr.open"
    nonisolated static let urlUserInfoKey = "pearQRURL"

    /// Registers the URL-notification category. Called once from QRTool.start().
    static func registerNotificationCategory() {
        let open = UNNotificationAction(
            identifier: openActionIdentifier, title: "Open Link", options: [])
        let category = UNNotificationCategory(
            identifier: categoryIdentifier, actions: [open],
            intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func scanFromScreen() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pear-qr-scan-\(UUID().uuidString).png")
        guard await ScreenCapture.region(to: tempURL) else { return }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let image = NSImage(contentsOf: tempURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        deliver(QRCode.decode(in: cgImage))
    }

    /// Shared result flow for the scan hotkey and the preview-card badge.
    func deliver(_ payloads: [String]) {
        guard !payloads.isEmpty else {
            notify(title: "No QR code found", body: "Pear couldn't find a code there.")
            return
        }

        let text = QRCode.clipboardText(for: payloads)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        SoundEffects.play(.done)

        let preview = text.count > 90 ? String(text.prefix(90)) + "…" : text
        if let url = QRCode.openableURL(in: payloads) {
            notify(title: "Copied link 📋", body: preview,
                   category: Self.categoryIdentifier,
                   userInfo: [Self.urlUserInfoKey: url.absoluteString])
        } else {
            let title = payloads.count > 1
                ? "Copied \(payloads.count) codes 📋" : "Copied code 📋"
            notify(title: title, body: preview)
        }
    }

    /// Clipboard text → QR card in the preview stack (wired in a later task).
    func generateFromClipboard() {
        let raw = NSPasteboard.general.string(forType: .string) ?? ""
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            notify(title: "Nothing to encode", body: "Copy some text or a link first.")
            return
        }
        guard let image = QRCode.generate(from: text), let png = image.pngData() else {
            notify(title: "Couldn't make a QR code", body: "That text is too long for a QR code.")
            return
        }
        presentGenerated(png: png)
    }

    /// Generated code → a card in the shared preview stack: copy it, reveal
    /// the PNG, scan it with a phone. Markup/send/background-removal make no
    /// sense on a QR grid, so those actions are off.
    private func presentGenerated(png: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pear-qr-\(UUID().uuidString).png")
        try? png.write(to: url)
        SoundEffects.play(.done)
        ScreenshotPreviewController.shared.show(
            imageData: png,
            canMarkup: false,
            canSend: false,
            canSave: false,
            canRemoveBackground: false,
            onCopy: {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([url as NSURL])
                pasteboard.setData(png, forType: .png)
                SoundEffects.play(.copy)
            },
            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([url]) },
            onMarkup: {},
            onSend: {}
        )
    }

    private func notify(title: String, body: String,
                        category: String? = nil, userInfo: [String: String] = [:]) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        content.userInfo = userInfo
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}
