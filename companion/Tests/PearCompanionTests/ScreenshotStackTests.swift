import XCTest
import AppKit
@testable import PearCompanion

/// Pure layout + eviction math for the preview stack. The newest card (index
/// 0) sits nearest the bottom-right corner; higher indices stack upward.
final class ScreenshotStackTests: XCTestCase {
    private let panel = NSSize(width: 280, height: 236)
    private let margin: CGFloat = 20
    private let gap: CGFloat = 12
    private let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)

    private func origin(_ index: Int, in area: NSRect) -> NSPoint {
        PreviewStackLayout.origin(index: index, panelSize: panel, in: area, margin: margin, gap: gap)
    }

    func testNewestSitsAtBottomRight() {
        let p = origin(0, in: visible)
        XCTAssertEqual(p.x, 1440 - 280 - 20, accuracy: 0.001)
        XCTAssertEqual(p.y, 20, accuracy: 0.001)
    }

    func testHigherIndicesStackUpwardByPanelPlusGap() {
        XCTAssertEqual(origin(1, in: visible).y, 20 + (236 + 12), accuracy: 0.001)
        XCTAssertEqual(origin(2, in: visible).y, 20 + 2 * (236 + 12), accuracy: 0.001)
        // x stays constant up the column.
        XCTAssertEqual(origin(1, in: visible).x, origin(0, in: visible).x, accuracy: 0.001)
    }

    func testRespectsScreenOrigin() {
        let offset = NSRect(x: 100, y: 50, width: 1440, height: 900)
        let p = origin(0, in: offset)
        XCTAssertEqual(p.x, 100 + 1440 - 280 - 20, accuracy: 0.001)
        XCTAssertEqual(p.y, 50 + 20, accuracy: 0.001)
    }

    func testOffscreenOriginIsPastRightEdgeSameRow() {
        let home = origin(1, in: visible)
        let off = PreviewStackLayout.offscreenOrigin(for: home, panelSize: panel, in: visible)
        XCTAssertGreaterThan(off.x, visible.maxX)
        XCTAssertEqual(off.y, home.y, accuracy: 0.001)
    }

    func testEvictionKeepsNewest() {
        XCTAssertEqual(PreviewStackLayout.overflowIndices(count: 5, maxCount: 5), [])
        XCTAssertEqual(PreviewStackLayout.overflowIndices(count: 6, maxCount: 5), [5])
        XCTAssertEqual(PreviewStackLayout.overflowIndices(count: 7, maxCount: 5), [5, 6])
        XCTAssertEqual(PreviewStackLayout.overflowIndices(count: 2, maxCount: 5), [])
    }
}

/// Which display the preview stack anchors to. The card belongs on the screen
/// the shot was taken on: a capture on the laptop panel whose card lands on an
/// external monitor is the bug this replaced.
@MainActor
final class ScreenshotAnchorTests: XCTestCase {
    private let laptop = NSRect(x: 0, y: 0, width: 1512, height: 916)
    private let external = NSRect(x: 1512, y: 0, width: 2560, height: 1415)
    private var both: [NSRect] { [laptop, external] }

    func testACaptureAnchorsToItsOwnScreen() {
        XCTAssertEqual(
            ScreenshotPreviewController.anchor(
                captured: external, current: .zero, available: both, fallback: laptop),
            external)
    }

    /// The whole point: the menu-bar display does not win just because it is first.
    func testASecondaryScreenCaptureDoesNotSnapBackToTheMenuBarDisplay() {
        let anchor = ScreenshotPreviewController.anchor(
            captured: external, current: laptop, available: both, fallback: laptop)
        XCTAssertEqual(anchor, external)
        XCTAssertNotEqual(anchor, laptop)
    }

    /// Markup and background removal re-present with no capture screen. The
    /// edited shot must stay where its card already was.
    func testARepresentKeepsTheStacksCurrentScreen() {
        XCTAssertEqual(
            ScreenshotPreviewController.anchor(
                captured: nil, current: external, available: both, fallback: laptop),
            external)
    }

    /// A display unplugged between the capture and the card is gone from
    /// `available`; the card must land somewhere real rather than off-screen.
    func testAnUnpluggedCaptureScreenFallsBack() {
        XCTAssertEqual(
            ScreenshotPreviewController.anchor(
                captured: external, current: .zero, available: [laptop], fallback: laptop),
            laptop)
    }

    func testAnUnpluggedCurrentAnchorFallsBack() {
        XCTAssertEqual(
            ScreenshotPreviewController.anchor(
                captured: nil, current: external, available: [laptop], fallback: laptop),
            laptop)
    }

    /// First card of a fresh stack with no capture screen — nothing to keep.
    func testNoCaptureAndNoCurrentAnchorFallsBack() {
        XCTAssertEqual(
            ScreenshotPreviewController.anchor(
                captured: nil, current: .zero, available: both, fallback: laptop),
            laptop)
    }
}
