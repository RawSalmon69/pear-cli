import AppKit
import Foundation

// The disk tool's ONLY deletion path. Every Trash action in the sunburst,
// treemap, and bars views funnels through here so the safety guard and the
// single recoverable sink can never be bypassed.

enum DiskDeletionError: Error {
    /// The path failed `canTrash` — refused before any filesystem call.
    case refused
}

enum DiskDeletion {
    /// Pure, side-effect-free guard deciding whether `path` may be trashed.
    ///
    /// The one rule that actually protects the user is the last one: a path
    /// must live *strictly inside* `home`. Everything above it is explicit,
    /// individually testable defense-in-depth. `home` is injectable so the
    /// guard can be unit-tested against a synthetic home; production passes
    /// `NSHomeDirectory()`.
    ///
    /// Refuses: the filesystem root, home itself and any ancestor of it,
    /// `/System` `/Library` `/usr` `/bin` `/sbin` `/private` `/Applications`
    /// `/opt` (and their subtrees), a bare `/Volumes/<name>` mount root, any
    /// path with fewer than 3 components, and anything outside `home`.
    static func canTrash(path: String, home: String = NSHomeDirectory()) -> Bool {
        let target = cleaned(path)
        let homeDir = cleaned(home)
        guard !target.isEmpty, !homeDir.isEmpty, target.hasPrefix("/") else { return false }

        // Reject shallow paths outright: "/" (1), "/Users" (2), a mount root (3).
        let components = URL(fileURLWithPath: target).pathComponents
        guard components.count >= 3 else { return false }

        // A bare volume mount root, e.g. "/Volumes/Backup".
        if components.count == 3, components[1] == "Volumes" { return false }

        // Known system roots and anything beneath them.
        let forbiddenRoots = [
            "/System", "/Library", "/usr", "/bin", "/sbin",
            "/private", "/Applications", "/opt",
        ]
        for root in forbiddenRoots where target == root || target.hasPrefix(root + "/") {
            return false
        }

        // Master rule: only paths strictly inside the user's home. This alone
        // rejects the root, home's ancestors, and every location above.
        if target == homeDir { return false }
        return target.hasPrefix(homeDir + "/")
    }

    /// The single deletion sink for the disk tool. Re-checks `canTrash` as a
    /// hard gate, then moves the item to the Trash.
    @MainActor
    static func moveToTrash(_ url: URL, home: String = NSHomeDirectory()) async throws {
        guard canTrash(path: url.path, home: home) else { throw DiskDeletionError.refused }
        // SAFE: NSWorkspace.recycle moves the item to the user's Trash — fully
        // recoverable from Finder. This is the ONLY delete path in the disk
        // tool. We never call FileManager.removeItem / unlink / rmdir, and we
        // never shell out to `rm`; nothing here deletes irrecoverably.
        _ = try await NSWorkspace.shared.recycle([url])
    }

    /// Batch form for the two-phase "Delete all": funnels every staged path
    /// through the SAME single `moveToTrash` sink, one at a time, so each path
    /// is re-checked by `canTrash` at trash time (not only when it was staged).
    /// Returns the paths that reached the Trash and those refused or failed, so
    /// the caller prunes exactly the trashed ones and leaves failures staged.
    /// This is the only disk-touching step of staged deletion.
    @MainActor
    static func moveAllToTrash(
        _ paths: [String], home: String = NSHomeDirectory()
    ) async -> (trashed: [String], failed: [String]) {
        var trashed: [String] = []
        var failed: [String] = []
        for path in paths {
            do {
                try await moveToTrash(URL(fileURLWithPath: path), home: home)
                trashed.append(path)
            } catch {
                failed.append(path)
            }
        }
        return (trashed, failed)
    }

    /// Standardizes a path (resolves `..`/`.`, strips trailing slashes) so the
    /// prefix comparisons above can't be fooled by traversal or formatting.
    private static func cleaned(_ path: String) -> String {
        var result = (path as NSString).standardizingPath
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

/// The mandatory confirmation-and-trash flow for the two-phase pile. Shows a
/// `.critical` alert naming the count and total, then trashes every staged
/// path; only an explicit "Move to Trash" proceeds.
@MainActor
enum DiskTrashPrompt {
    /// The two-phase "Delete all": one `.critical` alert naming the count and
    /// total, then a single batch trash through `DiskDeletion.moveAllToTrash`.
    /// Returns the paths that reached the Trash (empty if the user cancels).
    /// Surfaces a follow-up warning if any staged path couldn't be trashed.
    static func confirmAndTrashAll(count: Int, totalSize: Int64, paths: [String]) async -> [String] {
        guard count > 0, !paths.isEmpty else { return [] }

        let alert = NSAlert()
        alert.alertStyle = .critical
        let itemWord = count == 1 ? "item" : "items"
        alert.messageText = "Move \(count) \(itemWord) to Trash?"
        alert.informativeText = "\(ByteFormat.si(totalSize)) total\n\nYou can restore them from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return [] }

        let result = await DiskDeletion.moveAllToTrash(paths)
        if !result.failed.isEmpty {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Some items couldn’t be moved to Trash."
            failure.informativeText =
                "\(result.failed.count) of \(count) couldn’t be trashed and stay in the pending list."
            failure.addButton(withTitle: "OK")
            failure.runModal()
        }
        return result.trashed
    }
}
