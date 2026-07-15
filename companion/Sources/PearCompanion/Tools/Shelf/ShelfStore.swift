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
