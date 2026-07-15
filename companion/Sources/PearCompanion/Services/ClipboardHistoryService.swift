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

    var isImage: Bool { imageData != nil }
}

/// Menu-bar clipboard history: polls the pasteboard and keeps the last N
/// text/image copies so they can be re-used with a click. Text history
/// persists across launches; images are kept in memory only.
@MainActor
@Observable
final class ClipboardHistoryService {
    private(set) var items: [ClipItem] = []

    @ObservationIgnored private let maxItems = 20
    /// Images are capped by total bytes, not count — one 8K screenshot
    /// costs what it costs, many small ones can coexist.
    @ObservationIgnored private let maxImageBytes = 10 * 1024 * 1024
    @ObservationIgnored private let textDefaultsKey = "clipboardTextHistory"
    @ObservationIgnored private var lastChangeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var timer: Timer?
    /// Set when we write to the pasteboard ourselves, so re-copying an existing
    /// item doesn't churn the list.
    @ObservationIgnored private var selfCopyGuard = false

    init() {
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

    func clear() {
        items.removeAll()
        persistText()
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

    private func add(_ item: ClipItem) {
        // Skip if identical to the newest entry.
        if let first = items.first,
           first.text == item.text, first.imageData == item.imageData {
            return
        }
        items.insert(item, at: 0)
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
        enforceImageBudget()
        persistText()
    }

    /// Drops the oldest image entries until stored image bytes fit the cap.
    private func enforceImageBudget() {
        var total = items.compactMap(\.imageData?.count).reduce(0, +)
        while total > maxImageBytes {
            guard let index = items.lastIndex(where: { $0.imageData != nil }) else { break }
            total -= items[index].imageData?.count ?? 0
            items.remove(at: index)
        }
    }

    // MARK: - Text persistence

    private func persistText() {
        let texts = items.compactMap(\.text).prefix(maxItems)
        UserDefaults.standard.set(Array(texts), forKey: textDefaultsKey)
    }

    private func loadPersistedText() {
        let texts = UserDefaults.standard.stringArray(forKey: textDefaultsKey) ?? []
        items = texts.map { ClipItem(text: $0, imageData: nil, thumbnail: nil, date: Date()) }
    }
}
