import AppKit
import Foundation

/// The runners the menu-bar animation can use. Frames are the real RunCat
/// artwork, not hand-drawn: numbered PNG frame sets vendored from
/// RunCat365 (Apache-2.0) — https://github.com/runcat-dev/RunCat365 — shipped in
/// the SPM resource bundle under `Resources/Runners/<style>/`. The Apache-2.0
/// license text travels with them at `Resources/Runners/RunCat365-LICENSE.txt`.
///
/// Each style is a folder of `<style>_N.png` frames loaded in numeric order as
/// template images: `isTemplate` lets them tint themselves for the light/dark
/// menu bar, and each frame is scaled to menu-bar height on load. Styles may
/// carry different frame counts (RunCat's cat and horse cycle in 5, the parrot
/// in 10); the model animates whatever it is handed.
enum RunnerStyle: String, CaseIterable, Identifiable {
    /// A galloping cat — the original RunCat runner (5 frames).
    case cat
    /// A flapping parrot — the "party parrot" runner (10 frames).
    case parrot
    /// A galloping horse (5 frames).
    case horse

    var id: String { rawValue }

    /// Human-readable label for the settings picker.
    var name: String {
        switch self {
        case .cat: return "Cat"
        case .parrot: return "Parrot"
        case .horse: return "Horse"
        }
    }

    /// Target menu-bar image size in points. Frames (32×32 px squares at source)
    /// are scaled to this on load; also the size of the model's empty placeholder
    /// so a fallback image lines up with the real frames.
    static let size = NSSize(width: 18, height: 18)

    /// One full cycle as template images, loaded from the bundle in numeric frame
    /// order (`cat_0.png`, `cat_1.png`, …) until a frame is missing. Built on
    /// demand; the model holds the array for the selected style only.
    ///
    /// If this style's assets are absent at runtime the result is a single blank
    /// template frame rather than an empty array, so the model parks on a still
    /// (invisible) image and simply won't animate — it never indexes an empty
    /// array and never crashes.
    func frames() -> [NSImage] {
        var images: [NSImage] = []
        var index = 0
        while let url = Bundle.module.url(
            forResource: "\(rawValue)_\(index)",
            withExtension: "png",
            subdirectory: "Runners/\(rawValue)"
        ) {
            guard let image = NSImage(contentsOf: url) else { break }
            image.size = Self.size
            image.isTemplate = true
            images.append(image)
            index += 1
        }
        return images.isEmpty ? [Self.blankFrame()] : images
    }

    /// A single transparent template frame used only as the missing-assets
    /// fallback, sized like a real frame so the menu-bar item doesn't jump.
    private static func blankFrame() -> NSImage {
        let image = NSImage(size: size)
        image.isTemplate = true
        return image
    }
}
