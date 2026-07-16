import XCTest
@testable import PearCompanion

/// Coverage for the runner customization: the style list is discovered from the
/// bundled RunCat365 + Runner Gallery artwork at runtime, folder names map to
/// display labels, every discovered style loads a real frame set, and the
/// persisted style / CPU-readout preferences round-trip through an injectable
/// `UserDefaults` domain.
@MainActor
final class RunnerStyleTests: XCTestCase {

    /// The frame count each shipped runner is expected to load, keyed by folder
    /// id. Doubles as the discovery expectation: exactly these runners ship, and
    /// each loads exactly this many frames in numeric order (a missing folder
    /// degrades to the single blank fallback, which fails the count assertion).
    private static let expectedFrameCounts: [String: Int] = [
        // Original RunCat365 runners.
        "cat": 5, "parrot": 10, "horse": 5,
        // Runner Gallery runners.
        "beagle": 9, "border-collie": 8, "golden-retriever": 8, "greyhound": 8,
        "jack-russell-terrier": 7, "shiba-inu": 8, "welsh-corgi": 7, "chicken": 5,
        "classic-cat": 5, "dinosaur": 7, "fishman": 5, "frog": 5, "otter": 8,
        "rabbit": 5, "squirrel": 5, "turtle": 8, "escapement": 24, "linkage": 15,
        "wankel-engine": 10, "record-player": 5, "uhooi": 10, "spinning-bonfire": 10,
    ]

    /// Discovery finds exactly the runners we vendored, sorted and stable.
    func testDiscoversAllVendoredRunners() {
        let discovered = Set(RunnerStyle.all.map(\.id))
        XCTAssertEqual(discovered, Set(Self.expectedFrameCounts.keys))
        // Sorted by id for a stable picker order.
        XCTAssertEqual(RunnerStyle.all.map(\.id), RunnerStyle.all.map(\.id).sorted())
    }

    /// Every discovered style loads a non-empty frame set from the resource
    /// bundle. If the assets failed to ship, `frames()` degrades to a single
    /// blank frame — non-empty but wrong, which the count test catches.
    func testEveryDiscoveredStyleLoadsNonEmptyFrames() {
        for style in RunnerStyle.all {
            XCTAssertFalse(style.frames().isEmpty, "\(style.id) loaded no frames")
        }
    }

    /// Each discovered style loads exactly the frame count shipped in the bundle,
    /// in numeric order. This asserts the real artwork actually shipped for every
    /// runner, not just the blank fallback.
    func testFrameCountPerDiscoveredStyle() {
        for style in RunnerStyle.all {
            guard let expected = Self.expectedFrameCounts[style.id] else {
                XCTFail("unexpected runner discovered: \(style.id)")
                continue
            }
            XCTAssertEqual(style.frames().count, expected, "\(style.id)")
        }
    }

    /// Folder ids map to display labels: hyphens become spaces, each word is
    /// capitalized. Covers a single word, a two-word kebab id, and a long one.
    func testDisplayNameMapping() {
        XCTAssertEqual(RunnerStyle(id: "cat").name, "Cat")
        XCTAssertEqual(RunnerStyle(id: "border-collie").name, "Border Collie")
        XCTAssertEqual(RunnerStyle(id: "jack-russell-terrier").name, "Jack Russell Terrier")
        XCTAssertEqual(RunnerStyle(id: "wankel-engine").name, "Wankel Engine")
    }

    /// A vendored runner's frames load as sized template images — the generalized
    /// loader preserves the native aspect ratio of the variable-width 36 px art.
    func testVendoredRunnerFramesAreSizedTemplates() {
        guard let escapement = RunnerStyle.style(id: "escapement") else {
            return XCTFail("escapement did not ship")
        }
        let frames = escapement.frames()
        XCTAssertEqual(frames.count, 24)
        for frame in frames {
            XCTAssertTrue(frame.isTemplate, "frames must be template images")
            XCTAssertEqual(frame.size.height, RunnerStyle.menuBarHeight, "fixed menu-bar height")
            XCTAssertGreaterThan(frame.size.width, 0, "aspect-preserving width")
        }
    }

    /// Cropped-frame scaling: menu-bar height is fixed and width follows the
    /// cropped aspect ratio. A square crop stays square; a wide crop stays wide;
    /// a degenerate crop never divides by zero or yields a zero-size frame.
    func testScaledSizeNormalizesHeightAndPreservesAspect() {
        let square = RunnerStyle.scaledSize(cropWidth: 32, cropHeight: 32)
        XCTAssertEqual(square.height, RunnerStyle.menuBarHeight)
        XCTAssertEqual(square.width, RunnerStyle.menuBarHeight)

        let wide = RunnerStyle.scaledSize(cropWidth: 70, cropHeight: 36)
        XCTAssertEqual(wide.height, RunnerStyle.menuBarHeight)
        XCTAssertEqual(wide.width, (RunnerStyle.menuBarHeight * 70 / 36).rounded())
        XCTAssertGreaterThan(wide.width, wide.height)

        XCTAssertEqual(RunnerStyle.scaledSize(cropWidth: 0, cropHeight: 0), RunnerStyle.placeholderSize)
    }

    /// The legacy 32×32 RunCat frames (cat/parrot/horse) load through the crop
    /// path as height-normalized template images — the fix that makes their
    /// artwork read at the same visual weight as the tightly-cropped gallery art
    /// instead of half the size.
    func testLegacyRunnerFramesAreCroppedTemplates() throws {
        for id in ["cat", "parrot", "horse"] {
            let style = try XCTUnwrap(RunnerStyle.style(id: id))
            let frames = style.frames()
            XCTAssertFalse(frames.isEmpty, "\(id) loaded no frames")
            for frame in frames {
                XCTAssertTrue(frame.isTemplate, "\(id) frames must be template images")
                XCTAssertEqual(frame.size.height, RunnerStyle.menuBarHeight, "\(id) height")
                XCTAssertGreaterThan(frame.size.width, 0, "\(id) width")
            }
        }
    }

    /// The default runner is the cat and the CPU readout is off.
    func testDefaults() {
        let suite = "runnerStyleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = RunnerModel(defaults: defaults)
        XCTAssertEqual(model.style.id, "cat")
        XCTAssertEqual(model.style, RunnerStyle.defaultStyle)
        XCTAssertFalse(model.showsCPU)
    }

    /// Changing the style and CPU readout persists and is read back by a fresh
    /// model sharing the same defaults domain.
    func testStyleAndShowsCPURoundTrip() throws {
        let suite = "runnerStyleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let horse = try XCTUnwrap(RunnerStyle.style(id: "horse"))
        let first = RunnerModel(defaults: defaults)
        first.style = horse
        first.showsCPU = true

        let second = RunnerModel(defaults: defaults)
        XCTAssertEqual(second.style.id, "horse")
        XCTAssertTrue(second.showsCPU)
    }

    /// A pre-existing "cat"/"horse"/"parrot" selection (the old enum rawValues)
    /// still resolves to a live style — folder ids match the old rawValues, so no
    /// migration is needed and existing users don't silently reset.
    func testLegacyStringSelectionsStillResolve() {
        for legacy in ["cat", "parrot", "horse"] {
            let suite = "runnerStyleTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(legacy, forKey: "runnerStyle")

            let model = RunnerModel(defaults: defaults)
            XCTAssertEqual(model.style.id, legacy)
        }
    }
}
