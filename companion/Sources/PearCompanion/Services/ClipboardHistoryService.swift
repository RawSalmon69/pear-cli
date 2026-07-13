import AppKit
import Combine

/// One remembered clipboard entry.
struct ClipItem: Identifiable, Equatable {
    let id = UUID()
    let text: String?
    let imageData: Data?
    let date: Date

    var isImage: Bool { imageData != nil }
}

/// Menu-bar clipboard history: polls the pasteboard and keeps the last N
/// text/image copies so they can be re-used with a click. Text history
/// persists across launches; images are kept in memory only.
@MainActor
final class ClipboardHistoryService: ObservableObject {
    @Published private(set) var items: [ClipItem] = []

    private let maxItems = 20
    private let textDefaultsKey = "clipboardTextHistory"
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    /// Set when we write to the pasteboard ourselves, so re-copying an existing
    /// item doesn't churn the list.
    private var selfCopyGuard = false

    init() {
        loadPersistedText()
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
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
            add(ClipItem(text: string, imageData: nil, date: Date()))
        } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            add(ClipItem(text: nil, imageData: data, date: Date()))
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
        persistText()
    }

    // MARK: - Text persistence

    private func persistText() {
        let texts = items.compactMap(\.text).prefix(maxItems)
        UserDefaults.standard.set(Array(texts), forKey: textDefaultsKey)
    }

    private func loadPersistedText() {
        let texts = UserDefaults.standard.stringArray(forKey: textDefaultsKey) ?? []
        items = texts.map { ClipItem(text: $0, imageData: nil, date: Date()) }
    }
}
