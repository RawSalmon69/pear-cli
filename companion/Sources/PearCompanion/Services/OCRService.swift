import AppKit
import UserNotifications
import Vision
import os

/// "Grab text from anywhere": region capture → on-device text recognition →
/// clipboard, with a notification showing what was copied. Global hotkey ⌃⇧T
/// or a panel button. A cancelled capture is a no-op.
@MainActor
final class OCRService {
    private let logger = Logger(subsystem: CoupleKey.service, category: "ocr")

    func grab() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pear-ocr-\(UUID().uuidString).png")
        guard await ScreenCapture.region(to: tempURL) else { return }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let image = NSImage(contentsOf: tempURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        let text = recognizeText(in: cgImage)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            notify(title: "No text found", body: "Pear couldn't read any text there.")
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
        SoundEffects.play(.done)

        let preview = trimmed.count > 90 ? String(trimmed.prefix(90)) + "…" : trimmed
        notify(title: "Copied text 📋", body: preview)
    }

    /// Synchronous on-device recognition. Fast enough for a screenshot region
    /// that running it inline beats the concurrency-hop complexity.
    private func recognizeText(in cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.error("OCR failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
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
