import AppKit
import Observation
import UniformTypeIdentifiers

/// One held file: a copy that lives in the shelf's own directory (so it
/// survives deletion of the source) plus the original name for display.
/// `thumbnail` is decoded once at add/load time and never persisted.
struct ShelfEntry: Identifiable {
    let id: UUID
    /// Absolute path of the copy inside the shelf directory.
    let storedPath: String
    /// The dropped file's original name, shown in the row.
    let originalName: String
    let addedAt: Date
    /// Small preview for image files; nil for everything else (rows fall back
    /// to the Finder file icon).
    let thumbnail: NSImage?

    var url: URL { URL(fileURLWithPath: storedPath) }
}

/// Holds the shelf's items and owns their on-disk copies. Mirrors
/// `ClipboardHistoryService`'s shape: `@MainActor @Observable`, so a SwiftUI
/// row re-renders when `items` changes and nothing crosses an actor boundary.
///
/// Storage layout, all under one directory (default
/// `~/Library/Application Support/PearCompanion/Shelf/`):
///   - each held file is copied in beside the others, Finder-style unique
///     suffix on name collision;
///   - `index.json` records the copies (stored path, original name, date).
/// `root` is injectable so tests never touch real Application Support.
@MainActor
@Observable
final class ShelfStore {
    private(set) var items: [ShelfEntry] = []

    /// The row the pointer is over. Drives the hover highlight and is the
    /// target for ⌘C / the copy button. Kept on the store (not the view) so
    /// the window controller's key monitor can resolve the copy target.
    var hoveredID: UUID?

    @ObservationIgnored private let root: URL
    @ObservationIgnored private var indexURL: URL { root.appendingPathComponent("index.json") }

    static var defaultRoot: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PearCompanion/Shelf", isDirectory: true)
    }

    init(root: URL = ShelfStore.defaultRoot) {
        self.root = root
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        load()
    }

    /// Copies `source` into the shelf directory and adds it to the top of the
    /// list. The copy is what makes items survive the source being deleted.
    func add(_ source: URL) {
        guard source.isFileURL else { return }
        let preferred = root.appendingPathComponent(source.lastPathComponent)
        let dest = Self.uniqueDestination(for: preferred)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            NSLog("Shelf: copy failed for \(source.lastPathComponent) — \(error)")
            return
        }
        let entry = ShelfEntry(
            id: UUID(),
            storedPath: dest.path,
            originalName: source.lastPathComponent,
            addedAt: Date(),
            thumbnail: Self.thumbnail(for: dest)
        )
        items.insert(entry, at: 0)
        save()
    }

    /// Removes an item and moves its stored copy to the Trash (recoverable —
    /// never a bare `removeItem` on user-visible data).
    func remove(_ entry: ShelfEntry) {
        items.removeAll { $0.id == entry.id }
        try? FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        save()
    }

    // MARK: - Paste in / copy out

    /// A file to feed to `add`, plus whether it is a throwaway temp we created
    /// (and should delete once it has been copied into the shelf).
    struct IngestSource: Equatable {
        let url: URL
        let isTemporary: Bool
    }

    /// Adds whatever is on `pasteboard` to the shelf, reusing the same
    /// copy-into-shelf path as a drag-in. File URLs are copied directly; image
    /// data and plain text are written to a temp file first so they flow
    /// through `add` exactly like a dropped file. Returns the count added.
    @discardableResult
    func ingest(from pasteboard: NSPasteboard = .general) -> Int {
        let sources = Self.ingestSources(from: pasteboard)
        for source in sources {
            add(source.url)
            // `add` copies, so the temp original can go once it is in.
            if source.isTemporary {
                try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent())
            }
        }
        return sources.count
    }

    /// Puts `entry` on the pasteboard the way Finder copies a file: the file
    /// URL (so paste into Finder/apps drops the file) plus, for image entries,
    /// the image itself so image editors receive pixels. Mirrors the drag-out,
    /// which also vends `url as NSURL`.
    func copy(_ entry: ShelfEntry, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        var objects: [NSPasteboardWriting] = [entry.url as NSURL]
        if let type = UTType(filenameExtension: entry.url.pathExtension),
           type.conforms(to: .image), let image = NSImage(contentsOf: entry.url) {
            objects.append(image)
        }
        pasteboard.writeObjects(objects)
        SoundEffects.play(.copy)
    }

    /// Copies the hovered row out, falling back to the top item — the ⌘C path.
    @discardableResult
    func copyHovered(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let target = items.first(where: { $0.id == hoveredID }) ?? items.first
        else { return false }
        copy(target, to: pasteboard)
        return true
    }

    /// Maps a pasteboard's contents to files ready for `add`, materializing a
    /// temp file for image / text payloads. File URLs win when present, then
    /// image data, then plain text. Static and pasteboard-injectable so the
    /// mapping is unit-testable without the general pasteboard.
    static func ingestSources(from pasteboard: NSPasteboard) -> [IngestSource] {
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let files = objects.filter(\.isFileURL)
            if !files.isEmpty { return files.map { IngestSource(url: $0, isTemporary: false) } }
        }
        if let png = pasteboard.data(forType: .png),
           let url = writeTemp(png, filename: "Pasted Image.png") {
            return [IngestSource(url: url, isTemporary: true)]
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let url = writeTemp(tiff, filename: "Pasted Image.tiff") {
            return [IngestSource(url: url, isTemporary: true)]
        }
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let url = writeTemp(Data(text.utf8), filename: "Pasted Text.txt") {
            return [IngestSource(url: url, isTemporary: true)]
        }
        return []
    }

    /// Writes pasted bytes to a uniquely-named temp directory so the display
    /// name stays clean; the caller feeds it to `add` and then deletes it.
    private static func writeTemp(_ data: Data, filename: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfPaste-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(filename)
            try data.write(to: url)
            return url
        } catch {
            NSLog("Shelf: temp write failed for \(filename) — \(error)")
            return nil
        }
    }

    // MARK: - Persistence

    private struct PersistedEntry: Codable {
        let id: UUID
        let storedPath: String
        let originalName: String
        let addedAt: Date
    }

    private struct PersistedIndex: Codable {
        let version: Int
        let items: [PersistedEntry]
    }

    private func save() {
        let records = items.map {
            PersistedEntry(
                id: $0.id, storedPath: $0.storedPath,
                originalName: $0.originalName, addedAt: $0.addedAt)
        }
        do {
            let data = try JSONEncoder().encode(PersistedIndex(version: 1, items: records))
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NSLog("Shelf: index save failed — \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(PersistedIndex.self, from: data)
        else { return }
        // Drop entries whose stored copy has vanished so the list stays honest.
        items = index.items.compactMap { record in
            let url = URL(fileURLWithPath: record.storedPath)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return ShelfEntry(
                id: record.id,
                storedPath: record.storedPath,
                originalName: record.originalName,
                addedAt: record.addedAt,
                thumbnail: Self.thumbnail(for: url)
            )
        }
    }

    // MARK: - Helpers

    private static func thumbnail(for url: URL) -> NSImage? {
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image) else { return nil }
        // 64 px long side — rows are ~32 pt, so this stays crisp @2x without
        // ever decoding the full bitmap (Thumbnail downsamples via ImageIO).
        return Thumbnail.image(at: url, maxPixel: 64)
    }

    /// Finder-style "name (1)", "name (2)" suffix resolver.
    /// Adapted from Dropshit (MIT), `Conversion/UniqueDestination.swift`.
    private static func uniqueDestination(for preferred: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: preferred.path) else { return preferred }
        let dir = preferred.deletingLastPathComponent()
        let ext = preferred.pathExtension
        let stem = preferred.deletingPathExtension().lastPathComponent
        var i = 1
        while true {
            var candidate = dir.appendingPathComponent("\(stem) (\(i))")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}
