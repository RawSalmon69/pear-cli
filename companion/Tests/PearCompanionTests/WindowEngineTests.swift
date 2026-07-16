import XCTest

@testable import PearCompanion

/// The radial ring's center-click now toggles native macOS fullscreen. Only the
/// pure decision — which "AXFullScreen" value to write next — is unit-testable;
/// the AX read/write around it needs a live window, so it's exercised by hand.
@MainActor
final class WindowEngineTests: XCTestCase {
    func testFullscreenDecision() {
        // Already fullscreen → exit.
        XCTAssertFalse(WindowEngine.nextFullscreenState(from: true))
        // Not fullscreen → enter.
        XCTAssertTrue(WindowEngine.nextFullscreenState(from: false))
        // No "AXFullScreen" attribute (window can't fullscreen) → treat as not
        // fullscreen and enter; the AX write then no-ops for such windows.
        XCTAssertTrue(WindowEngine.nextFullscreenState(from: nil))
    }
}
