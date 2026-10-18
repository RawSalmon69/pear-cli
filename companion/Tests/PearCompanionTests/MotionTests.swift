import SwiftUI
import XCTest

@testable import PearCompanion

/// `Theme.motion`: the spring as given, or a plain ease under Reduce Motion.
final class MotionTests: XCTestCase {
    private let spring = Animation.spring(response: 0.3, dampingFraction: 0.7)

    func testSpringStaysWithoutReduceMotion() {
        XCTAssertEqual(Theme.motion(spring, reduce: false), spring)
    }

    func testReduceMotionSwapsTheSpringForAnEase() {
        XCTAssertEqual(Theme.motion(spring, reduce: true), .easeInOut(duration: 0.2))
        XCTAssertNotEqual(Theme.motion(spring, reduce: true), spring)
    }
}
