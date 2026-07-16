import AppKit
import Foundation

/// One menu-bar runner: a folder of numbered PNG frames shipped in the SPM
/// resource bundle under `Resources/Runners/<id>/`. Frames are the real RunCat
/// artwork, not hand-drawn: the cat, parrot, and horse come from RunCat365
/// (Apache-2.0) — https://github.com/runcat-dev/RunCat365 — and the rest from the
/// Runner Gallery (Apache-2.0) — https://github.com/runcat-dev/RunnerGallery. The
/// license texts travel with the frames at `Resources/Runners/RunCat365-LICENSE.txt`
/// and `Resources/Runners/RunnerGallery-LICENSE.txt`.
///
/// The style list is discovered from the bundle at runtime rather than hardcoded,
/// so adding a runner is just dropping in a folder: `id` is the folder name (also
/// the persisted selection), `name` is that name kebab→Title Case, and `frames()`
/// loads `<id>_0.png`, `<id>_1.png`, … in numeric order as template images.
/// Styles carry different frame counts (5 for the classic cat, 24 for escapement);
/// the model animates whatever it is handed.
struct RunnerStyle: Identifiable, Hashable, Sendable {
    /// Folder name under `Resources/Runners`, e.g. `"cat"`, `"border-collie"`.
    /// Doubles as the value persisted in `UserDefaults` and the `Identifiable` id.
    let id: String

    /// Human-readable label for the picker: the folder name with hyphens turned
    /// into spaces and each word capitalized (`border-collie` → `Border Collie`).
    var name: String { Self.titleCase(id) }

    /// The runner selected when none is stored (or the stored one is missing).
    static let defaultStyle = RunnerStyle(id: "cat")

    /// Every runner shipped in the bundle, discovered once and sorted by id for a
    /// stable picker order. Falls back to the default cat if the bundle can't be
    /// read, so the list is never empty.
    static let all: [RunnerStyle] = discover()

    /// The discovered style with this id, or nil if no such runner shipped. Used
    /// to resolve a persisted selection back to a live style without trusting that
    /// the folder still exists.
    static func style(id: String) -> RunnerStyle? {
        all.first { $0.id == id }
    }

    /// Fixed menu-bar image height in points. Frames scale to this height and keep
    /// their native aspect ratio — gallery frames are 36 px tall but vary in width
    /// (roughly 10–100 px), so a fixed square would distort them.
    static let menuBarHeight: CGFloat = 18

    /// Square placeholder size for the missing-assets fallback frame and the
    /// model's empty-state image, so a fallback lines up with real frames.
    static let placeholderSize = NSSize(width: menuBarHeight, height: menuBarHeight)

    /// One full cycle as template images, loaded from the bundle in numeric frame
    /// order (`<id>_0.png`, `<id>_1.png`, …) until a frame is missing. Built on
    /// demand; the model holds the array for the selected style only.
    ///
    /// If this style's assets are absent at runtime the result is a single blank
    /// template frame rather than an empty array, so the model parks on a still
    /// (invisible) image and simply won't animate — it never indexes an empty
    /// array and never crashes.
    func frames() -> [NSImage] {
        var images: [NSImage] = []
        var index = 0
        while let url = Bundle.pearResources.url(
            forResource: "\(id)_\(index)",
            withExtension: "png",
            subdirectory: "Runners/\(id)"
        ) {
            guard let image = NSImage(contentsOf: url) else { break }
            image.size = Self.scaledSize(for: image)
            image.isTemplate = true
            images.append(image)
            index += 1
        }
        return images.isEmpty ? [Self.blankFrame()] : images
    }

    /// Just the first frame as a template image, for the settings picker. Loads a
    /// single PNG instead of the whole cycle so rendering the grid of every runner
    /// stays cheap. Falls back to the blank frame if the asset is missing.
    func previewFrame() -> NSImage {
        guard let url = Bundle.pearResources.url(
            forResource: "\(id)_0",
            withExtension: "png",
            subdirectory: "Runners/\(id)"
        ), let image = NSImage(contentsOf: url) else {
            return Self.blankFrame()
        }
        image.size = Self.scaledSize(for: image)
        image.isTemplate = true
        return image
    }

    /// Discovers the runner folders shipped in the resource bundle, sorted by id.
    /// The two `*-LICENSE.txt` siblings are skipped by taking directories only.
    private static func discover() -> [RunnerStyle] {
        guard let root = Bundle.pearResources.url(forResource: "Runners", withExtension: nil) else {
            return [defaultStyle]
        }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let styles = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { RunnerStyle(id: $0.lastPathComponent) }
            .sorted { $0.id < $1.id }
        return styles.isEmpty ? [defaultStyle] : styles
    }

    /// Folder name → display label: split on hyphens, capitalize each word.
    private static func titleCase(_ id: String) -> String {
        id.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Menu-bar size for a loaded frame: the fixed menu-bar height, with width
    /// scaled from the frame's native pixel aspect ratio so nothing is squashed.
    private static func scaledSize(for image: NSImage) -> NSSize {
        let pixels = image.representations.first.map {
            NSSize(width: $0.pixelsWide, height: $0.pixelsHigh)
        } ?? image.size
        guard pixels.height > 0 else { return placeholderSize }
        let width = (menuBarHeight * pixels.width / pixels.height).rounded()
        return NSSize(width: width, height: menuBarHeight)
    }

    /// A single transparent template frame used only as the missing-assets
    /// fallback, sized like a real frame so the menu-bar item doesn't jump.
    private static func blankFrame() -> NSImage {
        let image = NSImage(size: placeholderSize)
        image.isTemplate = true
        return image
    }
}
