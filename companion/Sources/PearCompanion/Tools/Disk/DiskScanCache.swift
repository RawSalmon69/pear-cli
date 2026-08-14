import Foundation

/// The last finished disk scan, kept on disk so the Disk window opens on the
/// previous result instead of a spinner. The native walk costs ~26 s warm and
/// ~2 min cold over a full home folder — a wait worth paying once, not on every
/// open.
///
/// Same shape as `CaptureStore`: an app-owned folder under Application Support,
/// with every path injectable so tests never touch the real one. Unlike the
/// shelf index or the scratchpad notes this is *derived* data — a file that
/// does not decode is deleted rather than preserved, because losing it costs
/// one rescan and keeping it risks showing numbers we cannot read.
enum DiskScanCache {
    /// Past this the cache is still shown — instantly, which is the point — but
    /// labelled as possibly out of date rather than presented as live.
    static let staleAfter: TimeInterval = 24 * 60 * 60

    /// How many levels below the scan root are persisted.
    ///
    /// Measured on a 276 GB home folder: the scanner's full 10-level tree is
    /// **1,096,181 nodes / 211.6 MB** of JSON, taking 2.8 s to write and 2.4 s
    /// to read — nothing that size belongs in Application Support, and the read
    /// alone would cost more than it saves. Five levels is **57,745 nodes /
    /// 9.3 MB**, written in 0.15 s and read in 0.11 s, which is under the
    /// threshold where the window looks like it waited. (Six would be 21.7 MB
    /// and 0.26 s; four, 3.7 MB and 0.05 s.)
    ///
    /// What that drops is drill-in detail: a directory at the cap keeps its
    /// true total and simply stops being drillable, exactly how the scanner's
    /// own depth cap already reads. Five is the deepest either chart draws from
    /// the scan root (sunburst 5, treemap 4), so the opening screen is
    /// identical to a fresh scan's; only drilling goes shallower, and Rescan
    /// restores the full ten.
    static let maxDepth = 5

    /// `~/Library/Application Support/PearCompanion/DiskScan/scan.json`, next
    /// to the capture store.
    static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("PearCompanion/DiskScan", isDirectory: true)
            .appendingPathComponent("scan.json")
    }

    /// One cached scan: the tree, what was scanned, and when.
    struct Snapshot: Codable, Sendable {
        let scannedPath: String
        let scannedAt: Date
        let root: DiskNode
    }

    /// Reads the cache, or nil when there isn't one. A file that fails to
    /// decode is deleted on the spot: a corrupt cache must be no worse than no
    /// cache, and leaving it there would fail the same way on every open.
    static func load(from url: URL = fileURL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return snapshot
    }

    /// Writes `root` as the cache, depth-capped. Best-effort: a failed write
    /// just means the next open scans, so there is nothing to report.
    static func save(root: DiskNode, scannedPath: String, scannedAt: Date,
                     to url: URL = fileURL, maxDepth: Int = DiskScanCache.maxDepth) {
        let snapshot = Snapshot(scannedPath: scannedPath, scannedAt: scannedAt,
                                root: pruned(root, depth: maxDepth))
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Copy of `node` with everything more than `depth` levels below it
    /// dropped. Sizes are untouched, so a cut directory keeps its true total.
    static func pruned(_ node: DiskNode, depth: Int) -> DiskNode {
        guard depth > 0, !node.children.isEmpty else {
            return DiskNode(id: node.id, name: node.name, size: node.size,
                            isDirectory: node.isDirectory, children: [])
        }
        return DiskNode(id: node.id, name: node.name, size: node.size,
                        isDirectory: node.isDirectory,
                        children: node.children.map { pruned($0, depth: depth - 1) })
    }

    // MARK: - Age

    /// True once the cache is old enough that it should be read as history
    /// rather than as the current state of the disk.
    static func isStale(scannedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(scannedAt) >= staleAfter
    }

    /// "scanned 2 hours ago", plus an explicit warning once it is stale. The
    /// user must never be looking at week-old numbers believing they are live.
    static func ageLabel(scannedAt: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(scannedAt))
        let label: String
        switch seconds {
        case ..<60:
            label = "scanned just now"
        case ..<3600:
            label = "scanned \(count(seconds / 60, "minute")) ago"
        case ..<86_400:
            label = "scanned \(count(seconds / 3600, "hour")) ago"
        default:
            label = "scanned \(count(seconds / 86_400, "day")) ago"
        }
        return isStale(scannedAt: scannedAt, now: now) ? label + " · may be out of date" : label
    }

    private static func count(_ value: Double, _ unit: String) -> String {
        let whole = max(1, Int(value))
        return "\(whole) \(unit)\(whole == 1 ? "" : "s")"
    }
}
