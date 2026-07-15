import AppKit
import Observation

/// One remembered clipboard entry.
struct ClipItem: Identifiable, Equatable {
    let id = UUID()
    let text: String?
    let imageData: Data?
    /// Small preview decoded once at capture, so list rows never inflate
    /// the full bitmap.
    let thumbnail: NSImage?
    let date: Date
    /// Pinned items survive eviction and `clear()`, and sort first.
    var pinned = false

    var isImage: Bool { imageData != nil }
}

/// Menu-bar clipboard history: polls the pasteboard and keeps recent
/// text/image copies so they can be re-used with a click. Text history and
/// pins persist across launches; images are kept in memory only.
/// Pin/search behavior adapted from Maccy (MIT), reimplemented on our store.
@MainActor
@Observable
final class ClipboardHistoryService {
    private(set) var items: [ClipItem] = []

    /// Count cap for unpinned entries; pins are exempt.
    @ObservationIgnored private let maxItems = 50
    /// Unpinned images are capped by total bytes, not count — one 8K
    /// screenshot costs what it costs, many small ones can coexist.
    @ObservationIgnored private let maxImageBytes = 10 * 1024 * 1024
    @ObservationIgnored private let textDefaultsKey = "clipboardTextHistory"
    @ObservationIgnored private let pinnedDefaultsKey = "clipboardPinnedHistory"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastChangeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var timer: Timer?
    /// Set when we write to the pasteboard ourselves, so re-copying an existing
    /// item doesn't churn the list.
    @ObservationIgnored private var selfCopyGuard = false

    /// `defaults` is injectable so tests never touch the real domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadPersistedText()
    }

    func start() {
        guard timer == nil else { return }
        // 2 s is the accepted staleness for history capture; 1 s doubled the
        // idle wakeups for no perceptible gain.
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func copy(_ item: ClipItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let text = item.text {
            pasteboard.setString(text, forType: .string)
        } else if let data = item.imageData {
            pasteboard.setData(data, forType: .png)
        }
        selfCopyGuard = true
        lastChangeCount = pasteboard.changeCount
        SoundEffects.play(.copy)
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        persistText()
    }

    /// Clears the unpinned history; pins stay (Maccy behavior).
    func clear() {
        items.removeAll { !$0.pinned }
        persistText()
    }

    func togglePin(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle()
        persistText()
    }

    /// Display order: pins first (newest pin first), then the rest newest
    /// first, filtered by a case-insensitive substring when `query` is set.
    func display(matching query: String) -> [ClipItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let visible = trimmed.isEmpty ? items : items.filter {
            $0.text?.localizedCaseInsensitiveContains(trimmed) ?? false
        }
        return visible.filter(\.pinned) + visible.filter { !$0.pinned }
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        if selfCopyGuard {
            selfCopyGuard = false
            return
        }

        if let string = pasteboard.string(forType: .string),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(ClipItem(text: string, imageData: nil, thumbnail: nil, date: Date()))
        } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            let thumb = Thumbnail.image(from: data, maxPixel: 60)
            add(ClipItem(text: nil, imageData: data, thumbnail: thumb, date: Date()))
        }
    }

    /// Internal (not private) so store-logic tests can feed items without a
    /// real pasteboard.
    func add(_ item: ClipItem) {
        // Skip if identical to the newest entry.
        if let first = items.first,
           first.text == item.text, first.imageData == item.imageData {
            return
        }
        items.insert(item, at: 0)
        enforceCountCap()
        enforceImageBudget()
        persistText()
    }

    /// Drops the oldest unpinned entries beyond the count cap.
    private func enforceCountCap() {
        var unpinned = items.filter { !$0.pinned }.count
        while unpinned > maxItems {
            guard let index = items.lastIndex(where: { !$0.pinned }) else { break }
            items.remove(at: index)
            unpinned -= 1
        }
    }

    /// Drops the oldest unpinned image entries until stored image bytes fit
    /// the cap. Pinned images are exempt — bounded by explicit user intent.
    private func enforceImageBudget() {
        var total = items.filter { !$0.pinned }.compactMap(\.imageData?.count).reduce(0, +)
        while total > maxImageBytes {
            guard let index = items.lastIndex(where: { $0.imageData != nil && !$0.pinned }) else { break }
            total -= items[index].imageData?.count ?? 0
            items.remove(at: index)
        }
    }

    // MARK: - Text persistence

    private func persistText() {
        let texts = items.filter { !$0.pinned }.compactMap(\.text).prefix(maxItems)
        defaults.set(Array(texts), forKey: textDefaultsKey)
        let pinnedTexts = items.filter(\.pinned).compactMap(\.text)
        defaults.set(pinnedTexts, forKey: pinnedDefaultsKey)
    }

    private func loadPersistedText() {
        let pinnedTexts = defaults.stringArray(forKey: pinnedDefaultsKey) ?? []
        let texts = defaults.stringArray(forKey: textDefaultsKey) ?? []
        items = pinnedTexts.map {
            ClipItem(text: $0, imageData: nil, thumbnail: nil, date: Date(), pinned: true)
        } + texts.map {
            ClipItem(text: $0, imageData: nil, thumbnail: nil, date: Date())
        }
    }
}
