import Foundation
import Observation

// Model shape adapted from Radix (MIT), https://github.com/colinvkim/Radix,
// commit 6c694377 (ViewModels/AppModel.swift's DiscardPileState /
// DiscardPileSummary and its stage / remove / clear / move-to-trash flow): a
// staged set carried alongside an item-count + total-size summary, with items
// individually removable and the whole pile emptied through one Move-to-Trash
// action. Radix keys its pile by node IDs against a scan snapshot and hides
// staged nodes by recomputing the entire visualization; a menu-bar chart needs
// far less, so we key by absolute path and mark staged items cheaply. The
// staging model here is deliberately pure — no disk access — which is why it is
// a fresh, minimal re-implementation rather than a line copy.

/// The disk tool's two-phase deletion pile ("Pending deletion"). "Delete" on
/// any item stages it here; nothing is removed from disk until "Delete all"
/// runs every staged path through `DiskDeletion`'s single Trash sink. Every
/// method on this model is a pure in-memory list edit — the disk touch lives
/// only in the "Delete all" flow.
@MainActor
@Observable
final class DiskStagingModel {
    private(set) var items: [StagedItem] = []
    /// Bumped after a "Delete all" that trashed at least one path, so the active
    /// chart/bars view can prune the just-trashed paths (in `lastTrashed`) from
    /// its own data without a rescan.
    private(set) var trashGeneration = 0
    private(set) var lastTrashed: Set<String> = []

    /// One staged path awaiting Trash. Identified by its absolute path, so the
    /// same file can't be staged twice and matches across chart re-scans.
    struct StagedItem: Identifiable, Equatable, Sendable {
        var id: String { path }
        let name: String
        let path: String
        let size: Int64
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var stagedPaths: Set<String> { Set(items.map(\.path)) }
    /// Insertion-ordered paths — the order "Delete all" trashes in.
    var orderedPaths: [String] { items.map(\.path) }

    func isStaged(_ path: String) -> Bool { items.contains { $0.path == path } }

    /// Stages `path` for deletion. Refuses anything `DiskDeletion.canTrash`
    /// won't allow (the same home guard the sink enforces) and ignores a
    /// duplicate. Returns true only when a new item was added. Pure.
    @discardableResult
    func stage(name: String, path: String, size: Int64, home: String = NSHomeDirectory()) -> Bool {
        guard DiskDeletion.canTrash(path: path, home: home) else { return false }
        guard !isStaged(path) else { return false }
        items.append(StagedItem(name: name, path: path, size: size))
        return true
    }

    /// Cancels one staged item, returning it to the chart un-marked. Pure.
    func restore(path: String) { items.removeAll { $0.path == path } }

    /// Cancels the whole pile without touching disk. Pure.
    func clear() { items.removeAll() }

    /// Drops the paths a completed "Delete all" moved to Trash and signals the
    /// active view (via `trashGeneration` + `lastTrashed`) to prune them. Paths
    /// that failed to trash stay staged. Pure — the recycle already happened in
    /// `DiskDeletion`.
    func removeTrashed(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let set = Set(paths)
        items.removeAll { set.contains($0.path) }
        lastTrashed = set
        trashGeneration += 1
    }
}
