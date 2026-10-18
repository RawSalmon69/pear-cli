import XCTest
@testable import PearCompanion

/// The Shortcuts actions resolve their tool through `ToolRegistry.runnableTool`,
/// the same gate registration uses, so a tool switched off in Settings (or locked
/// by the paywall) answers with one plain sentence instead of running.
@MainActor
final class IntentResolutionTests: XCTestCase {
    private final class FakeTool: Tool {
        let id: String
        let title: String
        let icon = "star"
        let hotkey: HotKeyChord? = nil
        let survivesExpiry: Bool

        init(id: String, title: String, survivesExpiry: Bool = false) {
            self.id = id
            self.title = title
            self.survivesExpiry = survivesExpiry
        }

        var entry: ToolEntry { .action {} }
    }

    private func scrub() {
        for id in ["intent.a", "intent.b"] {
            UserDefaults.standard.removeObject(forKey: Prefs.toolEnabledKey(id))
        }
    }

    func testEnabledToolResolves() throws {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry()
        let tool = FakeTool(id: "intent.a", title: "Shot")
        registry.offer(tool)

        XCTAssertTrue(try registry.runnableTool("intent.a") === tool)
    }

    func testDisabledToolThrowsTurnedOff() {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry()
        registry.offer(FakeTool(id: "intent.a", title: "Window Shot"))
        registry.setEnabled("intent.a", false)

        XCTAssertThrowsError(try registry.runnableTool("intent.a")) { error in
            XCTAssertEqual((error as? ToolUnavailable)?.message,
                           "Window Shot is turned off in Pear Settings")
        }
    }

    /// Locked reads exactly like off: the registry's one gate decides, and a
    /// content tool that survives expiry still runs.
    func testLockedToolThrowsTurnedOffUnlessItSurvivesExpiry() throws {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry()
        registry.isLocked = { true }
        registry.offer(FakeTool(id: "intent.a", title: "Grab Text"))
        let content = FakeTool(id: "intent.b", title: "Shelf", survivesExpiry: true)
        registry.offer(content)

        XCTAssertThrowsError(try registry.runnableTool("intent.a")) { error in
            XCTAssertEqual((error as? ToolUnavailable)?.message,
                           "Grab Text is turned off in Pear Settings")
        }
        XCTAssertTrue(try registry.runnableTool("intent.b") === content)
    }
}
