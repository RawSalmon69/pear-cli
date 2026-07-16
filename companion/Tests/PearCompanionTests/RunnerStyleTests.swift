import XCTest
@testable import PearCompanion

/// Coverage for the runner customization: every style renders the shared frame
/// count, and the persisted style / CPU-readout preferences round-trip through
/// an injectable `UserDefaults` domain.
@MainActor
final class RunnerStyleTests: XCTestCase {

    /// Each style must render exactly `count` frames so the menu-bar item never
    /// jumps when the user switches runners.
    func testFramesCountPerStyle() {
        for style in RunnerStyle.allCases {
            XCTAssertEqual(style.frames().count, RunnerStyle.count, "\(style.rawValue)")
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
