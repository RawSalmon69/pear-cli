import Foundation

/// Something wrong right now that the cat should say. Cases are declared in
/// priority order, highest first, so `min()` is the one to show: Screen
/// Recording and Accessibility problems go above `diskNearlyFull` when they
/// arrive.
enum PanelProblem: Comparable {
    case diskNearlyFull

    var message: String {
        switch self {
        case .diskNearlyFull: "Your disk is nearly full"
        }
    }

    /// The problems the panel can currently detect.
    static func current(diskUsedFraction: Double?) -> [PanelProblem] {
        guard let diskUsedFraction, diskUsedFraction > 0.9 else { return [] }
        return [.diskNearlyFull]
    }
}

/// The panel's one decision point, pure so it is testable without AppKit: given
/// the enabled tools, the pins, the search text and the current problems, which
/// tiles and rows show, which one is selected, what a key press does, and what
/// the cat says. The view renders this and forwards keys; it decides nothing itself.
///
/// Arrows walk one linear order, the pinned tiles left to right and then the
/// list, so Return on open runs the first pinned tool and every tool is
/// reachable from the keyboard.
struct PanelModel {
    /// One tool as the list sees it.
    struct Entry: Equatable {
        let id: String
        let title: String
        let icon: String
        /// The tool's one-line description. Searched, not shown.
        let summary: String
        var aliases: [String] = []
        var shortcut: String?

        var shortcutText: String { shortcut ?? "no shortcut" }

        func matches(_ query: String) -> Bool {
            ([title, summary] + aliases).contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    enum Key: Equatable {
        case up, down, enter, escape
        case typed(String)
    }

    enum Command: Equatable {
        case run(String)
        case close
    }

    static let pinSlots = 4

    /// Enabled tools with a row, in offer order.
    var entries: [Entry]
    var problems: [PanelProblem]
    /// The user's pinned ids in order, enabled or not (`Prefs.pinnedTools`).
    private(set) var pins: [String]
    private(set) var pickYourFourDismissed: Bool
    /// An unseen couple note. The caller passes false unless `FeatureFlags.coupleNote`.
    var hasUnseenNote = false
    private(set) var query = ""
    /// The raw selection, held by the view between renders; read `selectedIndex`.
    private(set) var selection = 0

    init(entries: [Entry], problems: [PanelProblem],
         pins: [String] = Prefs.defaultPinnedTools, pickYourFourDismissed: Bool = false,
         hasUnseenNote: Bool = false, query: String = "", selection: Int = 0) {
        self.entries = entries
        self.problems = problems
        self.pins = pins
        self.pickYourFourDismissed = pickYourFourDismissed
        self.hasUnseenNote = hasUnseenNote
        self.query = query
        self.selection = selection
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// The fill rule: the enabled pins in the user's order, then enabled
    /// unpinned tools in offer order, up to four. Fewer enabled tools give
    /// fewer tiles, never placeholders.
    private var filledPins: [Entry] {
        var tiles: [Entry] = []
        for id in pins {
            if let entry = entries.first(where: { $0.id == id }), !tiles.contains(entry) {
                tiles.append(entry)
            }
        }
        for entry in entries where !tiles.contains(entry) { tiles.append(entry) }
        return Array(tiles.prefix(Self.pinSlots))
    }

    /// The pinned row. Hidden while searching: results then span every tool.
    var pinned: [Entry] { trimmedQuery.isEmpty ? filledPins : [] }

    /// The list: tools not in the pinned row, or every match while searching.
    var rows: [Entry] {
        let query = trimmedQuery
        guard query.isEmpty else { return entries.filter { $0.matches(query) } }
        let pinned = filledPins
        return entries.filter { !pinned.contains($0) }
    }

    /// The one-time card, until dismissed or any pin changes; not while searching.
    var showsPickYourFour: Bool { !pickYourFourDismissed && trimmedQuery.isEmpty }

    /// Whether the right-click menu offers Unpin. A tile that only fills an
    /// empty slot is not a pin, so it offers Pin, which keeps it there.
    func isPinned(_ id: String) -> Bool { pins.contains(id) }

    /// Unpin drops the id and pins the next tools in offer order into the
    /// freed slot, so the slot never refills with the tool just unpinned. Pin
    /// appends the id, unless four enabled pins already show: then it takes the
    /// fourth tile's place. Disabled pins are kept, so a tool switched back on
    /// returns to its slot.
    mutating func togglePin(_ id: String) {
        if let index = pins.firstIndex(of: id) {
            pins.remove(at: index)
            for entry in entries where entry.id != id && !pins.contains(entry.id) {
                guard enabledPinIndices.count < Self.pinSlots else { break }
                pins.append(entry.id)
            }
        } else {
            let enabled = enabledPinIndices
            if enabled.count >= Self.pinSlots {
                pins[enabled[Self.pinSlots - 1]] = id
            } else {
                pins.append(id)
            }
        }
        pickYourFourDismissed = true
    }

    private var enabledPinIndices: [Int] {
        pins.indices.filter { index in entries.contains { $0.id == pins[index] } }
    }

    mutating func dismissPickYourFour() { pickYourFourDismissed = true }

    /// Tiles then rows: the order the arrows walk.
    private var selectable: [Entry] { pinned + rows }

    var showsNoMatch: Bool { !trimmedQuery.isEmpty && rows.isEmpty }

    /// Clamped on read, so a list that shrank under the selection (a tool
    /// switched off in Settings) still points at a real row.
    var selectedIndex: Int? {
        let count = selectable.count
        return count == 0 ? nil : min(max(selection, 0), count - 1)
    }

    var selectedID: String? { selectedIndex.map { selectable[$0].id } }

    var catLine: String { problems.min()?.message ?? "" }

    var mood: MascotMood {
        if !problems.isEmpty { return .worried }
        return hasUnseenNote ? .excited : .idle
    }

    mutating func handle(_ key: Key) -> Command? {
        switch key {
        case .up:
            selection = max((selectedIndex ?? 0) - 1, 0)
        case .down:
            selection = min((selectedIndex ?? 0) + 1, max(selectable.count - 1, 0))
        case .enter:
            return selectedID.map(Command.run)
        case .escape:
            guard query.isEmpty else {
                query = ""
                selection = 0
                return nil
            }
            return .close
        case .typed(let text):
            query = text
            selection = 0
        }
        return nil
    }
}
