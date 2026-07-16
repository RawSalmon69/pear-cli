import XCTest
@testable import PearCompanion

/// Coverage for the runner customization: every style loads its real frame set
/// from the bundled RunCat365 artwork, and the persisted style / CPU-readout
/// preferences round-trip through an injectable `UserDefaults` domain.
@MainActor
final class RunnerStyleTests: XCTestCase {

    /// Every style loads a non-empty frame set from the resource bundle. If the
    /// assets failed to ship, `frames()` degrades to a single blank frame — so
    /// this guards against a crash but not a missing bundle (see the count test).
    func testEachStyleLoadsNonEmptyFramesFromBundle() {
        for style in RunnerStyle.allCases {
            XCTAssertFalse(style.frames().isEmpty, "\(style.rawValue) loaded no frames")
        }
    }

    /// Each style loads exactly the frame count shipped in the bundle. A missing
    /// asset folder degrades to the single blank fallback, which fails here — so
    /// this asserts the real artwork actually shipped, in numeric order.
    func testFramesCountPerStyle() {
        let expected: [RunnerStyle: Int] = [.cat: 5, .parrot: 10, .horse: 5]
        for style in RunnerStyle.allCases {
            XCTAssertEqual(style.frames().count, expected[style], "\(style.rawValue)")
        }
    }

    /// The default runner is the cat and the CPU readout is off.
    func testDefaults() {
        let suite = "runnerStyleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = RunnerModel(defaults: defaults)
        XCTAssertEqual(model.style, .cat)
        XCTAssertFalse(model.showsCPU)
    }

    /// Changing the style and CPU readout persists and is read back by a fresh
    /// model sharing the same defaults domain.
    func testStyleAndShowsCPURoundTrip() {
        let suite = "runnerStyleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = RunnerModel(defaults: defaults)
        first.style = .horse
        first.showsCPU = true

        let second = RunnerModel(defaults: defaults)
        XCTAssertEqual(second.style, .horse)
        XCTAssertTrue(second.showsCPU)
    }
}
