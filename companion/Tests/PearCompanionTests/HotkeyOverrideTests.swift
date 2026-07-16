import Carbon.HIToolbox
import XCTest
@testable import PearCompanion

@MainActor
final class HotkeyOverrideTests: XCTestCase {
    /// Records start()/stop() so the live-toggle path is observable. Nil hotkey
    /// keeps the registry off the real HotKeyManager unless an override is set.
    private final class FakeTool: Tool {
        let id: String
        let title: String
        let icon = "star"
        let hotkey: HotKeyChord?
        private(set) var startCount = 0
        private(set) var stopCount = 0

        init(id: String, title: String, hotkey: HotKeyChord? = nil) {
            self.id = id
            self.title = title
            self.hotkey = hotkey
        }

        var entry: ToolEntry { .action {} }
        func start() { startCount += 1 }
        func stop() { stopCount += 1 }
    }

    /// The registry reads/writes UserDefaults.standard for enabled state and
    /// overrides (only the override *round-trip* accepts an injected suite), so
    /// scrub any keys a test touches at its start and end. Overriding
    /// `setUp`/`tearDown` would cross the `@MainActor` boundary, so tests scrub
    /// inline with `defer` — the pattern the other suites here use.
    private func scrub() {
        for id in ["fake.a", "fake.b", "windows"] {
            UserDefaults.standard.removeObject(forKey: Prefs.toolEnabledKey(id))
            UserDefaults.standard.removeObject(forKey: Prefs.toolHotkeyKey(id))
        }
    }

    // MARK: - Prefs override round-trip

    func testHotkeyOverrideRoundTripSetGetClear() throws {
        let suite = "HotkeyOverrideTests-prefs"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(Prefs.hotkeyOverride("colorPicker", defaults: defaults))

        let chord = HotKeyChord(keyCode: kVK_ANSI_Q, modifiers: controlKey | shiftKey, label: "⌃⇧Q")
        Prefs.setHotkeyOverride("colorPicker", chord, defaults: defaults)
        XCTAssertEqual(Prefs.hotkeyOverride("colorPicker", defaults: defaults), chord)

        Prefs.setHotkeyOverride("colorPicker", nil, defaults: defaults)
        XCTAssertNil(Prefs.hotkeyOverride("colorPicker", defaults: defaults))
    }

    /// The explicit-removal sentinel: `removeHotkey` marks the binding gone
    /// (even for a tool with a default), `hotkeyOverride` parses it as no
    /// chord, and recording or resetting replaces it.
    func testHotkeyRemovalSentinelRoundTrip() throws {
        let suite = "HotkeyOverrideTests-removal"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(Prefs.isHotkeyRemoved("screenshot", defaults: defaults))
        XCTAssertFalse(Prefs.hasHotkeyCustomization("screenshot", defaults: defaults))

        Prefs.removeHotkey("screenshot", defaults: defaults)
        XCTAssertTrue(Prefs.isHotkeyRemoved("screenshot", defaults: defaults))
        XCTAssertTrue(Prefs.hasHotkeyCustomization("screenshot", defaults: defaults))
        // The sentinel parses as "no chord", so an older build reading it just
        // falls back to the default rather than tripping on a bad string.
        XCTAssertNil(Prefs.hotkeyOverride("screenshot", defaults: defaults))

        // Recording a chord replaces the removal…
        let chord = HotKeyChord(keyCode: kVK_ANSI_Q, modifiers: controlKey | shiftKey, label: "⌃⇧Q")
        Prefs.setHotkeyOverride("screenshot", chord, defaults: defaults)
        XCTAssertFalse(Prefs.isHotkeyRemoved("screenshot", defaults: defaults))
        XCTAssertEqual(Prefs.hotkeyOverride("screenshot", defaults: defaults), chord)

        // …and reset-to-default clears every customization.
        Prefs.setHotkeyOverride("screenshot", nil, defaults: defaults)
        XCTAssertFalse(Prefs.hasHotkeyCustomization("screenshot", defaults: defaults))
    }

    // MARK: - Conflict detection

    func testConflictMatchesSameChordAndIgnoresDifferentModifiers() {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry()
        registry.offer(FakeTool(id: "fake.a", title: "Alpha"))
        registry.offer(FakeTool(id: "fake.b", title: "Beta"))

        let chord = HotKeyChord(keyCode: kVK_ANSI_9, modifiers: cmdKey | shiftKey, label: "⌘⇧9")
        registry.setHotkeyOverride("fake.a", chord)
        defer { registry.setHotkeyOverride("fake.a", nil) } // unregister the real hotkey

        // Same keyCode+modifiers, seen from another tool → conflict with Alpha.
        XCTAssertEqual(registry.conflictingTool(for: chord, excluding: "fake.b"), "Alpha")

        // Excluding the owner itself is not a conflict.
        XCTAssertNil(registry.conflictingTool(for: chord, excluding: "fake.a"))

        // Same key, different modifiers → free.
        let other = HotKeyChord(keyCode: kVK_ANSI_9, modifiers: cmdKey | optionKey, label: "⌘⌥9")
        XCTAssertNil(registry.conflictingTool(for: other, excluding: "fake.b"))
    }

    func testConflictDetectsWindowsZoneChord() {
        scrub()
        defer { scrub() }
        Prefs.setToolEnabled("windows", true)
        let registry = ToolRegistry()
        registry.offer(FakeTool(id: "fake.a", title: "Alpha"))
        registry.offer(WindowsTool())
        defer { registry.setEnabled("windows", false) } // stop() unregisters the zone chords

        // ⌃⌥← is a Windows zone chord (left-half snap).
        let zoneChord = HotKeyChord(keyCode: kVK_LeftArrow, modifiers: controlKey | optionKey, label: "⌃⌥←")
        XCTAssertEqual(registry.conflictingTool(for: zoneChord, excluding: "fake.a"), "Windows")

        // Same key without the zone modifiers → not a zone chord.
        let plain = HotKeyChord(keyCode: kVK_LeftArrow, modifiers: cmdKey, label: "⌘←")
        XCTAssertNil(registry.conflictingTool(for: plain, excluding: "fake.a"))
    }

    // MARK: - Live enable / disable

    func testSetEnabledStartsStopsAndPreservesOfferOrder() {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry()
        let a = FakeTool(id: "fake.a", title: "Alpha")
        let b = FakeTool(id: "fake.b", title: "Beta")
        registry.offer(a)
        registry.offer(b)

        // Both default-enabled: started once, present in offer order.
        XCTAssertEqual(a.startCount, 1)
        XCTAssertEqual(b.startCount, 1)
        XCTAssertEqual(registry.all.map(\.id), ["fake.a", "fake.b"])

        // Disable the first: stop() runs, it leaves `all`, order otherwise holds.
        registry.setEnabled("fake.a", false)
        XCTAssertEqual(a.stopCount, 1)
        XCTAssertEqual(registry.all.map(\.id), ["fake.b"])

        // Re-enable: start() runs again and it returns to its offer position.
        registry.setEnabled("fake.a", true)
        XCTAssertEqual(a.startCount, 2)
        XCTAssertEqual(registry.all.map(\.id), ["fake.a", "fake.b"])
    }

    // MARK: - Label formatting

    func testLabelFormatting() {
        XCTAssertEqual(
            HotkeyRecording.label(keyCode: kVK_ANSI_P, carbonModifiers: controlKey | shiftKey, characters: "p"),
            "⌃⇧P")
        XCTAssertEqual(
            HotkeyRecording.label(keyCode: kVK_LeftArrow, carbonModifiers: cmdKey, characters: nil),
            "⌘←")
    }
}
