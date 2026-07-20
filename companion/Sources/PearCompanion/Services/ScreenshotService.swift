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
/// Triggered by the global hotkey (⌃⇧S) or the panel's Screenshot button.
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
        // Unmuted capture = macOS's own camera shutter (the CleanShot feel);
        // the sounds toggle mutes it.
        guard await ScreenCapture.region(to: tempURL, muted: !Prefs.soundsEnabled) else {
            return // cancelled or failed
        }

        guard let data = try? Data(contentsOf: tempURL) else { return }

        // Save into the screenshot folder when auto-save is on; either way a
        // file backs the preview, the send, and the clipboard's file URL.
        var savedURL = tempURL
        if Prefs.screenshotAutoSave {
            do {
                savedURL = try persist(data)
            } catch {
                logger.error("screenshot save failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        copyToPasteboard(data, fileURL: savedURL)
        present(data: data, at: savedURL)

        // With auto-save on, persist() wrote the real copy and the preview/send
        // point at it, so the capture temp is now dead weight — remove it. When
        // auto-save is off, savedURL == tempURL and the preview still needs it.
        if savedURL != tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    /// Shows the floating preview for `data` saved at `fileURL`, wiring copy,
    /// reveal, markup, and send. Markup re-runs the flow with the edited image.
    private func present(data: Data, at fileURL: URL) {
        let messaging = self.messaging
        let log = logger
        preview.show(
            imageData: data,
            canMarkup: onMarkupRequest != nil,
            // Only offer Save when auto-save is off; with it on the file is
            // already in the folder (and the preview already points at it).
            canSave: !Prefs.screenshotAutoSave,
            onCopy: { [weak self] in
                self?.copyToPasteboard(data, fileURL: fileURL)
                SoundEffects.play(.copy)
            },
            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) },
            onMarkup: { [weak self] in self?.markup(data: data, at: fileURL) },
            onRemoveBackground: { [weak self] in self?.removeBackground(data: data, at: fileURL) },
            onSend: {
                SoundEffects.play(.send)
                Task { @MainActor in
                    do {
                        try await messaging.send(fileAt: fileURL, kind: .image)
                    } catch {
                        log.error("screenshot send failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            },
            onSave: { [weak self] in self?.saveToFolder(data) }
        )
    }

    /// Writes the capture into the screenshot folder on demand — the Save
    /// button's action when auto-save is off. Reuses the same `persist` writer
    /// as auto-save, so naming and location stay identical.
    private func saveToFolder(_ data: Data) {
        do {
            _ = try persist(data)
        } catch {
            logger.error("screenshot manual save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens the markup editor; on completion, overwrites the saved PNG and
    /// clipboard with the edited image and re-shows the preview.
    private func markup(data: Data, at fileURL: URL) {
        guard let onMarkupRequest, let image = NSImage(data: data) else { return }
        // The tapped preview card dismisses itself; on completion we show a
        // fresh preview for the edited image.
        onMarkupRequest(image) { [weak self] edited in
            guard let self, let edited, let png = edited.pngData() else { return }
            try? png.write(to: fileURL)
            self.copyToPasteboard(png, fileURL: fileURL)
            self.present(data: png, at: fileURL)
        }
    }

    /// Vision background removal on the current shot: replaces the card's image
    /// with the transparent cutout, copies it, and overwrites the saved file
    /// (like Markup, this is an edit of the shot). No subject found → keep the
    /// original and re-show it.
    private func removeBackground(data: Data, at fileURL: URL) {
        Task { @MainActor in
            let cutout = await Task.detached(priority: .userInitiated) {
                BackgroundRemovalService.cutout(imageData: data)
            }.value
            guard let cutout else {
                SoundEffects.play(.discard)
                self.present(data: data, at: fileURL)
                return
            }
            try? cutout.write(to: fileURL)
            self.copyToPasteboard(cutout, fileURL: fileURL)
            SoundEffects.play(.copy)
            self.present(data: cutout, at: fileURL)
        }
    }

    private func copyToPasteboard(_ pngData: Data, fileURL: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Write the saved file's URL first so targets that take a FILE paste
        // (terminals, Finder, this very chat) accept it — matching how a
        // CleanShot paste lands as a path. Bitmap-only left those unable to
        // paste at all; the bitmap types below still serve image editors that
        // want an inline Cmd+V image. One item, three representations.
        pasteboard.writeObjects([fileURL as NSURL])
        if let tiff = NSImage(data: pngData)?.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
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
