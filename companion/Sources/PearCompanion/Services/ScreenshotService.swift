import Foundation
import AppKit
import os

/// Pure filename/folder policy for screenshots, factored out of the service
/// so it's unit-testable without touching the real disk or defaults.
enum ScreenshotNaming {
    static let folderDefaultsKey = "screenshotFolder"

    /// "Pear 2026-07-13 at 14.03.59.png"
    static func filename(for date: Date, prefix: String = "Pear") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: date)).png"
    }

    /// Finder-style "name (1)" resolution. The filename is second-granular, so
    /// two captures — or two Saves — inside one second resolve to the same path
    /// and the second `write` silently truncated the first. `exists` is injected
    /// so this stays testable without touching the disk.
    static func uniqueURL(preferred: URL, exists: (URL) -> Bool) -> URL {
        guard exists(preferred) else { return preferred }
        let dir = preferred.deletingLastPathComponent()
        let ext = preferred.pathExtension
        let stem = preferred.deletingPathExtension().lastPathComponent
        var i = 1
        while true {
            var candidate = dir.appendingPathComponent("\(stem) (\(i))")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !exists(candidate) { return candidate }
            i += 1
        }
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

/// Where a capture lives while only a preview card points at it.
///
/// With auto-save off the capture used to stay in `/var/folders/…/T/` and that
/// temp file was the only copy — a directory macOS reaps on its own schedule.
/// Because the file could vanish underneath it, every card had to hold the
/// whole PNG in memory (30–200 MB for a stack of 6K shots). An app-owned folder
/// makes the file trustworthy, so the cards can hold a URL and a thumbnail.
///
/// Names are the same human-readable `Pear <date>.png` the screenshot folder
/// uses: "I lost that screenshot" stays recoverable by going and looking.
enum CaptureStore {
    /// Unsaved captures are Pear's own scratch copies, not user documents —
    /// they are cleared a week after capture.
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    /// `~/Library/Application Support/PearCompanion/Captures` (the app is not
    /// sandboxed), same shape as the shelf's and the HD model's stores.
    static var root: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PearCompanion/Captures", isDirectory: true)
    }

    /// Where a fresh capture is filed, best first. Auto-save on → the user's
    /// screenshot folder, with the store as a fallback so an unmounted external
    /// folder loses no shot. Auto-save off → the store only; the user asked for
    /// captures NOT to land in their folder.
    static func destinations(
        autoSave: Bool,
        defaults: UserDefaults = .standard,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        store: URL = CaptureStore.root
    ) -> [URL] {
        autoSave ? [ScreenshotNaming.folder(defaults: defaults, home: home), store] : [store]
    }

    /// Writes `data` into the store under a fresh, collision-free name.
    static func save(_ data: Data, prefix: String = "Pear", now: Date = Date(),
                     in directory: URL = CaptureStore.root) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = ScreenshotNaming.uniqueURL(
            preferred: directory.appendingPathComponent(
                ScreenshotNaming.filename(for: now, prefix: prefix)),
            exists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Drops captures older than `retention`. Called at launch, where `live` is
    /// necessarily empty (cards are in-memory), but a card's file must never be
    /// deleted out from under it if this ever runs while the app is up.
    ///
    /// Only `.png` files are considered, and only inside Pear's own store — no
    /// user document is ever in scope, which is why this deletes outright
    /// instead of routing through the Trash.
    @discardableResult
    static func sweep(
        in directory: URL = CaptureStore.root,
        now: Date = Date(),
        retention: TimeInterval = CaptureStore.retention,
        keeping live: Set<URL> = []
    ) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let protected = Set(live.map(\.standardizedFileURL.path))
        var removed = 0
        for url in entries {
            guard url.pathExtension.lowercased() == "png" else { continue }
            guard !protected.contains(url.standardizedFileURL.path) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) >= retention else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
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
    private let preview = ScreenshotPreviewController.shared
    private lazy var ocr = OCRService()
    private lazy var qr = QRService()

    /// Set by AppEnvironment to the markup editor. When nil, the preview hides
    /// its Markup button, so ScreenshotService never hard-depends on the editor.
    var onMarkupRequest: ((NSImage, @escaping (NSImage?) -> Void) -> Void)?

    /// One capture at a time. Each hotkey press is its own main-actor turn, so a
    /// double-tap (or key auto-repeat) used to launch two `screencapture -i`
    /// processes fighting over one crosshair — and produce two cards, two
    /// clipboard writes and two saved files from one user intent.
    private var isCapturing = false

    init(messaging: MessagingService) {
        self.messaging = messaging
    }

    func capture() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        let tempURL = Self.captureTempURL()
        // Unmuted capture = macOS's own camera shutter (the CleanShot feel);
        // the sounds toggle mutes it.
        guard await ScreenCapture.region(to: tempURL, muted: !Prefs.soundsEnabled) else {
            return // cancelled or failed
        }
        deliver(tempURL: tempURL)
    }

    /// Whole main display, no region drag — same downstream flow as `capture()`.
    func captureFullScreen() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        let tempURL = Self.captureTempURL()
        guard await ScreenCapture.fullScreen(to: tempURL, muted: !Prefs.soundsEnabled) else {
            return // failed
        }
        deliver(tempURL: tempURL)
    }

    /// Click-a-window shot — same downstream flow as `capture()`.
    func captureWindow() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        let tempURL = Self.captureTempURL()
        guard await ScreenCapture.window(to: tempURL, muted: !Prefs.soundsEnabled) else {
            return // cancelled or failed
        }
        deliver(tempURL: tempURL)
    }

    private static func captureTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pear-shot-\(UUID().uuidString).png")
    }

    /// Filename prefixes of the temp PNGs older Pear builds left behind: a
    /// capture temp was kept for as long as its card lived (auto-save off), and
    /// a generated QR card's PNG likewise. Neither was ever swept.
    nonisolated static let tempPrefixes = ["pear-shot-", "pear-qr-"]

    /// Deletes Pear's own leftover temp PNGs. Called at launch ONLY, which is
    /// what makes it safe: preview cards live in memory, so nothing from a
    /// previous run is still referenced. A 5-minute age floor is belt-and-braces
    /// against deleting a file a just-started sibling process is using.
    ///
    /// Captures no longer stay in the temp dir at all (see `CaptureStore`), so
    /// this only clears the backlog left by builds ≤ 2.14.1. Delete it a release
    /// or two after that backlog is gone.
    nonisolated static func sweepStaleTempFiles(
        in directory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date(),
        minimumAge: TimeInterval = 300
    ) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var removed = 0
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasSuffix(".png"),
                  tempPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, now.timeIntervalSince(modified) < minimumAge { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Post-capture half, shared by every capture mode: file the shot, put it on
    /// the clipboard, show the card. The bytes are never held past this call —
    /// the card is backed by the file from here on.
    private func deliver(tempURL: URL) {
        let url = fileCapture(tempURL)
        copyToPasteboard(at: url)
        present(at: url)
    }

    /// Moves a fresh capture out of the system temp dir into its real home. Both
    /// fallbacks earn their keep: an unmounted external screenshot folder must
    /// not lose the shot, and a card backed by the temp file (today's behaviour)
    /// still beats no card at all.
    private func fileCapture(_ tempURL: URL) -> URL {
        for folder in CaptureStore.destinations(autoSave: Prefs.screenshotAutoSave) {
            if let url = try? Self.file(tempURL, into: folder, moving: true) { return url }
        }
        logger.error("capture could not be filed; keeping the temp copy")
        return tempURL
    }

    /// Files a capture into `folder` under a fresh, collision-free Pear name.
    /// Move when the source is a capture temp; copy for Save, where the store
    /// copy stays behind until retention drops it. Not private: this moves the
    /// user's only copy of a screenshot, so it is under test.
    static func file(_ source: URL, into folder: URL, moving: Bool) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = ScreenshotNaming.uniqueURL(
            preferred: folder.appendingPathComponent(ScreenshotNaming.filename(for: Date())),
            exists: { fm.fileExists(atPath: $0.path) }
        )
        if moving {
            do {
                try fm.moveItem(at: source, to: url)
            } catch {
                // A rename cannot cross volumes, and the screenshot folder may
                // well be on an external disk. Keeping the shot matters more
                // than the move being one syscall, so fall back to a copy —
                // clearing any partial destination the failed move left.
                try? fm.removeItem(at: url)
                try fm.copyItem(at: source, to: url)
                try? fm.removeItem(at: source)
            }
        } else {
            try fm.copyItem(at: source, to: url)
        }
        return url
    }

    /// Shows the floating preview for the capture at `fileURL`, wiring copy,
    /// reveal, markup, and send. Every action reads the file when it is clicked:
    /// holding the PNG for the card's whole lifetime is what made a stack of
    /// captures cost tens of megabytes of resident memory.
    private func present(at fileURL: URL) {
        let messaging = self.messaging
        let log = logger
        preview.show(
            // Backs the thumbnail, the detail view, the insights scan, and the
            // Details section's reveal link.
            url: fileURL,
            canMarkup: onMarkupRequest != nil,
            // Only offer Save when auto-save is off; with it on the file is
            // already in the folder (and the preview already points at it).
            canSave: !Prefs.screenshotAutoSave,
            onCopy: { [weak self] in
                if self?.copyToPasteboard(at: fileURL) == true { SoundEffects.play(.copy) }
            },
            onCopyText: { [weak self] in
                guard let self, let cg = self.decode(at: fileURL) else { return }
                self.ocr.copyText(from: cg)
            },
            onQRTap: { [weak self] payloads in
                self?.qr.deliver(payloads)
            },
            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) },
            onMarkup: { [weak self] in self?.markup(at: fileURL) },
            onRemoveBackground: { [weak self] in self?.removeBackground(at: fileURL) },
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
            onSave: { [weak self] in self?.saveToFolder(from: fileURL) }
        )
    }

    /// Copies the capture into the screenshot folder on demand — the Save
    /// button's action when auto-save is off. The card keeps pointing at the
    /// store copy, exactly as it kept pointing at the temp file before.
    private func saveToFolder(from url: URL) {
        let folder = ScreenshotNaming.folder(
            defaults: .standard,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
        do {
            _ = try Self.file(url, into: folder, moving: false)
        } catch {
            logger.error("screenshot manual save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens the markup editor; on completion, overwrites the saved PNG and
    /// clipboard with the edited image and re-shows the preview.
    private func markup(at fileURL: URL) {
        guard let onMarkupRequest, let data = bytes(at: fileURL),
              let image = NSImage(data: data) else { return }
        // The tapped preview card dismisses itself; on completion we show a
        // fresh preview for the edited image.
        onMarkupRequest(image) { [weak self] edited in
            guard let self, let edited, let png = edited.pngData() else { return }
            self.overwrite(png, at: fileURL)
            self.copyToPasteboard(png, fileURL: fileURL)
            self.present(at: fileURL)
        }
    }

    /// Vision background removal on the current shot: replaces the card's image
    /// with the transparent cutout, copies it, and overwrites the saved file
    /// (like Markup, this is an edit of the shot). No subject found → keep the
    /// original and re-show it.
    private func removeBackground(at fileURL: URL) {
        guard let data = bytes(at: fileURL) else { return }
        Task { @MainActor in
            // Loads the HD model on first use; nil falls back to Apple Vision.
            let hd = await HDBackgroundModelManager.shared.prepared()
            let cutout = await Task.detached(priority: .userInitiated) {
                BackgroundRemovalService.cutout(imageData: data, using: hd)
            }.value
            guard let cutout else {
                SoundEffects.play(.discard)
                self.present(at: fileURL)
                return
            }
            self.overwrite(cutout, at: fileURL)
            self.copyToPasteboard(cutout, fileURL: fileURL)
            SoundEffects.play(.copy)
            self.present(at: fileURL)
        }
    }

    // MARK: Reading a card's file

    /// A card can outlive its file — the user deleted it, an external cleaner
    /// ate it, the volume went away. Fail loudly: a button that silently does
    /// nothing is worse than the memory this indirection buys back, so the card
    /// (and any detail window on it) goes away with a sound.
    private func missing(_ url: URL, _ reason: String) {
        logger.error("capture unreadable: \(reason, privacy: .public)")
        SoundEffects.play(.discard)
        preview.dismissCards(backedBy: url)
    }

    private func bytes(at url: URL) -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch {
            missing(url, error.localizedDescription)
            return nil
        }
    }

    /// Full-resolution decode straight off the file — no intermediate `Data` +
    /// `NSImage` copy of a multi-megapixel capture.
    private func decode(at url: URL) -> CGImage? {
        guard let cg = CaptureImage.decode(at: url) else {
            missing(url, "not a decodable image")
            return nil
        }
        return cg
    }

    /// Replaces an already-saved shot after an edit (markup, background
    /// removal). Atomic: a plain `write(to:)` truncates first, so a full disk or
    /// an unmounted external screenshot folder left the original 0-byte while
    /// the UI still showed the edit as saved.
    private func overwrite(_ data: Data, at fileURL: URL) {
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("screenshot overwrite failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Supplies the TIFF representation only if a paste target actually asks for
    /// it. Holds the compressed PNG (already in memory) and decodes + re-encodes
    /// on demand, so the common capture pays nothing for a representation almost
    /// nobody requests now that `.png` is on the pasteboard too.
    final class TIFFPromise: NSObject, NSPasteboardItemDataProvider {
        private let pngData: Data
        /// How many times a paste target actually asked for the TIFF. The point of
        /// the promise is that this stays 0 for a capture nobody pastes as TIFF.
        private(set) var fulfillments = 0

        init(pngData: Data) {
            self.pngData = pngData
            super.init()
        }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {
            guard type == .tiff, let tiff = NSImage(data: pngData)?.tiffRepresentation else { return }
            fulfillments += 1
            item.setData(tiff, forType: .tiff)
        }
    }

    /// The one pasteboard item a capture writes: the saved file's URL, the PNG
    /// bytes, and a promise for TIFF. Factored out so the representation set is
    /// testable against a private named pasteboard — never `.general`, which is
    /// the user's real clipboard (and feeds clipboard history).
    static func pasteboardItem(pngData: Data, fileURL: URL) -> (NSPasteboardItem, TIFFPromise) {
        let item = NSPasteboardItem()
        item.setString(fileURL.absoluteString, forType: .fileURL)
        let promise = TIFFPromise(pngData: pngData)
        item.setDataProvider(promise, forTypes: [.tiff])
        item.setData(pngData, forType: .png)
        return (item, promise)
    }

    /// Keeps the most recent promise alive for as long as its data might be
    /// requested — the pasteboard item is the owner, but a stale promise costs one
    /// `Data` reference and this removes any doubt about fulfilling a late paste.
    private var pasteboardPromise: TIFFPromise?

    /// Clipboard write for a card, reading the file at click time. False when
    /// the file is gone — the caller then skips its "copied" feedback.
    @discardableResult
    private func copyToPasteboard(at url: URL) -> Bool {
        guard let data = bytes(at: url) else { return false }
        copyToPasteboard(data, fileURL: url)
        return true
    }

    private func copyToPasteboard(_ pngData: Data, fileURL: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Write the saved file's URL first so targets that take a FILE paste
        // (terminals, Finder, this very chat) accept it — matching how a
        // CleanShot paste lands as a path. Bitmap-only left those unable to
        // paste at all; the bitmap types below still serve image editors that
        // want an inline Cmd+V image. One item, three representations.
        // TIFF is PROMISED, not encoded now: building it meant a full PNG decode
        // plus an uncompressed re-encode (~81 MB for a 6K shot) on the main actor
        // between the shutter and the preview card, on every single capture. The
        // type is still advertised, so an editor that only takes TIFF still gets
        // it — AppKit calls back for the bytes at paste time.
        let (item, promise) = Self.pasteboardItem(pngData: pngData, fileURL: fileURL)
        pasteboardPromise = promise
        pasteboard.writeObjects([item])
    }
}
