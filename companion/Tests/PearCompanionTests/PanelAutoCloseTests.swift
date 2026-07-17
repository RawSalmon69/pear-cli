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
}
