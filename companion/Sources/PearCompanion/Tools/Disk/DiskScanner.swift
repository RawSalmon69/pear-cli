import Foundation

// Adapted from Radix (MIT), https://github.com/colinvkim/Radix — specifically its
// allocated-size accounting (totalFileAllocatedSize, falling back to
// fileAllocatedSize) and its bounded, symlink-safe directory walk. This is a
// fresh, minimal re-implementation of that engine's intent, not a line copy:
// Radix's production scanner is a 2000-line actor with parallel workers, atomic
// summarization, and hard-link dedup. We keep only what a compact menu-bar
// visualization needs — a cancellable, read-only, depth/entry-bounded walk that
// yields a Sendable size tree.

/// One node in a measured directory tree.
///
/// A value type, fully `Sendable`, so a background scan can hand the finished
/// tree back to the main actor without data-race risk. `children` is sorted
/// largest-first and is empty for files, symlinks, packages, and directories
/// that hit the depth/entry cap (their `size` still reflects the full subtree).
struct DiskNode: Identifiable, Sendable, Hashable {
    /// Absolute filesystem path; unique within a single scan.
    let id: String
    let name: String
    /// Total allocated bytes for this subtree (this node plus all descendants).
    let size: Int64
    let isDirectory: Bool
    let children: [DiskNode]

    var hasChildren: Bool { !children.isEmpty }

    /// Depth-first search for a descendant (or self) by path id. Used to resolve
    /// a clicked chart segment back to its node for drill-in.
    func firstDescendant(id target: String) -> DiskNode? {
        if id == target { return self }
        for child in children {
            if let found = child.firstDescendant(id: target) { return found }
        }
        return nil
    }
}

/// Read-only, cancellable disk scanner. No deletion, no mutation — it only
/// reads file sizes to build a `DiskNode` tree for the sunburst/treemap views.
enum DiskScanner {
    /// Bounds that keep a scan from exhausting memory or spinning forever on a
    /// pathological tree. `maxDepth` caps how deep nodes are *materialized*;
    /// sizes below the cap are still summed so proportions stay accurate.
    struct Limits: Sendable {
        var maxDepth: Int = 10
        var maxChildrenPerDir: Int = 200

        static let `default` = Limits()
    }

    /// Resource keys read for every entry. Kept minimal for speed.
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .nameKey,
    ]
    /// Size-only keys for subtrees we sum but don't materialize.
    private static let sizeKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    /// Scans `path` off the main actor and returns its measured tree.
    ///
    /// Cancellation flows through: cancelling the awaiting task cancels the
    /// detached worker, and the walk checks `Task.checkCancellation()` on every
    /// directory and every 128 entries, so a cancel stops it promptly and
    /// surfaces as `CancellationError`.
    static func scan(path: String, limits: Limits = .default) async throws -> DiskNode {
        let worker = Task.detached(priority: .utility) {
            try scanSubtree(at: URL(fileURLWithPath: path), depth: 0, limits: limits)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    // MARK: - Walk

    private static func scanSubtree(at url: URL, depth: Int, limits: Limits) throws -> DiskNode {
        try Task.checkCancellation()

        let values = try? url.resourceValues(forKeys: Set(keys))
        let name = values?.name ?? url.lastPathComponent
        let isSymlink = values?.isSymbolicLink ?? false
        let isDirectory = (values?.isDirectory ?? false) && !isSymlink
        let isPackage = values?.isPackage ?? false
        let ownSize = allocatedSize(values)

        // Leaves: files, symlinks (never followed), and app/package bundles.
        // A package is summed as one opaque blob rather than exposing internals.
        guard isDirectory, !isPackage else {
            let size = (isDirectory && isPackage) ? try subtreeSize(at: url) : ownSize
            return DiskNode(id: url.path, name: name, size: max(size, 0),
                            isDirectory: isDirectory, children: [])
        }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [])) ?? []

        // Materialize children only while under the depth cap; below it we still
        // sum sizes (via subtreeSize) so this directory's total stays correct.
        let materializeChildren = depth + 1 <= limits.maxDepth
        var aggregate = ownSize
        var children: [DiskNode] = []

        for (index, entry) in entries.enumerated() {
            if index % 128 == 0 { try Task.checkCancellation() }
            if materializeChildren {
                let node = try scanSubtree(at: entry, depth: depth + 1, limits: limits)
                aggregate += node.size
                children.append(node)
            } else {
                aggregate += try subtreeSize(at: entry)
            }
        }

        if !children.isEmpty {
            children.sort { $0.size > $1.size }
            children = capped(children, parentPath: url.path, limit: limits.maxChildrenPerDir)
        }

        return DiskNode(id: url.path, name: name, size: max(aggregate, 0),
                        isDirectory: true, children: children)
    }

    /// Sums allocated bytes of a subtree without building nodes. Never follows
    /// symlinks, so it cannot loop.
    private static func subtreeSize(at url: URL) throws -> Int64 {
        try Task.checkCancellation()
        let values = try? url.resourceValues(forKeys: Set(sizeKeys))
        let isSymlink = values?.isSymbolicLink ?? false
        let own = allocatedSize(values)
        guard (values?.isDirectory ?? false), !isSymlink else { return own }

        var total = own
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: sizeKeys, options: [])) ?? []
        for (index, entry) in entries.enumerated() {
            if index % 128 == 0 { try Task.checkCancellation() }
            total += try subtreeSize(at: entry)
        }
        return total
    }

    private static func allocatedSize(_ values: URLResourceValues?) -> Int64 {
        if let total = values?.totalFileAllocatedSize { return Int64(total) }
        if let allocated = values?.fileAllocatedSize { return Int64(allocated) }
        return 0
    }

    /// Keeps the largest `limit - 1` children and folds the rest into a single
    /// synthetic "N more items" node so the parent's visible children still sum
    /// to the true total. Only triggers on directories with a huge fan-out.
    private static func capped(_ nodes: [DiskNode], parentPath: String, limit: Int) -> [DiskNode] {
        guard nodes.count > limit else { return nodes }
        let kept = Array(nodes.prefix(limit - 1))
        let rest = nodes[(limit - 1)...]
        let restSize = rest.reduce(Int64(0)) { $0 + $1.size }
        let more = DiskNode(
            id: parentPath + "/\u{1F}more",
            name: "\(rest.count) more items",
            size: restSize,
            isDirectory: false,
            children: []
        )
        return kept + [more]
    }
}
