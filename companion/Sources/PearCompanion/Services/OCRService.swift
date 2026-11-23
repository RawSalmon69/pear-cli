import AppKit
import Carbon
import UserNotifications
import Vision
import os

/// Pure on-device recognition, free of the actor and the clipboard flow, so
/// off-main callers (the screenshot insights scan) share one Vision path with
/// the ⌃⇧T hotkey instead of keeping a second copy.
enum OCRText {
    /// Auto-detect first (don't assume English: a shot of a non-English UI
    /// should still come back with its text). Auto-detect misreads small Thai
    /// as Latin garbage (confidence 0.5) or nothing, so such a read is retried
    /// with the user's `languages` and the more confident read wins. Mixed
    /// Thai/English reads 0.67–0.83 either way, so it gets no wasted second
    /// pass. Not list-only: Vision honors just a list's first script and turns
    /// Japanese into Latin garbage under ["th-TH", "en-US"] (all measured).
    static func recognize(in cgImage: CGImage, languages: [String]? = nil) -> String {
        let auto = run(cgImage) { $0.automaticallyDetectsLanguage = true }
        guard let languages, auto.confidence <= 0.5 else { return auto.text }
        let listed = run(cgImage) { $0.recognitionLanguages = languages }
        return listed.confidence > auto.confidence ? listed.text : auto.text
    }

    /// Text plus mean confidence; nothing read is confidence 0.
    private static func run(_ cgImage: CGImage, configure: (VNRecognizeTextRequest) -> Void)
        -> (text: String, confidence: Float) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        configure(request)
        // Observations are returned in Vision's own reading order and every one
        // of them is kept — the detail view scrolls rather than truncating.

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ("", 0)
        }
        let candidates = (request.results ?? []).compactMap { $0.topCandidates(1).first }
        guard !candidates.isEmpty else { return ("", 0) }
        return (candidates.map(\.string).joined(separator: "\n"),
                candidates.map(\.confidence).reduce(0, +) / Float(candidates.count))
    }

    /// The user's first non-English language Vision can read, plus English, from
    /// System Settings languages then enabled keyboards (a Thai user on an
    /// English UI usually only has the Thai keyboard). Main actor: Text Input
    /// Sources traps off the main thread.
    @MainActor static func userLanguages() -> [String]? {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsEnabled as String: true] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        // First language only: a US keyboard lists every language it can type.
        let keyboards = sources.compactMap { source -> String? in
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
            return (Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String])?.first
        }
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
        return languages(preferring: Locale.preferredLanguages + keyboards, supported: supported)
    }

    /// Pure half of `userLanguages`: exact match first ("zh-Hant-TW" → zh-Hant),
    /// then by language ("th" → th-TH). Nil when the user is English-only.
    static func languages(preferring user: [String], supported: [String]) -> [String]? {
        for code in user {
            let language = String(code.prefix { $0 != "-" && $0 != "_" })
            guard language != "en",
                  let match = supported.first(where: { code.hasPrefix($0) })
                    ?? supported.first(where: { $0.hasPrefix(language + "-") })
            else { continue }
            return [match, "en-US"]
        }
        return nil
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
        guard await ScreenCapture.region(to: tempURL, tool: "ocr") else { return }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        // Seconds on a slower Mac with nothing on screen read as "it didn't work".
        CopyToast.show(message: "Reading text…")
        let languages = OCRText.userLanguages()

        // Off the main actor: `.accurate` recognition takes seconds on a big
        // region and froze the whole app meanwhile.
        guard let text = await Task.detached(priority: .userInitiated, operation: {
            CaptureImage.decode(at: tempURL).map { OCRText.recognize(in: $0, languages: languages) }
        }).value else { return }
        copyText(text)
    }

    /// Clipboard → sound → notification for already-recognised text. Shared
    /// with the screenshot preview's "Copy text" action.
    func copyText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // The notification alone is silent when notifications are off.
            CopyToast.show(message: "No text found")
            notify(title: "No text found", body: "Pear couldn't read any text there.")
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
        SoundEffects.play(.done)
        CopyToast.show(message: "Copied text")

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
