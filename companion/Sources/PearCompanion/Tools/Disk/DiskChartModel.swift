import SwiftUI
import Observation

// Chart-mode plumbing shared by the sunburst and treemap views: the scan model
// that owns a background scan, the Theme-derived color palette, and the small
// value types the two charts hand back to their host.

/// Which native visualization is showing. Bars renders the same scan tree as a
/// plain list, so it needs no style of its own.
enum DiskChartStyle: Sendable {
    case sunburst
    case treemap
}

/// A segment the pointer is over, surfaced to the host for the hover readout
/// and per-item actions (Reveal / Move to Trash). `path` is nil for a folded
/// "smaller items" wedge, which has no single file to act on.
struct DiskChartHover: Equatable, Sendable {
    let name: String
    let size: Int64
    let path: String?
}

/// One entry in a disk item's right-click menu. Path-based so the SwiftUI
/// `.contextMenu` (treemap) and the AppKit `NSMenu` (sunburst overlay) build
/// from the exact same source; `handler` runs on the main actor.
struct DiskChartContextAction {
    let title: String
    let isDestructive: Bool
    let handler: @MainActor () -> Void
}

/// Owns one native scan and publishes its result. `@MainActor` so view state
/// stays on the main actor; the heavy walk runs off-main inside `DiskScanner`.
@MainActor
@Observable
final class DiskScanModel {
    private(set) var root: DiskNode?
    /// The biggest files anywhere under the scanned root, for the bars mode's
    /// "Largest files" list. Derived once per scan and off the main actor:
    /// walking a finished tree for them costs ~2.3s over a 900k-file home
    /// folder (measured), so it must never run per render.
    private(set) var largeFiles: [DiskNode] = []
    private(set) var isScanning = false
    private(set) var errorMessage: String?
    private(set) var scannedPath: String?

    /// How many rows "Largest files" lists.
    private nonisolated static let largeFileLimit = 20

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Starts a scan only if nothing has been scanned and none is running, so a
    /// view's `.task` can call it idempotently on every appearance.
    func scanIfNeeded(path: String) {
        guard root == nil, task == nil else { return }
        scan(path: path)
    }

    /// (Re)scans `path`, superseding any in-flight scan.
    func scan(path: String) {
        task?.cancel()
        isScanning = true
        errorMessage = nil
        scannedPath = path
        task = Task { [weak self] in
            let outcome: Result<DiskNode, Error>
            do {
                outcome = .success(try await DiskScanner.scan(path: path))
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .success(let tree):
                let files = await Task.detached {
                    Self.largestFiles(in: tree, limit: Self.largeFileLimit)
                }.value
                guard !Task.isCancelled else { return }
                self.task = nil
                self.root = tree
                self.largeFiles = files
                self.isScanning = false
            case .failure(let error):
                if error is CancellationError { return }
                self.task = nil
                self.errorMessage = "Couldn't scan this location."
                self.isScanning = false
            }
        }
    }

    /// Largest files under `root`, biggest first. Skips the scanner's synthetic
    /// "N more items" node — that is a group total, not a file, and nothing can
    /// act on it.
    private nonisolated static func largestFiles(in root: DiskNode, limit: Int) -> [DiskNode] {
        var files: [DiskNode] = []
        var pending = [root]
        while let node = pending.popLast() {
            if node.isDirectory {
                pending.append(contentsOf: node.children)
            } else if !node.id.contains("\u{1F}") {
                files.append(node)
            }
        }
        return Array(files.sorted { $0.size > $1.size }.prefix(limit))
    }

    func cancel() {
        task?.cancel()
        task = nil
        isScanning = false
    }

    /// Prunes a just-trashed path from the in-memory tree, adjusting ancestor
    /// sizes, without a rescan. A no-op if the tree is empty or the path isn't
    /// present. This is the recovery path after a delete: it keeps the chart in
    /// place instead of kicking off a full home-folder rescan.
    func remove(pathID: String) {
        guard let current = root, let pruned = current.removingDescendant(id: pathID) else { return }
        root = pruned
        // A trashed directory takes the files under it out of the list too.
        largeFiles.removeAll { $0.id == pathID || $0.id.hasPrefix(pathID + "/") }
    }
}

/// Maps a segment's position in the tree to a fill color.
///
/// Not ported from Radix: the brief says keep our design system. Hues stay in
/// the `Theme.accent` green family, one hue per top-level branch so everything
/// under a folder reads as a group; brightness lifts and saturation eases with
/// depth so nested rings/tiles separate; anything that dominates its chart
/// (≥ half of the whole) escalates into the `Theme.warn` amber. The HSB anchors
/// below are `Theme.accent` and `Theme.warn` expressed in HSB.
enum DiskChartPalette {
    // Theme.accent  → RGB(0.48, 0.68, 0.32) ≈ HSB(0.26, 0.53, 0.68)
    private static let accentHue = 0.26
    private static let accentSaturation = 0.53
    private static let accentBrightness = 0.68
    // Theme.warn    → RGB(0.86, 0.62, 0.22) ≈ HSB(0.10, 0.74, 0.86)
    private static let warnHue = 0.10
    private static let warnSaturation = 0.74
    private static let warnBrightness = 0.86

    /// Fraction of the whole chart above which a segment escalates to warn.
    private static let warnFraction = 0.5

    static func color(
        depth: Int,
        branchIndex: Int,
        branchCount: Int,
        fraction: Double,
        isAggregate: Bool
    ) -> Color {
        if isAggregate {
            // Folded "smaller items": a muted, near-neutral green that recedes.
            return Color(hue: accentHue, saturation: 0.08, brightness: 0.52)
        }

        let deepen = Double(depth)

        if fraction >= warnFraction {
            return Color(
                hue: warnHue,
                saturation: max(0.42, warnSaturation - deepen * 0.05),
                brightness: min(0.92, warnBrightness + deepen * 0.04)
            )
        }

        // Spread branches across a ±0.06 hue band centered on the accent so
        // sibling top-level folders are distinguishable but stay green.
        let spread = branchCount > 1
            ? (Double(branchIndex % branchCount) / Double(branchCount)) - 0.5
            : 0.0
        let hue = wrapHue(accentHue + spread * 0.12)
        let saturation = max(0.28, accentSaturation - deepen * 0.06)
        let brightness = min(0.92, accentBrightness + deepen * 0.06)
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    private static func wrapHue(_ hue: Double) -> Double {
        var wrapped = hue.truncatingRemainder(dividingBy: 1.0)
        if wrapped < 0 { wrapped += 1.0 }
        return wrapped
    }
}
