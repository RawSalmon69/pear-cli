import AppIntents
import Foundation

// Pear's actions in Shortcuts (macOS 14+) and Spotlight (26+). Each resolves its
// tool through `ToolRegistry.runnableTool` — the gate registration uses, so a
// tool that is off (or locked) fails with "<Tool> is turned off in Pear
// Settings" — then calls the entry point its hotkey uses. No intent opens the
// app: Pear is an accessory app with no window to bring forward, and every tool
// here already works from the background (a hotkey never activates Pear
// either). The system launches Pear to run the action if it is not running.

/// Thrown when an action arrives before the app delegate set `ToolRegistry.live`.
struct PearNotReady: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "Pear is still starting. Try again." }
}

@MainActor
private func runnableTool(_ id: String) throws -> any Tool {
    guard let registry = ToolRegistry.live else { throw PearNotReady() }
    return try registry.runnableTool(id)
}

struct CaptureRegionIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Region"
    static let description = IntentDescription("Select a region of the screen to capture.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try runnableTool("screenshot").hotkeyFired()
        return .result()
    }
}

struct CaptureFullScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Full Screen"
    static let description = IntentDescription("Capture the whole screen at once.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try runnableTool("screenshot-full").hotkeyFired()
        return .result()
    }
}

struct CaptureWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Window"
    static let description = IntentDescription("Click a window to capture it.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try runnableTool("screenshot-window").hotkeyFired()
        return .result()
    }
}

struct GrabTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Grab Text"
    static let description = IntentDescription("Copy the text in a region of the screen.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try runnableTool("ocr").hotkeyFired()
        return .result()
    }
}

struct PickColorIntent: AppIntent {
    static let title: LocalizedStringResource = "Pick Color"
    static let description = IntentDescription("Pick a color on screen and copy it.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try runnableTool("colorPicker").hotkeyFired()
        return .result()
    }
}

struct ToggleKeepAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Keep Awake"
    static let description = IntentDescription("Turn Keep Awake on or off. Returns whether it is now on.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard let switches = try runnableTool("switches") as? SwitchesTool else {
            throw ToolUnavailable(title: "Switches")
        }
        return .result(value: switches.toggleKeepAwake())
    }
}

struct AddFileToShelfIntent: AppIntent {
    static let title: LocalizedStringResource = "Add File to Shelf"
    static let description = IntentDescription("Put a copy of a file on the Shelf.")

    @Parameter(title: "File")
    var file: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let shelf = try runnableTool("shelf") as? ShelfTool else {
            throw ToolUnavailable(title: "Shelf")
        }
        if let url = file.fileURL {
            await shelf.add(url)
        } else {
            // A file another action produced may arrive as data only. The shelf
            // copies what it is given, so the temp file can go straight after.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent(file.filename)
            try file.data.write(to: url)
            await shelf.add(url)
        }
        return .result()
    }
}

struct NewScratchpadNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Scratchpad Note"
    static let description = IntentDescription("Start a new Scratchpad note, optionally with text.")

    @Parameter(title: "Text")
    var text: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let scratchpad = try runnableTool("scratchpad") as? ScratchpadTool else {
            throw ToolUnavailable(title: "Scratchpad")
        }
        scratchpad.newNote(text: text)
        return .result()
    }
}

struct PearShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaptureRegionIntent(), phrases: ["Capture a region with \(.applicationName)"],
                    shortTitle: "Capture Region", systemImageName: "camera.viewfinder")
        AppShortcut(intent: CaptureFullScreenIntent(), phrases: ["Capture the screen with \(.applicationName)"],
                    shortTitle: "Capture Full Screen", systemImageName: "camera.on.rectangle")
        AppShortcut(intent: CaptureWindowIntent(), phrases: ["Capture a window with \(.applicationName)"],
                    shortTitle: "Capture Window", systemImageName: "macwindow.on.rectangle")
        AppShortcut(intent: GrabTextIntent(), phrases: ["Grab text with \(.applicationName)"],
                    shortTitle: "Grab Text", systemImageName: "text.viewfinder")
        AppShortcut(intent: PickColorIntent(), phrases: ["Pick a color with \(.applicationName)"],
                    shortTitle: "Pick Color", systemImageName: "eyedropper")
        AppShortcut(intent: ToggleKeepAwakeIntent(), phrases: ["Toggle Keep Awake in \(.applicationName)"],
                    shortTitle: "Toggle Keep Awake", systemImageName: "cup.and.saucer")
        AppShortcut(intent: AddFileToShelfIntent(), phrases: ["Add a file to the \(.applicationName) shelf"],
                    shortTitle: "Add File to Shelf", systemImageName: "tray.full")
        AppShortcut(intent: NewScratchpadNoteIntent(), phrases: ["New \(.applicationName) note"],
                    shortTitle: "New Scratchpad Note", systemImageName: "note.text")
    }
}
