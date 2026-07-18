import XCTest

@testable import PearCompanion

/// The close-on-focus-loss guard: close only when the user opted in AND focus
/// didn't move to one of the panel's own surfaces (Settings/Help popover =
/// child window, folder picker = attached sheet) or back to the panel itself.
@MainActor
final class PanelAutoCloseTests: XCTestCase {
    func testClosesWhenFocusLeavesToAnotherApp() {
        XCTAssertTrue(PanelController.shouldAutoClose(
            prefEnabled: true, hasChildWindows: false,
            hasAttachedSheet: false, panelIsKey: false))
    }

    func testNeverClosesWhenPrefDisabled() {
        XCTAssertFalse(PanelController.shouldAutoClose(
            prefEnabled: false, hasChildWindows: false,
            hasAttachedSheet: false, panelIsKey: false))
    }

    func testStaysOpenWhileOwnPopoverIsUp() {
        XCTAssertFalse(PanelController.shouldAutoClose(
            prefEnabled: true, hasChildWindows: true,
            hasAttachedSheet: false, panelIsKey: false))
    }

    func testStaysOpenWhileFolderPickerSheetIsUp() {
        XCTAssertFalse(PanelController.shouldAutoClose(
            prefEnabled: true, hasChildWindows: false,
            hasAttachedSheet: true, panelIsKey: false))
    }

    func testStaysOpenWhenPanelTookKeyBack() {
        XCTAssertFalse(PanelController.shouldAutoClose(
            prefEnabled: true, hasChildWindows: false,
            hasAttachedSheet: false, panelIsKey: true))
    }

    // MARK: - Vertical origin clamp (panel never opens off the top/bottom)

    /// A screen 0…900 (visibleFrame below a menu bar starts at maxY 900).
    private let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)

    func testNormalPositionUnchanged() {
        // Panel (height 300) anchored well within the screen stays put.
        XCTAssertEqual(
            PanelController.clampedVerticalOrigin(desiredY: 500, height: 300, visible: visible),
            500)
    }

    func testTopClampPullsAnOffTopPanelDown() {
        // Desired top would be 850+300 = 1150, above the visible top (900).
        // Pulled down so top == 900 → origin 600.
        XCTAssertEqual(
            PanelController.clampedVerticalOrigin(desiredY: 850, height: 300, visible: visible),
            600)
    }

    func testBottomClampKeepsAnOffBottomPanelOn() {
        XCTAssertEqual(
            PanelController.clampedVerticalOrigin(desiredY: -50, height: 300, visible: visible),
            8)
    }

    func testTallerThanScreenPinsToBottom() {
        // Panel taller than the visible height: both clamps conflict, bottom
        // wins (origin = minY + 8) so at least the top / greeting is on-screen.
        XCTAssertEqual(
            PanelController.clampedVerticalOrigin(desiredY: 500, height: 1000, visible: visible),
            8)
    }
}
