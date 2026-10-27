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
/// external monitor is the bug this replaced. Displays are identified by their
/// `CGDirectDisplayID`, never by `visibleFrame`, which moves under the stack
/// whenever the Dock or menu bar does.
@MainActor
final class ScreenshotAnchorTests: XCTestCase {
    private let laptop: CGDirectDisplayID = 1
    private let external: CGDirectDisplayID = 2
    private var both: [CGDirectDisplayID] { [laptop, external] }

    func testACaptureAnchorsToItsOwnScreen() {
        XCTAssertEqual(
            ScreenshotPreviewController.anchor(
                captured: external, current: nil, available: both, fallback: laptop),
            external)
    }

    /// The whole point: the menu-bar display does not win just because it is first.
    func testASecondaryScreenCaptureDoesNotSnapBackToTheMenuBarDisplay() {
        let anchor = ScreenshotPreviewController.anchor(
            captured: external, current: laptop, available: both, fallback: laptop)
        XCTAssertEqual(anchor, external)
        XCTAssertNotEqual(anchor, laptop)
    }

    /// A screen-parameter change (or any re-resolve with no new capture and no
    /// focus to follow) keeps the stack where it is.
    func testAReResolveKeepsTheStacksCurrentScreen() {
        XCTAssertEqual(
            ScreenshotPreviewController.anchor(
                captured: nil, current: external, available: both, fallback: laptop),
            external)
    }

    /// The Dock moving to the external display, or auto-hiding, changes that
    /// display's visibleFrame but not its id. Keyed by the old frame, the stack
    /// lost its display and jumped to the menu-bar one; keyed by id it stays.
    func testSameDisplayWithAChangedVisibleFrameStaysPut() {
        // The display set is unchanged: only frames moved, which the decision
        // never sees.
        XCTAssertEqual(
            ScreenshotPreviewController.anchor(
                captured: nil, current: external, available: [external, laptop], fallback: laptop),
            external)
    }

    /// A display unplugged between the capture and the card is gone from
    /// `available`; the card must land somewhere real rather than off-screen.
    func testAnUnpluggedCaptureScreenFallsBack() {
        XCTAssertEqual(
            ScreenshotPreviewController.anchor(
                captured: external, current: nil, available: [laptop], fallback: laptop),
            laptop)
    }

    /// The stack's display unplugged with cards up: the re-resolve on the
    /// screen-parameter change lands it on the menu-bar display.
    func testAnUnpluggedCurrentAnchorFallsBack() {
        XCTAssertEqual(
            ScreenshotPreviewController.anchor(
                captured: nil, current: external, available: [laptop], fallback: laptop),
            laptop)
    }

    /// Focus moving to the other display re-anchors a live stack through the
    /// same decision: the cards follow the user rather than sitting on the
    /// display they left.
    func testFocusMovingToAnotherScreenMovesTheStack() {
        XCTAssertEqual(
            ScreenshotPreviewController.anchor(
                captured: nil, focused: laptop, current: external, available: both, fallback: laptop),
            laptop)
    }

    /// A fresh stack with no capture screen (opened from the panel's Recent
    /// strip, or an edit re-presented after its card left) opens where the user
    /// is now. The emptied stack's old display is stale: it used to win here,
    /// so a Recent-strip open landed on whatever display the last stack was on.
    func testAFreshStackWithNoCaptureScreenOpensOnTheFocusedScreen() {
        XCTAssertEqual(
            ScreenshotPreviewController.anchor(
                captured: nil, focused: external, current: laptop, available: both, fallback: laptop),
            external)
    }

    /// First card of a fresh stack with nothing to go on.
    func testNoCaptureNoFocusAndNoCurrentAnchorFallsBack() {
        XCTAssertEqual(
            ScreenshotPreviewController.anchor(
                captured: nil, current: nil, available: both, fallback: laptop),
            laptop)
    }
}
