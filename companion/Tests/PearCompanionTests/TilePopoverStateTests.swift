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

    // MARK: - Visibility-driven toggle

    /// The new transition: a genuinely-open popover, re-clicked, closes plainly
    /// (no re-present) instead of the close-then-reopen flicker that read as a
    /// misclick.
    func testVisiblePopoverReclickClosesWithoutRepresent() {
        var state = TilePopoverState()
        _ = state.request("colors")
        state.didPresent("colors") // SwiftUI actually put it up
        XCTAssertFalse(state.request("colors")) // visible → plain close, no defer
        XCTAssertNil(state.activeID)
    }

    /// A stale active ID (content already gone, but SwiftUI still thinks it's
    /// up) still re-presents on the next runloop turn.
    func testStaleActiveIDReclickRepresents() {
        var state = TilePopoverState()
        _ = state.request("colors")
        state.didPresent("colors")
        state.didDismiss("colors") // content left, but activeID lingered
        XCTAssertTrue(state.request("colors")) // not visible → deferred re-present
        XCTAssertNil(state.activeID)
        state.present("colors")
        XCTAssertEqual(state.activeID, "colors")
    }

    /// A late onDisappear from an old popover must not clear the newer one's
    /// visibility, mirroring the `dismissed` owner-only guard.
    func testLateDidDismissOfOldPopoverKeepsNewVisibility() {
        var state = TilePopoverState()
        _ = state.request("colors")
        state.didPresent("colors")
        _ = state.request("windows")
        state.didPresent("windows")
        state.didDismiss("colors") // stale callback from the old popover
        XCTAssertEqual(state.visibleID, "windows")
        // The now-visible windows tile still closes plainly on re-click.
        XCTAssertFalse(state.request("windows"))
        XCTAssertNil(state.activeID)
    }

    func testPanelClosedClearsVisibility() {
        var state = TilePopoverState()
        _ = state.request("colors")
        state.didPresent("colors")
        state.panelClosed()
        XCTAssertNil(state.activeID)
        XCTAssertNil(state.visibleID)
    }
}
