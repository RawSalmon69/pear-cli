import Foundation
import Observation

/// One quick note. Plain text only — `TextEditor` paste is inherently
/// plain-text, so "strip formatting on paste" is automatic, not a feature
/// this file implements.
struct ScratchpadNote: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String

    init(id: UUID = UUID(), text: String = "") {
        self.id = id
        self.text = text
    }
}

/// Scratchpad notes: JSON-backed, debounced autosave. Mirrors
/// `ClipboardHistoryService`'s shape (`@Observable @MainActor`, small
/// persisted list) rather than inventing a new persistence pattern.
@MainActor
@Observable
final class ScratchpadStore {
    private(set) var notes: [ScratchpadNote]
    private(set) var currentIndex: Int

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private static let saveDelay: Duration = .milliseconds(500)

    /// `fileURL` is injectable so tests point at a temp-dir path instead of
    /// the real Application Support location.
    init(fileURL: URL = ScratchpadStore.defaultFileURL) {
        self.fileURL = fileURL
        let loaded = Self.load(from: fileURL)
        self.notes = loaded.isEmpty ? [ScratchpadNote()] : loaded
        self.currentIndex = 0
    }

    var currentNote: ScratchpadNote { notes[currentIndex] }

    // ponytail: command parsing (math/convert/timer) is the follow-up tier —
    // this is where a parser would inspect typed text before it's stored.
    func updateText(_ text: String) {
        notes[currentIndex].text = text
        scheduleSave()
    }

    /// Inserts a fresh note right after the current one and selects it.
    func createNote() {
        notes.insert(ScratchpadNote(), at: currentIndex + 1)
        currentIndex += 1
        scheduleSave()
    }

    /// Removes the current note. Never leaves the list empty — deleting the
    /// last remaining note leaves one fresh empty note behind.
    func deleteCurrentNote() {
        notes.remove(at: currentIndex)
        if notes.isEmpty {
            notes.append(ScratchpadNote())
        }
        currentIndex = min(currentIndex, notes.count - 1)
        scheduleSave()
    }

    func next() {
        guard notes.count > 1 else { return }
        currentIndex = (currentIndex + 1) % notes.count
    }

    func previous() {
        guard notes.count > 1 else { return }
        currentIndex = (currentIndex - 1 + notes.count) % notes.count
    }

    /// Debounced autosave: ~0.5 s after typing stops.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Flushes immediately, bypassing the debounce — called on panel close
    /// so nothing typed in the last half-second is lost.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> [ScratchpadNote] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let notes = try? JSONDecoder().decode([ScratchpadNote].self, from: data) {
            return notes
        }
        // The file exists but doesn't decode. Preserve it under a timestamped
        // sibling before seeding a blank note — otherwise the next autosave
        // silently overwrites (and destroys) the user's real notes.
        let corrupt = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: corrupt)
        return []
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PearCompanion/Scratchpad", isDirectory: true)
            .appendingPathComponent("notes.json")
    }
}
