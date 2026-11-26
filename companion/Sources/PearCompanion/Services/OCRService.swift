import AppKit
import UserNotifications
import Vision
import VisionKit
import os

/// Pure on-device recognition, free of the actor and the clipboard flow, so
/// off-main callers (the screenshot insights scan) share one Vision path with
/// the ⌃⇧T hotkey instead of keeping a second copy.
enum OCRText {
    /// Stage timings only, never the text (it can be a password or a 2FA code).
    /// Read on a slow Mac with:
    /// /usr/bin/log show --last 10m --predicate 'subsystem == "com.rawsalmon69.pear.companion" AND category == "ocr"'
    static let log = Logger(subsystem: CoupleKey.service, category: "ocr")

    /// What every caller uses. On macOS 27 (logged on a MacBook Neo) Vision's
    /// first read in a process took 20+ s and every later one returned nothing
    /// in milliseconds until relaunch. Live Text runs out of process, so it is
    /// the fallback for a slow or empty read. Vision stays first: Live Text
    /// joins unspaced Thai list lines into one.
    static func read(in cgImage: CGImage, visionLimit: TimeInterval = 5,
                     vision: @escaping @Sendable (CGImage) -> String = recognize(in:)) async -> String {
        if let text = await answer(within: visionLimit, { vision(cgImage) }), !text.isEmpty {
            return text
        }
        return await liveText(in: cgImage)
    }

    /// `work`'s result, or nil once `limit` passes. Vision can't be cancelled,
    /// so a late read finishes in the background and is dropped.
    static func answer<T: Sendable>(within limit: TimeInterval, _ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (T?) -> Void = { value in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            DispatchQueue.global(qos: .userInitiated).async { finish(work()) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + limit) { finish(nil) }
        }
    }

    private static func liveText(in cgImage: CGImage) async -> String {
        guard ImageAnalyzer.isSupported else { return "" }
        let started = ContinuousClock.now
        do {
            let analysis = try await ImageAnalyzer().analyze(
                cgImage, orientation: .up, configuration: ImageAnalyzer.Configuration([.text]))
            log.notice("live text: \(started.duration(to: .now), privacy: .public), \(analysis.transcript.count) characters")
            return analysis.transcript
        } catch {
            log.error("live text failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    /// Vision alone, synchronous; `read(in:)` is the entry point.
    static func recognize(in cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Don't assume English: a shot of a non-English UI should still come
        // back with its text rather than nothing.
        request.automaticallyDetectsLanguage = true
        // Observations are returned in Vision's own reading order and every one
        // of them is kept — the detail view scrolls rather than truncating.
        let started = ContinuousClock.now
        defer { log.notice("read pass: \(started.duration(to: .now), privacy: .public), \(cgImage.width)x\(cgImage.height), \(request.results?.count ?? 0) lines") }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            log.error("read failed: \(error.localizedDescription, privacy: .public)")
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
        guard await ScreenCapture.region(to: tempURL, tool: "ocr") else { return }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let captured = ContinuousClock.now
        // A slow screencapture exit after the drag shows up as a gap here.
        if let written = (try? FileManager.default.attributesOfItem(atPath: tempURL.path))?[.creationDate] as? Date {
            OCRText.log.notice("capture exited \(Date().timeIntervalSince(written), format: .fixed(precision: 2), privacy: .public)s after writing the file")
        }
        // Seconds on a slower Mac with nothing on screen read as "it didn't work".
        CopyToast.show(message: "Reading text…")

        // Off the main actor: `.accurate` recognition takes seconds on a big
        // region and froze the whole app meanwhile.
        guard let text = await Task.detached(priority: .userInitiated, operation: { () async -> String? in
            guard let image = CaptureImage.decode(at: tempURL) else { return nil }
            return await OCRText.read(in: image)
        }).value else { return }
        OCRText.log.notice("read done \(captured.duration(to: .now), privacy: .public) after capture, \(text.count) characters")
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
