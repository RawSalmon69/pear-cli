import AppKit
import UserNotifications
import Vision
import os

/// Pure on-device recognition, free of the actor and the clipboard flow, so
/// off-main callers (the screenshot insights scan) share one Vision path with
/// the ⌃⇧T hotkey instead of keeping a second copy.
enum OCRText {
    static func recognize(in cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Don't assume English: a shot of a non-English UI should still come
        // back with its text rather than nothing.
        request.automaticallyDetectsLanguage = true
        // Observations are returned in Vision's own reading order and every one
        // of them is kept — the detail view scrolls rather than truncating.

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// Straight from encoded bytes — the form the preview stack holds. Sendable
    /// input, so callers can hop executors (mirrors `QRCode.payloads`).
    static func recognize(inImageData data: Data) -> String {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
        }
        return recognize(in: cgImage)
    }
}

/// "Grab text from anywhere": region capture → on-device text recognition →
/// clipboard, with a notification showing what was copied. Global hotkey ⌃⇧T
/// or a panel button. A cancelled capture is a no-op.
@MainActor
final class OCRService {
    func grab() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pear-ocr-\(UUID().uuidString).png")
        guard await ScreenCapture.region(to: tempURL) else { return }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let image = NSImage(contentsOf: tempURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        copyText(from: cgImage)
    }

    /// Recognize → clipboard → sound → notification. Public so the screenshot
    /// preview's "Copy text" action can reuse the whole flow on an existing image.
    func copyText(from cgImage: CGImage) {
        let text = OCRText.recognize(in: cgImage)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            notify(title: "No text found", body: "Pear couldn't read any text there.")
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
        SoundEffects.play(.done)

        // Deliberately NOT a preview of the text. A notification body is drawn as
        // an on-screen banner and kept in Notification Center until dismissed —
        // grabbing text from a password field, a private message or a 2FA code
        // put it in both. Same reasoning as the concealed-pasteboard rule in
        // `ClipboardHistoryService`; the text itself is on the clipboard.
        notify(title: "Copied text 📋", body: Self.summary(of: trimmed))
    }

    /// Neutral confirmation: enough to know the grab worked, nothing readable.
    /// Pure, so it's nonisolated and unit-testable off the main actor.
    nonisolated static func summary(of text: String) -> String {
        let characters = text.count
        let words = text.split(whereSeparator: \.isWhitespace).count
        let unit = characters == 1 ? "character" : "characters"
        return words > 1 ? "\(words) words · \(characters) \(unit)" : "\(characters) \(unit)"
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}
