import Carbon.HIToolbox
import XCTest
@testable import PearCompanion

/// A tool page's status block: the registry's last-error hook (one line per
/// tool, in memory only), what it says about the shortcut, and the capture
/// failures that report through the hook. Enabled state and chords are
/// `.standard`-only, so those keys are scrubbed in a `defer`.
@MainActor
final class ToolStatusTests: XCTestCase {
    private final class FakeTool: Tool {
        let id: String
        let title = "Fake"
        let icon = "star"
        let hotkey: HotKeyChord?
        let acceptsHotkey: Bool
        init(id: String, hotkey: HotKeyChord? = nil, acceptsHotkey: Bool = true) {
            self.id = id
            self.hotkey = hotkey
            self.acceptsHotkey = acceptsHotkey
        }
        var entry: ToolEntry { .action {} }
    }

    private let ids = ["fake.a", "fake.b"]
    private let chord = HotKeyChord(keyCode: kVK_ANSI_8, modifiers: cmdKey | shiftKey, label: "⌘⇧8")

    private func scrub() {
        for id in ids {
            UserDefaults.standard.removeObject(forKey: Prefs.toolEnabledKey(id))
            UserDefaults.standard.removeObject(forKey: Prefs.toolHotkeyKey(id))
        }
    }

    // MARK: - Last error

    func testAReportedErrorIsReturnedForThatToolOnly() {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry()
        registry.offer(FakeTool(id: "fake.a"))
        registry.offer(FakeTool(id: "fake.b"))
        XCTAssertNil(registry.lastError(for: "fake.a"))

        registry.reportError("Screen Recording is off", for: "fake.a")
        XCTAssertEqual(registry.lastError(for: "fake.a"), "Screen Recording is off")
        XCTAssertNil(registry.lastError(for: "fake.b"))
    }

    func testTheNextReportReplacesTheLastOne() {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry()
        registry.offer(FakeTool(id: "fake.a"))
        registry.reportError("first", for: "fake.a")
        registry.reportError("second", for: "fake.a")
        XCTAssertEqual(registry.lastError(for: "fake.a"), "second")
    }

    /// Turning a tool off (or on) starts it clean, so an old error does not
    /// outlive the tool being reset.
    func testTurningAToolOffOrOnClearsItsError() {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry()
        registry.offer(FakeTool(id: "fake.a"))
        registry.reportError("broken", for: "fake.a")
        registry.setEnabled("fake.a", false)
        XCTAssertNil(registry.lastError(for: "fake.a"))
        registry.reportError("broken", for: "fake.a")
        registry.setEnabled("fake.a", true)
        XCTAssertNil(registry.lastError(for: "fake.a"))
    }

    // MARK: - Shortcut status

    func testShortcutStatusFollowsTheRegistry() {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry()
        registry.offer(FakeTool(id: "fake.a", hotkey: chord))
        registry.offer(FakeTool(id: "fake.b", acceptsHotkey: false))

        XCTAssertEqual(registry.shortcutStatus(for: "fake.b"), .notOffered)
        // Under XCTest the registry claims no Carbon hotkey, so an enabled tool
        // with a chord reads as not registered: the status reports what really
        // registered, not just that a chord exists.
        XCTAssertEqual(registry.shortcutStatus(for: "fake.a"), .notRegistered("⌘⇧8"))

        registry.setEnabled("fake.a", false)
        XCTAssertEqual(registry.shortcutStatus(for: "fake.a"), .toolOff("⌘⇧8"))

        registry.setEnabled("fake.a", true)
        registry.removeHotkey("fake.a")
        XCTAssertEqual(registry.shortcutStatus(for: "fake.a"), .none)
    }

    // MARK: - Capture failures

    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// No file written: a launch failure, a denial, or a plain Esc. Only the
    /// first two are errors. The launcher grabs nothing (a real one would
    /// screenshot whoever runs the suite).
    private func runCapture(launched: Bool, denied: Bool) async -> [String] {
        let reports = Reports()
        _ = await ScreenCapture.run(
            ["-x", "/dev/null"],
            writing: URL(fileURLWithPath: "/nonexistent/pear-status-test.png"),
            tool: "screenshot",
            launch: { _ in launched },
            wroteNothing: { denied },
            report: { message, tool in reports.add("\(tool): \(message)") })
        return reports.all
    }

    func testACaptureThatCouldNotLaunchReportsIt() async {
        let reports = await runCapture(launched: false, denied: false)
        XCTAssertEqual(reports, ["screenshot: \(ScreenCapture.launchFailedMessage)"])
    }

    func testADeniedCaptureReportsScreenRecording() async {
        let reports = await runCapture(launched: true, denied: true)
        XCTAssertEqual(reports, ["screenshot: \(ScreenCapture.deniedMessage)"])
    }

    func testACancelledCaptureReportsNothing() async {
        let reports = await runCapture(launched: true, denied: false)
        XCTAssertEqual(reports, [])
    }
}
