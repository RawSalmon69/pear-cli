import Foundation
import AppKit
import os

/// Pure filename/folder policy for screenshots, factored out of the service
/// so it's unit-testable without touching the real disk or defaults.
enum ScreenshotNaming {
    static let folderDefaultsKey = "screenshotFolder"

    /// "Pear 2026-07-13 at 14.03.59.png"
    static func filename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Pear \(formatter.string(from: date)).png"
    }

    /// The configured screenshot folder, defaulting to
    /// `<home>/Documents/PearScreenshots`. Tilde in the stored path expands.
    static func folder(defaults: UserDefaults, home: URL) -> URL {
        if let path = defaults.string(forKey: folderDefaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("PearScreenshots", isDirectory: true)
    }
}

/// Region screenshot → clipboard + saved PNG + floating preview. The preview
/// offers re-copy, reveal-in-Finder, and the encrypted send to the other Mac.
/// Triggered by the global hotkey (⌃⇧P) or the panel's Screenshot button.
/// A user-cancelled capture (no file written) is a no-op.
@MainActor
final class ScreenshotService {
    private let messaging: MessagingService
    private let logger = Logger(subsystem: CoupleKey.service, category: "screenshot")
    private let preview = ScreenshotPreviewController()

    /// Set by AppEnvironment to the markup editor. When nil, the preview hides
    /// its Markup button, so ScreenshotService never hard-depends on the editor.
    var onMarkupRequest: ((NSImage, @escaping (NSImage?) -> Void) -> Void)?

    init(messaging: MessagingService) {
        self.messaging = messaging
    }

    func capture() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pear-shot-\(UUID().uuidString).png")
        guard await ScreenCapture.region(to: tempURL) else { return } // cancelled or failed

        guard let data = try? Data(contentsOf: tempURL) else { return }

        SoundEffects.play(.capture)
        copyToPasteboard(data)

        // Save into the screenshot folder when auto-save is on; either way the
        // temp file backs the preview and send.
        var savedURL = tempURL
        if Prefs.screenshotAutoSave {
            do {
                savedURL = try persist(data)
            } catch {
                logger.error("screenshot save failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        present(data: data, at: savedURL)
    }

    /// Shows the floating preview for `data` saved at `fileURL`, wiring copy,
    /// reveal, markup, and send. Markup re-runs the flow with the edited image.
    private func present(data: Data, at fileURL: URL) {
        let messaging = self.messaging
        let log = logger
        preview.show(
            imageData: data,
            canMarkup: onMarkupRequest != nil,
            onCopy: { [weak self] in
                self?.copyToPasteboard(data)
                SoundEffects.play(.copy)
            },
            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) },
            onMarkup: { [weak self] in self?.markup(data: data, at: fileURL) },
            onSend: {
                SoundEffects.play(.send)
                Task { @MainActor in
                    do {
                        try await messaging.send(fileAt: fileURL, kind: .image)
                    } catch {
                        log.error("screenshot send failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        )
    }

    /// Opens the markup editor; on completion, overwrites the saved PNG and
    /// clipboard with the edited image and re-shows the preview.
    private func markup(data: Data, at fileURL: URL) {
        guard let onMarkupRequest, let image = NSImage(data: data) else { return }
        preview.dismiss()
        onMarkupRequest(image) { [weak self] edited in
            guard let self, let edited, let png = edited.pngData() else { return }
            self.copyToPasteboard(png)
            try? png.write(to: fileURL)
            self.present(data: png, at: fileURL)
        }
    }

    private func copyToPasteboard(_ pngData: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
    }

    private func persist(_ data: Data) throws -> URL {
        let folder = ScreenshotNaming.folder(
            defaults: .standard,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(ScreenshotNaming.filename(for: Date()))
        try data.write(to: url)
        return url
    }
}
