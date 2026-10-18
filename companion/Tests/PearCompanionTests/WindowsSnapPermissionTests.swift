import XCTest

@testable import PearCompanion

/// A snap chord pressed without Accessibility says so instead of doing nothing.
/// The trust check and the refusal are injected: the real ones would read TCC
/// and raise the system prompt on the developer's machine.
@MainActor
final class WindowsSnapPermissionTests: XCTestCase {
    private final class RecordingMover: WindowMover {
        var commits: [WindowAction] = []
        func preview(_ action: WindowAction?, on window: AXUIElement?) {}
        func commit(_ action: WindowAction, on window: AXUIElement?) { commits.append(action) }
    }

    func testSnapWithoutAccessibilityRefusesAndMovesNothing() {
        let mover = RecordingMover()
        var refusals = 0
        let tool = WindowsTool(mover: mover, accessibilityTrusted: { false },
                               refuseUntrusted: { refusals += 1 })
        tool.snapRequested(.center)
        XCTAssertEqual(refusals, 1)
        XCTAssertEqual(mover.commits, [])
    }

    func testSnapWithAccessibilityMovesTheWindow() {
        let mover = RecordingMover()
        var refusals = 0
        let tool = WindowsTool(mover: mover, accessibilityTrusted: { true },
                               refuseUntrusted: { refusals += 1 })
        tool.snapRequested(.center)
        XCTAssertEqual(refusals, 0)
        XCTAssertEqual(mover.commits, [.center])
    }
}
