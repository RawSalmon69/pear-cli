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

    /// A tool that owns a set of chords it registers itself, like the Windows
    /// tool. `hotkey` stays nil so nothing reaches the real HotKeyManager.
    private final class MultiChordTool: Tool {
        let id: String
        let title: String
        let icon = "star"
        let hotkey: HotKeyChord? = nil
        let extraChords: [HotKeyChord]

        init(id: String, title: String, extra: [HotKeyChord]) {
            self.id = id
            self.title = title
            self.extraChords = extra
        }

        var entry: ToolEntry { .action {} }
    }

    /// The registry reads/writes UserDefaults.standard for enabled state and
    /// overrides (only the override *round-trip* accepts an injected suite), so
    /// scrub any keys a test touches at its start and end. Overriding
    /// `setUp`/`tearDown` would cross the `@MainActor` boundary, so tests scrub
    /// inline with `defer` — the pattern the other suites here use.
    private func scrub() {
        for id in ["fake.a", "fake.b", "fake.multi"] {
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

    /// A tool that registers its own set of chords (the Windows tool and its
    /// ⌃⌥ snapping family) never routes them through the registry, so the
    /// recorder can only know about them through `extraChords`. Without this the
    /// user is told a chord is free and it then silently loses at runtime.
    func testConflictSeesToolOwnedExtraChords() {
        scrub()
        defer { scrub() }
        let owned = HotKeyChord(keyCode: kVK_LeftArrow, modifiers: controlKey | optionKey, label: "⌃⌥←")
        let registry = ToolRegistry()
        registry.offer(MultiChordTool(id: "fake.multi", title: "Multi", extra: [owned]))
        registry.offer(FakeTool(id: "fake.b", title: "Beta"))

        XCTAssertEqual(registry.conflictingTool(for: owned, excluding: "fake.b"), "Multi")
        XCTAssertNil(registry.conflictingTool(for: owned, excluding: "fake.multi"))

        // A different chord is still free.
        let free = HotKeyChord(keyCode: kVK_RightArrow, modifiers: controlKey | optionKey, label: "⌃⌥→")
        XCTAssertNil(registry.conflictingTool(for: free, excluding: "fake.b"))
    }

    /// Disabled tools register nothing, so their owned chords are not conflicts
    /// either — same rule the single-`hotkey` path already follows.
    func testDisabledToolsExtraChordsAreNotConflicts() {
        scrub()
        defer { scrub() }
        let owned = HotKeyChord(keyCode: kVK_UpArrow, modifiers: controlKey | optionKey, label: "⌃⌥↑")
        let registry = ToolRegistry()
        registry.offer(MultiChordTool(id: "fake.multi", title: "Multi", extra: [owned]))
        registry.offer(FakeTool(id: "fake.b", title: "Beta"))

        registry.setEnabled("fake.multi", false)
        XCTAssertNil(registry.conflictingTool(for: owned, excluding: "fake.b"))
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

    // MARK: - Remapped default chords (v2.3.x panel round)

    /// The owner-specified defaults: panel toggle claims ⌃⇧P; Screenshot moved
    /// to ⌃⇧S; Grab Text (OCR) moved to ⌃⇧T.
    func testRemappedDefaultChords() {
        XCTAssertEqual(
            ScreenshotTool(messaging: MockMessagingService()).hotkey,
            HotKeyChord(keyCode: kVK_ANSI_S, modifiers: controlKey | shiftKey, label: "⌃⇧S"))
        XCTAssertEqual(
            OCRTool().hotkey,
            HotKeyChord(keyCode: kVK_ANSI_T, modifiers: controlKey | shiftKey, label: "⌃⇧T"))
        XCTAssertEqual(
            PanelTool().hotkey,
            HotKeyChord(keyCode: kVK_ANSI_P, modifiers: controlKey | shiftKey, label: "⌃⇧P"))
    }

    /// The extra capture modes ride ⌃⇧F / ⌃⇧W, each with its own id, and no
    /// default chord may be claimed twice.
    func testCaptureModeChordsAreDistinct() {
        let full = ScreenshotTool(mode: .fullScreen, messaging: MockMessagingService())
        let window = ScreenshotTool(mode: .window, messaging: MockMessagingService())
        XCTAssertEqual(full.id, "screenshot-full")
        XCTAssertEqual(window.id, "screenshot-window")
        XCTAssertEqual(
            full.hotkey,
            HotKeyChord(keyCode: kVK_ANSI_F, modifiers: controlKey | shiftKey, label: "⌃⇧F"))
        XCTAssertEqual(
            window.hotkey,
            HotKeyChord(keyCode: kVK_ANSI_W, modifiers: controlKey | shiftKey, label: "⌃⇧W"))

        let tools: [any Tool] = [
            ScreenshotTool(messaging: MockMessagingService()), full, window, OCRTool(),
            QRTool(), ShelfTool(), ScratchpadTool(), KeyCluTool(), PanelTool(), ClipboardTool(),
        ]
        var claimed: [String: String] = [:]
        for tool in tools {
            guard let chord = tool.hotkey else { continue }
            let key = "\(chord.keyCode)-\(chord.modifiers)"
            XCTAssertNil(claimed[key], "\(tool.id) collides with \(claimed[key] ?? "")")
            claimed[key] = tool.id
        }
    }

    /// Remapping a *default* must never disturb a user override in
    /// `toolHotkey.*`. The tool is offered disabled so no real Carbon hotkey is
    /// registered; the effective label still resolves to the override.
    func testUserOverrideWinsOverRemappedDefault() {
        let id = "screenshot"
        let keys = [Prefs.toolEnabledKey(id), Prefs.toolHotkeyKey(id)]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

        let custom = HotKeyChord(keyCode: kVK_ANSI_9, modifiers: cmdKey | shiftKey, label: "⌘⇧9")
        Prefs.setHotkeyOverride(id, custom)
        Prefs.setToolEnabled(id, false)

        let registry = ToolRegistry()
        registry.offer(ScreenshotTool(messaging: MockMessagingService()))

        // The override wins over the new ⌃⇧S default.
        XCTAssertEqual(registry.hotkeyLabel(for: id), "⌘⇧9")
        XCTAssertTrue(registry.hasHotkeyOverride(id))
        XCTAssertTrue(registry.hasDefaultHotkey(id))
    }

    /// The panel toggle rides the same registry machinery, so conflict
    /// detection sees its default chord like any other tool's.
    func testPanelToolConflictsOnItsDefaultChord() {
        let ids = ["fake.a", "panel"]
        ids.forEach {
            UserDefaults.standard.removeObject(forKey: Prefs.toolEnabledKey($0))
            UserDefaults.standard.removeObject(forKey: Prefs.toolHotkeyKey($0))
        }
        defer {
            ids.forEach {
                UserDefaults.standard.removeObject(forKey: Prefs.toolEnabledKey($0))
                UserDefaults.standard.removeObject(forKey: Prefs.toolHotkeyKey($0))
            }
        }
        let registry = ToolRegistry()
        registry.offer(FakeTool(id: "fake.a", title: "Alpha"))
        registry.offer(PanelTool()) // default-enabled → registers the real ⌃⇧P
        defer { registry.setEnabled("panel", false) } // unregister it

        let panelChord = HotKeyChord(keyCode: kVK_ANSI_P, modifiers: controlKey | shiftKey, label: "⌃⇧P")
        XCTAssertEqual(registry.conflictingTool(for: panelChord, excluding: "fake.a"), "Companion Panel")
        // Excluding the panel itself is not a self-conflict.
        XCTAssertNil(registry.conflictingTool(for: panelChord, excluding: "panel"))
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

/// The settings toggle reads its state from `known`, so `setEnabled` has to
/// publish there. Bound straight to `UserDefaults` the write lands but the
/// switch never redraws, which shipped as "the tool turns on but the toggle
/// stays off until you click it twice".
@MainActor
final class ToolEnabledPublishingTests: XCTestCase {
    private final class FakeTool: Tool {
        let id: String
        let title = "Fake"
        let icon = "star"
        let hotkey: HotKeyChord? = nil
        init(id: String) { self.id = id }
        var entry: ToolEntry { .action {} }
    }

    private let id = "publish.fake"

    private func scrub() {
        UserDefaults.standard.removeObject(forKey: Prefs.toolEnabledKey(id))
        UserDefaults.standard.removeObject(forKey: Prefs.toolHotkeyKey(id))
    }

    func testTogglingPublishesTheNewStateWhereTheToggleReadsIt() {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry()
        registry.offer(FakeTool(id: id))
        XCTAssertTrue(registry.isEnabled(id), "a default-on tool reads as on")

        registry.setEnabled(id, false)
        XCTAssertFalse(registry.isEnabled(id), "off must be visible immediately")
        XCTAssertEqual(registry.known.first { $0.id == id }?.isEnabled, false)

        registry.setEnabled(id, true)
        XCTAssertTrue(registry.isEnabled(id), "and on again, without a second call")
        XCTAssertEqual(registry.known.first { $0.id == id }?.isEnabled, true)
    }

    /// The observable mirror must agree with the stored preference, or the switch
    /// and the behaviour drift apart.
    func testThePublishedStateMatchesThePreference() {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry()
        registry.offer(FakeTool(id: id))
        for value in [false, true, false] {
            registry.setEnabled(id, value)
            XCTAssertEqual(
                registry.isEnabled(id),
                Prefs.isToolEnabled(id, default: true),
                "mirror disagreed with Prefs at \(value)")
        }
    }

    /// A tool that ships off must not read as on before anyone touches it.
    func testADefaultOffToolReadsAsOff() {
        let offID = "publish.fake.off"
        UserDefaults.standard.removeObject(forKey: Prefs.toolEnabledKey(offID))
        defer { UserDefaults.standard.removeObject(forKey: Prefs.toolEnabledKey(offID)) }

        final class OffTool: Tool {
            let id: String
            let title = "Off"
            let icon = "star"
            let hotkey: HotKeyChord? = nil
            var defaultEnabled: Bool { false }
            init(id: String) { self.id = id }
            var entry: ToolEntry { .action {} }
        }
        let registry = ToolRegistry()
        registry.offer(OffTool(id: offID))
        XCTAssertFalse(registry.isEnabled(offID))
    }
}
