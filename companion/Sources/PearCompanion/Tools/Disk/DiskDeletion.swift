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

    /// Standardizes a path (resolves `..`/`.`, strips trailing slashes) so the
    /// prefix comparisons above can't be fooled by traversal or formatting.
    private static func cleaned(_ path: String) -> String {
        var result = (path as NSString).standardizingPath
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

/// The mandatory confirmation-and-trash flow shared by every disk view. Shows
/// a `.critical` alert naming the item, its full path, and human size; only an
/// explicit "Move to Trash" proceeds. Returns `true` when the item was trashed.
@MainActor
enum DiskTrashPrompt {
    static func confirmAndTrash(name: String, path: String, size: Int64) async -> Bool {
        guard DiskDeletion.canTrash(path: path) else { return false }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Move “\(name)” to Trash?"
        alert.informativeText = "\(path)\n\(ByteFormat.si(size))\n\nYou can restore it from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        do {
            try await DiskDeletion.moveToTrash(URL(fileURLWithPath: path))
            return true
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Couldn’t move “\(name)” to Trash."
            failure.informativeText = error.localizedDescription
            failure.addButton(withTitle: "OK")
            failure.runModal()
            return false
        }
    }
}
