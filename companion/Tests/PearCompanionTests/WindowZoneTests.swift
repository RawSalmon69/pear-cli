import XCTest

@testable import PearCompanion

/// Pure frame-math for the snapping zones. All rects are AppKit y-up (an
/// `NSScreen.visibleFrame`), so "top" quarters sit at higher y. Verified on a
/// synthetic 1440×900 visible frame at the origin and, to catch origin bugs,
/// on a non-zero-origin frame (simulating a secondary display / Dock inset).
final class WindowZoneTests: XCTestCase {
    private let origin = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let offset = NSRect(x: 100, y: 50, width: 1440, height: 900)

    private func assertFrame(
        _ zone: WindowZone,
        in area: NSRect,
        _ expected: NSRect,
        _ file: StaticString = #filePath,
        _ line: UInt = #line
    ) {
        let f = zone.frame(in: area)
        XCTAssertEqual(f.minX, expected.minX, accuracy: 0.001, "x", file: file, line: line)
        XCTAssertEqual(f.minY, expected.minY, accuracy: 0.001, "y", file: file, line: line)
        XCTAssertEqual(f.width, expected.width, accuracy: 0.001, "w", file: file, line: line)
        XCTAssertEqual(f.height, expected.height, accuracy: 0.001, "h", file: file, line: line)
    }

    // MARK: Halves

    func testHalves() {
        assertFrame(.leftHalf, in: origin, NSRect(x: 0, y: 0, width: 720, height: 900))
        assertFrame(.rightHalf, in: origin, NSRect(x: 720, y: 0, width: 720, height: 900))
    }

    func testHalvesOffsetScreen() {
        assertFrame(.leftHalf, in: offset, NSRect(x: 100, y: 50, width: 720, height: 900))
        assertFrame(.rightHalf, in: offset, NSRect(x: 820, y: 50, width: 720, height: 900))
    }

    // MARK: Quarters (y-up: top row sits at y = height/2)

    func testQuarters() {
        assertFrame(.topLeftQuarter, in: origin, NSRect(x: 0, y: 450, width: 720, height: 450))
        assertFrame(.topRightQuarter, in: origin, NSRect(x: 720, y: 450, width: 720, height: 450))
        assertFrame(.bottomLeftQuarter, in: origin, NSRect(x: 0, y: 0, width: 720, height: 450))
        assertFrame(.bottomRightQuarter, in: origin, NSRect(x: 720, y: 0, width: 720, height: 450))
    }

    func testQuartersOffsetScreen() {
        assertFrame(.topLeftQuarter, in: offset, NSRect(x: 100, y: 500, width: 720, height: 450))
        assertFrame(.bottomRightQuarter, in: offset, NSRect(x: 820, y: 50, width: 720, height: 450))
    }

    // MARK: Thirds & two-thirds

    func testThirds() {
        assertFrame(.leftThird, in: origin, NSRect(x: 0, y: 0, width: 480, height: 900))
        assertFrame(.centerThird, in: origin, NSRect(x: 480, y: 0, width: 480, height: 900))
        assertFrame(.rightThird, in: origin, NSRect(x: 960, y: 0, width: 480, height: 900))
    }

    func testTwoThirds() {
        assertFrame(.leftTwoThirds, in: origin, NSRect(x: 0, y: 0, width: 960, height: 900))
        assertFrame(.rightTwoThirds, in: origin, NSRect(x: 480, y: 0, width: 960, height: 900))
    }

    func testThirdsOffsetScreen() {
        assertFrame(.rightThird, in: offset, NSRect(x: 1060, y: 50, width: 480, height: 900))
        assertFrame(.leftTwoThirds, in: offset, NSRect(x: 100, y: 50, width: 960, height: 900))
    }

    // MARK: Maximize

    func testMaximize() {
        assertFrame(.maximize, in: origin, origin)
        assertFrame(.maximize, in: offset, offset)
    }

    // MARK: Center (size-preserving, no resize)

    func testCenterKeepsSizeAndCentersInOrigin() {
        let frame = WindowZone.centered(NSSize(width: 800, height: 600), in: origin)
        XCTAssertEqual(frame, NSRect(x: 320, y: 150, width: 800, height: 600))
    }

    func testCenterKeepsSizeAndCentersInOffsetScreen() {
        let frame = WindowZone.centered(NSSize(width: 800, height: 600), in: offset)
        XCTAssertEqual(frame, NSRect(x: 420, y: 200, width: 800, height: 600))
    }

    func testCenterZoneDoesNotResize() {
        XCTAssertFalse(WindowZone.center.resizes)
        XCTAssertTrue(WindowZone.leftHalf.resizes)
    }
}
