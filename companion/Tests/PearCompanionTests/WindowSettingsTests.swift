import XCTest

@testable import PearCompanion

/// Logic-level cover for the Windows-tool settings seam: the vendored snap
/// easing curve, the speed-picker → duration mapping, and the `windows.*`
/// UserDefaults round-trip (defaults, persistence, clamping). No AX, no views.
final class WindowSettingsTests: XCTestCase {
    // MARK: Snap easing (Loop's cubic ease-out)

    func testEaseOutCubicEndpoints() {
        XCTAssertEqual(WindowTransformAnimation.easeOutCubic(0), 0, accuracy: 1e-9)
        XCTAssertEqual(WindowTransformAnimation.easeOutCubic(1), 1, accuracy: 1e-9)
    }

    func testEaseOutCubicIsMonotonicAndFrontLoaded() {
        var previous = WindowTransformAnimation.easeOutCubic(0)
        for step in 1 ... 100 {
            let t = Double(step) / 100.0
            let value = WindowTransformAnimation.easeOutCubic(t)
            // Strictly increasing across the interval.
            XCTAssertGreaterThan(value, previous, "not monotonic at t=\(t)")
            // Ease-out sits above the linear line for t in (0, 1).
            if t < 1 {
                XCTAssertGreaterThan(value, t - 1e-9, "not front-loaded at t=\(t)")
            }
            previous = value
        }
    }

    func testEaseOutCubicMidpoint() {
        // 1 - (1 - 0.5)^3 = 1 - 0.125 = 0.875
        XCTAssertEqual(WindowTransformAnimation.easeOutCubic(0.5), 0.875, accuracy: 1e-9)
    }

    // MARK: Speed picker → duration

    func testSpeedSnapDurationMapping() {
        XCTAssertEqual(WindowAnimationSpeed.fluid.snapDuration, 0.35)
        XCTAssertEqual(WindowAnimationSpeed.relaxed.snapDuration, 0.28)
        XCTAssertEqual(WindowAnimationSpeed.snappy.snapDuration, 0.22)
        XCTAssertEqual(WindowAnimationSpeed.brisk.snapDuration, 0.15)
        XCTAssertNil(WindowAnimationSpeed.instant.snapDuration, "Instant means no animation")
    }

    func testSpeedDurationsDecreaseFluidToBrisk() {
        let ordered: [WindowAnimationSpeed] = [.fluid, .relaxed, .snappy, .brisk]
        let durations = ordered.compactMap(\.snapDuration)
        XCTAssertEqual(durations.count, ordered.count)
        XCTAssertEqual(durations, durations.sorted(by: >), "faster presets must be shorter")
    }

    func testInstantNeverAnimatesRingOrPreview() {
        XCTAssertFalse(WindowAnimationSpeed.instant.animateRadialMenuAppearance)
        XCTAssertNil(WindowAnimationSpeed.instant.previewWindow)
    }

    // MARK: Effective snap duration (toggle + speed)

    func testSnapDurationHonorsToggleAndSpeed() {
        let suite = "windows-settings-snap"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // Default: enabled + snappy → 0.22.
        XCTAssertEqual(WindowSettings.snapDuration(defaults), 0.22)

        // Toggle off → nil regardless of speed.
        defaults.set(false, forKey: WindowSettings.Key.animationEnabled)
        XCTAssertNil(WindowSettings.snapDuration(defaults))

        // On again, Instant speed → nil.
        defaults.set(true, forKey: WindowSettings.Key.animationEnabled)
        defaults.set(WindowAnimationSpeed.instant.rawValue, forKey: WindowSettings.Key.animationSpeed)
        XCTAssertNil(WindowSettings.snapDuration(defaults))

        // On + fluid → 0.35.
        defaults.set(WindowAnimationSpeed.fluid.rawValue, forKey: WindowSettings.Key.animationSpeed)
        XCTAssertEqual(WindowSettings.snapDuration(defaults), 0.35)
    }

    // MARK: Defaults when nothing is stored

    func testDefaultsWhenUnset() {
        let suite = "windows-settings-defaults"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(WindowSettings.ringCornerRadius(defaults), 50)
        XCTAssertEqual(WindowSettings.ringThickness(defaults), 22)
        XCTAssertEqual(WindowSettings.previewPadding(defaults), 10)
        XCTAssertTrue(WindowSettings.previewBlur(defaults))
        XCTAssertTrue(WindowSettings.animationEnabled(defaults)) // owner wants ON
        XCTAssertEqual(WindowSettings.animationSpeed(defaults), .snappy)
        XCTAssertEqual(WindowSettings.triggerDelay(defaults), 0.1)
    }

    // MARK: Persistence round-trip

    func testRoundTrip() {
        let suite = "windows-settings-roundtrip"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(42.0, forKey: WindowSettings.Key.ringCornerRadius)
        defaults.set(30.0, forKey: WindowSettings.Key.ringThickness)
        defaults.set(5.0, forKey: WindowSettings.Key.previewPadding)
        defaults.set(false, forKey: WindowSettings.Key.previewBlur)
        defaults.set(0.5, forKey: WindowSettings.Key.triggerDelay)
        defaults.set(WindowAnimationSpeed.brisk.rawValue, forKey: WindowSettings.Key.animationSpeed)

        XCTAssertEqual(WindowSettings.ringCornerRadius(defaults), 42)
        XCTAssertEqual(WindowSettings.ringThickness(defaults), 30)
        XCTAssertEqual(WindowSettings.previewPadding(defaults), 5)
        XCTAssertFalse(WindowSettings.previewBlur(defaults))
        XCTAssertEqual(WindowSettings.triggerDelay(defaults), 0.5)
        XCTAssertEqual(WindowSettings.animationSpeed(defaults), .brisk)
    }

    // MARK: Clamping (a stray write can't break the ring)

    func testAccessorsClampOutOfRange() {
        let suite = "windows-settings-clamp"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(999.0, forKey: WindowSettings.Key.ringCornerRadius)
        defaults.set(-5.0, forKey: WindowSettings.Key.ringThickness)
        defaults.set(999.0, forKey: WindowSettings.Key.previewPadding)
        defaults.set(-1.0, forKey: WindowSettings.Key.triggerDelay)

        XCTAssertEqual(WindowSettings.ringCornerRadius(defaults), 50) // upper bound
        XCTAssertEqual(WindowSettings.ringThickness(defaults), 10) // lower bound
        XCTAssertEqual(WindowSettings.previewPadding(defaults), 20) // upper bound
        XCTAssertEqual(WindowSettings.triggerDelay(defaults), 0) // lower bound
    }

    func testGarbageSpeedFallsBackToDefault() {
        let suite = "windows-settings-garbage"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("nonsense", forKey: WindowSettings.Key.animationSpeed)
        XCTAssertEqual(WindowSettings.animationSpeed(defaults), .snappy)
    }
}
