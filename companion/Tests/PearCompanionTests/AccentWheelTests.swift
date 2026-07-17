import XCTest

@testable import PearCompanion

/// The custom-accent hue wheel's pure math: angle → hue (clockwise from
/// 3 o'clock, matching SwiftUI's y-down AngularGradient), radius → saturation.
final class AccentWheelTests: XCTestCase {
    private let size = CGSize(width: 140, height: 140)

    func testCenterIsDesaturated() throws {
        let pick = try XCTUnwrap(AccentWheelMath.pick(at: CGPoint(x: 70, y: 70), in: size))
        XCTAssertEqual(pick.saturation, 0, accuracy: 0.001)
    }

    func testCardinalEdgesMapToQuarterHues() throws {
        // 3 o'clock = hue 0, then clockwise quarters (y-down view space).
        let right = try XCTUnwrap(AccentWheelMath.pick(at: CGPoint(x: 140, y: 70), in: size))
        XCTAssertEqual(right.hue, 0, accuracy: 0.001)
        XCTAssertEqual(right.saturation, 1, accuracy: 0.001)

        let bottom = try XCTUnwrap(AccentWheelMath.pick(at: CGPoint(x: 70, y: 140), in: size))
        XCTAssertEqual(bottom.hue, 0.25, accuracy: 0.001)

        let left = try XCTUnwrap(AccentWheelMath.pick(at: CGPoint(x: 0, y: 70), in: size))
        XCTAssertEqual(left.hue, 0.5, accuracy: 0.001)

        let top = try XCTUnwrap(AccentWheelMath.pick(at: CGPoint(x: 70, y: 0), in: size))
        XCTAssertEqual(top.hue, 0.75, accuracy: 0.001)
    }

    func testMidRadiusIsHalfSaturation() throws {
        let pick = try XCTUnwrap(AccentWheelMath.pick(at: CGPoint(x: 105, y: 70), in: size))
        XCTAssertEqual(pick.saturation, 0.5, accuracy: 0.001)
    }

    func testOutsideTheDiscIsNil() {
        // The disc's corner regions are outside the circle.
        XCTAssertNil(AccentWheelMath.pick(at: CGPoint(x: 0, y: 0), in: size))
        XCTAssertNil(AccentWheelMath.pick(at: CGPoint(x: 139, y: 139), in: size))
    }

    func testDegenerateSizeIsNil() {
        XCTAssertNil(AccentWheelMath.pick(at: .zero, in: .zero))
    }
}
