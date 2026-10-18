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
/// the enabled tools, the search text and the current problems, which rows show,
/// which one is selected, what a key press does, and what the cat says. The view
/// renders this and forwards keys; it decides nothing itself.
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

    /// Enabled tools with a row, in offer order.
    var entries: [Entry]
    var problems: [PanelProblem]
    /// An unseen couple note. The caller passes false unless `FeatureFlags.coupleNote`.
    var hasUnseenNote = false
    private(set) var query = ""
    /// The raw selection, held by the view between renders; read `selectedIndex`.
    private(set) var selection = 0

    init(entries: [Entry], problems: [PanelProblem], hasUnseenNote: Bool = false,
         query: String = "", selection: Int = 0) {
        self.entries = entries
        self.problems = problems
        self.hasUnseenNote = hasUnseenNote
        self.query = query
        self.selection = selection
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var rows: [Entry] {
        let query = trimmedQuery
        return query.isEmpty ? entries : entries.filter { $0.matches(query) }
    }

    var showsNoMatch: Bool { !trimmedQuery.isEmpty && rows.isEmpty }

    /// Clamped on read, so a list that shrank under the selection (a tool
    /// switched off in Settings) still points at a real row.
    var selectedIndex: Int? {
        let count = rows.count
        return count == 0 ? nil : min(max(selection, 0), count - 1)
    }

    var selectedID: String? { selectedIndex.map { rows[$0].id } }

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
            selection = min((selectedIndex ?? 0) + 1, max(rows.count - 1, 0))
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
