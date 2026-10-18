import Carbon.HIToolbox
import XCTest
@testable import PearCompanion

/// The Shortcuts page's contract with the registry: one place answers "who owns
/// this chord?" for tool hotkeys and the Windows snap chords alike, a Windows
/// chord change reaches the running tool with no relaunch, and Reset all clears
/// both sets. Windows chords live in an injected suite; tool enabled state and
/// overrides are `.standard`-only, so those keys are scrubbed in a `defer`.
@MainActor
final class ShortcutRegistryTests: XCTestCase {
    /// Stands in for `WindowsTool` by id, counting the stop/start pair that
    /// re-registers its chords. Real Windows wiring (tap, ring) never loads.
    private final class FakeWindowsTool: Tool {
        let id = WindowsTool.toolID
        let title = "Windows"
        let icon = "star"
        let hotkey: HotKeyChord? = nil
        var acceptsHotkey: Bool { false }
        private(set) var startCount = 0
        private(set) var stopCount = 0
        var entry: ToolEntry { .action {} }
        func start() { startCount += 1 }
        func stop() { stopCount += 1 }
    }

    private final class FakeTool: Tool {
        let id: String
        let title: String
        let icon = "star"
        let hotkey: HotKeyChord?
        init(id: String, title: String, hotkey: HotKeyChord? = nil) {
            self.id = id
            self.title = title
            self.hotkey = hotkey
        }
        var entry: ToolEntry { .action {} }
    }

    private let suiteName = "ShortcutRegistryTests"
    private let ids = [WindowsTool.toolID, "fake.a", "fake.b"]

    private let ctrlOpt = controlKey | optionKey
    private lazy var leftHalf = HotKeyChord(keyCode: kVK_LeftArrow, modifiers: ctrlOpt, label: "⌃⌥←")
    private lazy var rightHalf = HotKeyChord(keyCode: kVK_RightArrow, modifiers: ctrlOpt, label: "⌃⌥→")
    private let custom = HotKeyChord(
        keyCode: kVK_ANSI_1, modifiers: controlKey | optionKey | shiftKey, label: "⌃⌥⇧1")
    private let betaDefault = HotKeyChord(keyCode: kVK_ANSI_8, modifiers: cmdKey | shiftKey, label: "⌘⇧8")

    private func makeStore() throws -> UserDefaults {
        let store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store.removePersistentDomain(forName: suiteName)
        return store
    }

    private func scrub() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        for id in ids {
            UserDefaults.standard.removeObject(forKey: Prefs.toolEnabledKey(id))
            UserDefaults.standard.removeObject(forKey: Prefs.toolHotkeyKey(id))
        }
    }

    // MARK: - Tool chord vs live Windows chord

    /// The check reads the Windows bindings as they are now, not the defaults:
    /// a moved chord conflicts at its new place, and frees its old one. The
    /// warning names the action, not just the tool.
    func testToolChordConflictsWithTheLiveWindowsChord() throws {
        scrub()
        defer { scrub() }
        let store = try makeStore()
        let registry = ToolRegistry(windowsStore: store)
        registry.offer(FakeWindowsTool())
        registry.offer(FakeTool(id: "fake.b", title: "Beta"))

        XCTAssertEqual(registry.conflictingTool(for: leftHalf, excluding: .tool("fake.b")), "Windows: Left Half")

        registry.setWindowsChord(custom, for: "left-half")
        XCTAssertEqual(registry.conflictingTool(for: custom, excluding: .tool("fake.b")), "Windows: Left Half")
        XCTAssertNil(registry.conflictingTool(for: leftHalf, excluding: .tool("fake.b")))
    }

    /// A Windows chord stored before launch is live from the first check.
    func testStoredWindowsChordIsLiveAtLaunch() throws {
        scrub()
        defer { scrub() }
        let store = try makeStore()
        WindowSettings.setChord(custom, for: "center", store)
        let registry = ToolRegistry(windowsStore: store)
        registry.offer(FakeWindowsTool())
        registry.offer(FakeTool(id: "fake.b", title: "Beta"))

        XCTAssertEqual(registry.conflictingTool(for: custom, excluding: .tool("fake.b")), "Windows: Center")
    }

    /// Windows off registers no chords, so they block nothing — the same rule a
    /// disabled tool's hotkey follows.
    func testDisabledWindowsChordsDoNotBlockToolChords() throws {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry(windowsStore: try makeStore())
        registry.offer(FakeWindowsTool())
        registry.offer(FakeTool(id: "fake.b", title: "Beta"))
        registry.setEnabled(WindowsTool.toolID, false)

        XCTAssertNil(registry.conflictingTool(for: leftHalf, excluding: .tool("fake.b")))
    }

    /// A removed Windows chord frees its keys.
    func testRemovedWindowsChordIsFree() throws {
        scrub()
        defer { scrub() }
        let store = try makeStore()
        let registry = ToolRegistry(windowsStore: store)
        registry.offer(FakeWindowsTool())
        registry.offer(FakeTool(id: "fake.b", title: "Beta"))

        registry.removeWindowsChord("left-half")
        XCTAssertNil(registry.windowsChord(for: "left-half"))
        XCTAssertNil(WindowSettings.chords(store).first { $0.id == "left-half" })
        XCTAssertNil(registry.conflictingTool(for: leftHalf, excluding: .tool("fake.b")))
        XCTAssertTrue(registry.isWindowsChordCustomized("left-half"))
    }

    // MARK: - Windows chord vs every tool chord

    func testWindowsChordConflictsWithToolEffectiveChords() throws {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry(windowsStore: try makeStore())
        registry.offer(FakeWindowsTool())
        registry.offer(FakeTool(id: "fake.a", title: "Alpha"))
        registry.offer(FakeTool(id: "fake.b", title: "Beta", hotkey: betaDefault))

        // A default chord…
        XCTAssertEqual(registry.conflictingTool(for: betaDefault, excluding: .windows("left-half")), "Beta")
        // …and an override both count.
        registry.setHotkeyOverride("fake.a", custom)
        XCTAssertEqual(registry.conflictingTool(for: custom, excluding: .windows("left-half")), "Alpha")
        // A removed tool shortcut no longer does.
        registry.removeHotkey("fake.b")
        XCTAssertNil(registry.conflictingTool(for: betaDefault, excluding: .windows("left-half")))
    }

    /// Two Windows bindings on one chord: the first would silently win, so the
    /// other binding is named — and a binding is never its own conflict. This
    /// holds with Windows off too, because the clash is inside the set being
    /// edited and would bite the moment it is turned on.
    func testWindowsChordConflictsWithAnotherWindowsChord() throws {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry(windowsStore: try makeStore())
        registry.offer(FakeWindowsTool())
        registry.setEnabled(WindowsTool.toolID, false)

        XCTAssertEqual(
            registry.conflictingTool(for: rightHalf, excluding: .windows("left-half")), "Windows: Right Half")
        XCTAssertNil(registry.conflictingTool(for: rightHalf, excluding: .windows("right-half")))
    }

    // MARK: - Live re-registration

    /// The Windows tool registers its chords itself in `start()`, so a chord
    /// change restarts it: the new chord is live without a relaunch.
    func testWindowsChordChangeReRegistersTheRunningTool() throws {
        scrub()
        defer { scrub() }
        let store = try makeStore()
        let registry = ToolRegistry(windowsStore: store)
        let windows = FakeWindowsTool()
        registry.offer(windows)
        XCTAssertEqual(windows.startCount, 1)

        registry.setWindowsChord(custom, for: "left-half")
        XCTAssertEqual(windows.stopCount, 1)
        XCTAssertEqual(windows.startCount, 2)
        XCTAssertEqual(WindowSettings.chords(store).first { $0.id == "left-half" }?.chord, custom)
        XCTAssertEqual(registry.windowsChord(for: "left-half"), custom)

        registry.removeWindowsChord("right-half")
        XCTAssertEqual(windows.startCount, 3)

        registry.setWindowsChord(nil, for: "left-half")
        XCTAssertEqual(windows.startCount, 4)
        XCTAssertEqual(registry.windowsChord(for: "left-half"), leftHalf)
    }

    /// Off stays off: a chord change only stores the value for the next enable.
    func testWindowsChordChangeDoesNotStartADisabledTool() throws {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry(windowsStore: try makeStore())
        let windows = FakeWindowsTool()
        registry.offer(windows)
        registry.setEnabled(WindowsTool.toolID, false)
        let starts = windows.startCount

        registry.setWindowsChord(custom, for: "left-half")
        XCTAssertEqual(windows.startCount, starts)
        XCTAssertEqual(registry.windowsChord(for: "left-half"), custom)
    }

    // MARK: - Reset all

    func testResetAllClearsToolOverridesAndWindowsChords() throws {
        scrub()
        defer { scrub() }
        let store = try makeStore()
        let registry = ToolRegistry(windowsStore: store)
        let windows = FakeWindowsTool()
        registry.offer(windows)
        registry.offer(FakeTool(id: "fake.a", title: "Alpha"))
        registry.offer(FakeTool(id: "fake.b", title: "Beta", hotkey: betaDefault))

        registry.setHotkeyOverride("fake.a", custom)
        registry.removeHotkey("fake.b")
        registry.setWindowsChord(betaDefault, for: "left-half")
        registry.removeWindowsChord("center")
        let starts = windows.startCount

        registry.resetAllShortcuts()

        XCTAssertFalse(registry.hasHotkeyOverride("fake.a"))
        XCTAssertFalse(registry.hasHotkeyOverride("fake.b"))
        XCTAssertNil(registry.hotkeyLabel(for: "fake.a"))
        XCTAssertEqual(registry.hotkeyLabel(for: "fake.b"), "⌘⇧8")
        XCTAssertEqual(registry.windowsChords, WindowSettings.chordDefaults)
        XCTAssertEqual(WindowSettings.chords(store), WindowSettings.chordDefaults)
        XCTAssertFalse(registry.isWindowsChordCustomized("left-half"))
        XCTAssertFalse(registry.isWindowsChordCustomized("center"))
        XCTAssertEqual(windows.startCount, starts + 1, "reset reaches the running Windows tool too")
    }
}
