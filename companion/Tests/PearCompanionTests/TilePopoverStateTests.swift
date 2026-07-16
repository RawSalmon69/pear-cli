import XCTest

@testable import PearCompanion

/// Pins the two dead-tile mechanisms in the panel's popover state: a stale
/// active ID surviving the panel closing with a popover up, and an old
/// popover's late dismissal callback clearing a newer request.
final class TilePopoverStateTests: XCTestCase {
    func testRequestPresentsImmediately() {
        var state = TilePopoverState()
        XCTAssertFalse(state.request("colors"))
        XCTAssertEqual(state.activeID, "colors")
    }

    func testSwitchingTilesMovesActiveID() {
        var state = TilePopoverState()
        _ = state.request("colors")
        XCTAssertFalse(state.request("windows"))
        XCTAssertEqual(state.activeID, "windows")
    }

    /// The A→B race: A's dismissal callback lands after B was requested and
    /// must not clear B. The old unconditional `activePopoverID = nil` did,
    /// which killed B's popover before it ever presented.
    func testLateDismissalOfOldPopoverKeepsNewRequest() {
        var state = TilePopoverState()
        _ = state.request("colors")
        _ = state.request("windows")
        state.dismissed("colors")
        XCTAssertEqual(state.activeID, "windows")
    }

    func testOwnDismissalClears() {
        var state = TilePopoverState()
        _ = state.request("colors")
        state.dismissed("colors")
        XCTAssertNil(state.activeID)
    }

    /// The stale-ID case: panel closed with a popover up and no dismissal
    /// handshake ever ran. Clicking the same tile again must demand a
    /// deferred re-present (nil first, then the ID again) instead of being
    /// the no-op that left the tile permanently dead.
    func testSameTileClickWithStaleIDRequestsRepresent() {
        var state = TilePopoverState()
        _ = state.request("colors")
        XCTAssertTrue(state.request("colors"))
        XCTAssertNil(state.activeID)
        state.present("colors")
        XCTAssertEqual(state.activeID, "colors")
    }

    func testPanelClosedResetsSoNextClickPresentsPlainly() {
        var state = TilePopoverState()
        _ = state.request("colors")
        state.panelClosed()
        XCTAssertNil(state.activeID)
        XCTAssertFalse(state.request("colors"))
        XCTAssertEqual(state.activeID, "colors")
    }
}
