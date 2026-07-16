import XCTest

@testable import PearCompanion

/// Pure math behind the radial ring: cursor angle+distance → snap zone
/// (adapted from Loop's sector selection), the arrow-key refinement, the
/// full-circle sweep delta, and the new ring-only half zones. Angles are
/// y-up degrees: 0° = East, 90° = North.
final class RadialSectorTests: XCTestCase {
    private let deadzone: CGFloat = 40

    private func zone(_ angle: Double, magnitude: CGFloat = 100) -> WindowZone {
        WindowZone.radialZone(angleDegrees: angle, magnitude: magnitude, deadzone: deadzone)
    }

    // MARK: All eight directions

    func testEightCompassDirections() {
        XCTAssertEqual(zone(0), .rightHalf)
        XCTAssertEqual(zone(45), .topRightQuarter)
        XCTAssertEqual(zone(90), .topHalf)
        XCTAssertEqual(zone(135), .topLeftQuarter)
        XCTAssertEqual(zone(180), .leftHalf)
        XCTAssertEqual(zone(225), .bottomLeftQuarter)
        XCTAssertEqual(zone(270), .bottomHalf)
        XCTAssertEqual(zone(315), .bottomRightQuarter)
    }

    // MARK: Deadzone

    func testDeadzoneResolvesToCenterRegardlessOfAngle() {
        XCTAssertEqual(zone(0, magnitude: 0), .center)
        XCTAssertEqual(zone(90, magnitude: 39.9), .center)
        XCTAssertEqual(zone(215, magnitude: 40), .center) // boundary is inclusive
        XCTAssertEqual(zone(215, magnitude: 40.1), .bottomLeftQuarter)
    }

    // MARK: Wraparound at 0°/360°

    func testWraparoundAtZeroDegrees() {
        XCTAssertEqual(zone(359), .rightHalf)
        XCTAssertEqual(zone(360), .rightHalf)
        XCTAssertEqual(zone(361), .rightHalf)
        XCTAssertEqual(zone(-10), .rightHalf)
        XCTAssertEqual(zone(-45), .bottomRightQuarter)
        XCTAssertEqual(zone(710), .rightHalf) // 710 → 350
        XCTAssertEqual(zone(675), .bottomRightQuarter) // 675 → 315
        XCTAssertEqual(zone(-270), .topHalf) // −270 → 90
    }

    func testSectorBoundariesSplitAtHalfSpan() {
        XCTAssertEqual(zone(22.4), .rightHalf)
        XCTAssertEqual(zone(22.6), .topRightQuarter)
        XCTAssertEqual(zone(337.4), .bottomRightQuarter)
        XCTAssertEqual(zone(337.6), .rightHalf)
    }

    // MARK: Offset convenience (dx/dy, y-up)

    func testOffsetConvenienceMatchesAngles() {
        XCTAssertEqual(WindowZone.radialZone(dx: 100, dy: 0, deadzone: deadzone), .rightHalf)
        XCTAssertEqual(WindowZone.radialZone(dx: -70, dy: 70, deadzone: deadzone), .topLeftQuarter)
        XCTAssertEqual(WindowZone.radialZone(dx: 0, dy: -100, deadzone: deadzone), .bottomHalf)
        XCTAssertEqual(WindowZone.radialZone(dx: 10, dy: 10, deadzone: deadzone), .center)
    }

    // MARK: Sector index (drives the ring highlight)

    func testSectorIndexRoundTripsThroughRadialZone() {
        for index in 0 ..< WindowZone.radialSectorCount {
            let resolved = WindowZone.radialZone(
                angleDegrees: Double(index) * 45,
                magnitude: 100,
                deadzone: deadzone
            )
            XCTAssertEqual(resolved.radialSectorIndex, index, "sector \(index)")
        }
        XCTAssertNil(WindowZone.center.radialSectorIndex)
        XCTAssertNil(WindowZone.maximize.radialSectorIndex)
        XCTAssertNil(WindowZone.leftThird.radialSectorIndex)
    }

    // MARK: Arrow-key refinement

    func testArrowSelectionCombinesHalvesIntoQuarters() {
        XCTAssertEqual(WindowZone.arrowSelection(current: nil, arrow: .left), .leftHalf)
        XCTAssertEqual(WindowZone.arrowSelection(current: .topHalf, arrow: .left), .topLeftQuarter)
        XCTAssertEqual(WindowZone.arrowSelection(current: .bottomHalf, arrow: .right), .bottomRightQuarter)
        XCTAssertEqual(WindowZone.arrowSelection(current: .leftHalf, arrow: .down), .bottomLeftQuarter)
        XCTAssertEqual(WindowZone.arrowSelection(current: .rightHalf, arrow: .up), .topRightQuarter)
        // Non-orthogonal current selections fall back to the arrow's half.
        XCTAssertEqual(WindowZone.arrowSelection(current: .center, arrow: .up), .topHalf)
        XCTAssertEqual(WindowZone.arrowSelection(current: .leftHalf, arrow: .left), .leftHalf)
    }

    // MARK: Sweep delta (full-circle → maximize)

    func testWrappedAngleDeltaCrossesTheSeam() {
        XCTAssertEqual(WindowZone.wrappedAngleDelta(from: 350, to: 10), 20, accuracy: 0.001)
        XCTAssertEqual(WindowZone.wrappedAngleDelta(from: 10, to: 350), -20, accuracy: 0.001)
        XCTAssertEqual(WindowZone.wrappedAngleDelta(from: 0, to: 180), 180, accuracy: 0.001)
        XCTAssertEqual(WindowZone.wrappedAngleDelta(from: 90, to: 90), 0, accuracy: 0.001)
    }

    // MARK: Ring-only half zones (frame math, matching WindowZoneTests style)

    func testTopAndBottomHalfFrames() {
        let area = NSRect(x: 100, y: 50, width: 1440, height: 900)
        let top = WindowZone.topHalf.frame(in: area)
        XCTAssertEqual(top, NSRect(x: 100, y: 500, width: 1440, height: 450))
        let bottom = WindowZone.bottomHalf.frame(in: area)
        XCTAssertEqual(bottom, NSRect(x: 100, y: 50, width: 1440, height: 450))
    }

    // MARK: Trigger key persistence (injectable store)

    func testTriggerKeyDefaultsRoundTrip() {
        let suite = "radial-trigger-tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        XCTAssertEqual(RadialTriggerKey.current(from: defaults), .fnGlobe) // Loop's default
        defaults.set(RadialTriggerKey.rightCommand.rawValue, forKey: RadialTriggerKey.defaultsKey)
        XCTAssertEqual(RadialTriggerKey.current(from: defaults), .rightCommand)
        defaults.set("garbage", forKey: RadialTriggerKey.defaultsKey)
        XCTAssertEqual(RadialTriggerKey.current(from: defaults), .fnGlobe)

        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Trigger key flag detection

    func testTriggerKeyIsHeld() {
        let rightCommandBit: UInt = 0x0010 // NX_DEVICERCMDKEYMASK
        let rightOptionBit: UInt = 0x0040 // NX_DEVICERALTKEYMASK

        let rightCmd = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.command.rawValue | rightCommandBit)
        XCTAssertTrue(RadialTriggerKey.rightCommand.isHeld(rightCmd))
        // Left ⌘ (no right-side bit) must NOT count as right ⌘.
        XCTAssertFalse(RadialTriggerKey.rightCommand.isHeld(.command))

        let rightOpt = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.option.rawValue | rightOptionBit)
        XCTAssertTrue(RadialTriggerKey.rightOption.isHeld(rightOpt))
        XCTAssertFalse(RadialTriggerKey.rightOption.isHeld(.option))

        XCTAssertTrue(RadialTriggerKey.fnGlobe.isHeld(.function))
        XCTAssertFalse(RadialTriggerKey.fnGlobe.isHeld([.command, .option]))

        XCTAssertTrue(RadialTriggerKey.controlOption.isHeld([.control, .option]))
        XCTAssertFalse(RadialTriggerKey.controlOption.isHeld(.control))
        XCTAssertFalse(RadialTriggerKey.controlOption.isHeld(.option))
    }
}
