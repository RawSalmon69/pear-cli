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

    /// Fixed menu-bar height in points for a runner's *artwork*. After the
    /// transparent padding is cropped away, the remaining art scales to this
    /// height and keeps its aspect ratio, so every runner reads at the same
    /// visual weight — the legacy RunCat frames (cat/parrot/horse) are 32×32
    /// squares with the animal drawn small inside a lot of empty margin, while
    /// the gallery frames are cropped tight to 36 px-tall art. Scaling the raw
    /// canvas made the legacy animals render roughly half the size.
    static let menuBarHeight: CGFloat = 18

    /// Square placeholder size for the missing-assets fallback frame and the
    /// model's empty-state image, so a fallback lines up with real frames.
    static let placeholderSize = NSSize(width: menuBarHeight, height: menuBarHeight)

    /// One full cycle as template images, loaded from the bundle in numeric frame
    /// order (`<id>_0.png`, `<id>_1.png`, …) until a frame is missing. Built on
    /// demand; the model holds the array for the selected style only.
    ///
    /// Frames are cropped to the artwork before scaling — see `scaledSize`. The
    /// crop box is the union of every frame's opaque bounds, computed once per
    /// cycle, so the sprite keeps a constant size and position while only the
    /// legs move (a per-frame crop would make the whole animal pulse).
    ///
    /// If this style's assets are absent at runtime the result is a single blank
    /// template frame rather than an empty array, so the model parks on a still
    /// (invisible) image and simply won't animate — it never indexes an empty
    /// array and never crashes.
    func frames() -> [NSImage] {
        var reps: [NSBitmapImageRep] = []
        var index = 0
        while let url = Bundle.pearResources.url(
            forResource: "\(id)_\(index)",
            withExtension: "png",
            subdirectory: "Runners/\(id)"
        ) {
            guard let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { break }
            reps.append(rep)
            index += 1
        }
        guard !reps.isEmpty else { return [Self.blankFrame()] }
        let box = reps.reduce(CGRect.null) { $0.union(Self.opaqueBounds($1)) }
        return reps.map { Self.templateFrame(from: $0, cropping: box) }
    }

    /// Just the first frame as a template image, for the settings picker. Loads a
    /// single PNG instead of the whole cycle so rendering the grid of every runner
    /// stays cheap. Falls back to the blank frame if the asset is missing.
    func previewFrame() -> NSImage {
        guard let url = Bundle.pearResources.url(
            forResource: "\(id)_0",
            withExtension: "png",
            subdirectory: "Runners/\(id)"
        ), let data = try? Data(contentsOf: url),
            let rep = NSBitmapImageRep(data: data) else {
            return Self.blankFrame()
        }
        return Self.templateFrame(from: rep, cropping: Self.opaqueBounds(rep))
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

    /// Point size for a cropped frame: the fixed menu-bar height, with width
    /// scaled from the cropped pixel aspect ratio so nothing is squashed. Pure
    /// so the scaling is unit-testable without loading real artwork.
    static func scaledSize(cropWidth: CGFloat, cropHeight: CGFloat) -> NSSize {
        guard cropHeight > 0 else { return placeholderSize }
        let width = (menuBarHeight * cropWidth / cropHeight).rounded()
        return NSSize(width: max(width, 1), height: menuBarHeight)
    }

    /// Opaque bounding box of a frame in top-left pixel coordinates — the tight
    /// rectangle around every pixel that isn't (near-)transparent. Falls back to
    /// the full canvas for any non-32-bit-RGBA rep it can't scan, so an unusual
    /// asset degrades to the old canvas scaling rather than vanishing.
    private static func opaqueBounds(_ rep: NSBitmapImageRep) -> CGRect {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        guard rep.bitsPerPixel == 32, rep.samplesPerPixel == 4, !rep.isPlanar,
              let data = rep.bitmapData else { return full }
        let bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
        let alphaByte = rep.bitmapFormat.contains(.alphaFirst) ? 0 : 3
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where data[y * bpr + x * spp + alphaByte] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return full }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Crops `rep` to `box` and returns it as a menu-bar-sized template image.
    /// Uses the cropped pixel dimensions for the size, so it is robust even when
    /// the crop is a no-op (a full-canvas fallback box).
    private static func templateFrame(from rep: NSBitmapImageRep, cropping box: CGRect) -> NSImage {
        guard let cg = rep.cgImage?.cropping(to: box) ?? rep.cgImage else { return blankFrame() }
        let image = NSImage(
            cgImage: cg,
            size: scaledSize(cropWidth: CGFloat(cg.width), cropHeight: CGFloat(cg.height))
        )
        image.isTemplate = true
        return image
    }

    /// A single transparent template frame used only as the missing-assets
    /// fallback, sized like a real frame so the menu-bar item doesn't jump.
    private static func blankFrame() -> NSImage {
        let image = NSImage(size: placeholderSize)
        image.isTemplate = true
        return image
    }
}
