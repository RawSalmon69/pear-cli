import SwiftUI
import Carbon.HIToolbox

// The four launch tools. Each holds its heavy service lazily; only the
// clipboard collector runs from launch (its history is worthless otherwise).

/// Screenshot → clipboard + preview + markup + send. Three modes, one tool:
/// region drag (⌃⇧S), whole screen (⌃⇧F), click-a-window (⌃⇧W). Everything
/// after the capture is identical, so only the `ScreenCapture` call and the
/// tile metadata differ. Each mode is offered as its own instance, so each
/// gets its own id, tile, and rebindable hotkey.
@MainActor
final class ScreenshotTool: Tool {
    enum Mode { case region, fullScreen, window }

    let id: String
    let title: String
    let icon: String
    let summary: String
    let hotkey: HotKeyChord?
    let category = ToolCategory.capture

    private let mode: Mode
    private let messaging: MessagingService
    private var service: ScreenshotService?

    init(mode: Mode = .region, messaging: MessagingService) {
        self.mode = mode
        self.messaging = messaging
        switch mode {
        case .region:
            id = "screenshot"
            title = "Screenshot"
            icon = "camera.viewfinder"
            summary = "Select a region. Copy it, mark it up, or save it."
            hotkey = HotKeyChord(keyCode: kVK_ANSI_S, modifiers: controlKey | shiftKey, label: "⌃⇧S")
        case .fullScreen:
            id = "screenshot-full"
            title = "Full-screen Shot"
            icon = "camera.on.rectangle"
            summary = "Capture the whole screen at once."
            hotkey = HotKeyChord(keyCode: kVK_ANSI_F, modifiers: controlKey | shiftKey, label: "⌃⇧F")
        case .window:
            id = "screenshot-window"
            title = "Window Shot"
            icon = "macwindow.on.rectangle"
            summary = "Click a window to grab it, shadow and all."
            hotkey = HotKeyChord(keyCode: kVK_ANSI_W, modifiers: controlKey | shiftKey, label: "⌃⇧W")
        }
    }

    var entry: ToolEntry {
        .action { [weak self] in
            guard let self else { return }
            Task { await self.capture() }
        }
    }

    private func capture() async {
        let service = resolveService()
        switch mode {
        case .region: await service.capture()
        case .fullScreen: await service.captureFullScreen()
        case .window: await service.captureWindow()
        }
    }

    private func resolveService() -> ScreenshotService {
        if let service { return service }
        let created = ScreenshotService(messaging: messaging)
        created.onMarkupRequest = { image, done in
            MarkupWindow.present(image: image, onComplete: done)
        }
        service = created
        return created
    }
}

/// Region capture → Vision OCR → clipboard. ⌃⇧T.
@MainActor
final class OCRTool: Tool {
    let id = "ocr"
    let title = "Grab Text"
    let icon = "text.viewfinder"
    let category = ToolCategory.capture
    let summary = "Copy text out of any region on screen."
    let hotkey: HotKeyChord? = HotKeyChord(
        keyCode: kVK_ANSI_T, modifiers: controlKey | shiftKey, label: "⌃⇧T")

    private var service: OCRService?

    var entry: ToolEntry {
        .action { [weak self] in
            guard let self else { return }
            let service = self.service ?? OCRService()
            self.service = service
            Task { await service.grab() }
        }
    }
}

/// Clipboard history. The collector must poll from launch; the tile shows a
/// popover, the hotkey (⌃⇧C) opens the floating picker near the mouse.
@MainActor
final class ClipboardTool: Tool {
    let id = "clipboard"
    let title = "Clipboard"
    let icon = "doc.on.clipboard"
    let category = ToolCategory.utilities
    let summary = "Search everything you have copied. Pin what you want to keep."
    let hotkey: HotKeyChord? = HotKeyChord(
        keyCode: kVK_ANSI_C, modifiers: controlKey | shiftKey, label: "⌃⇧C")

    let service = ClipboardHistoryService()
    private let window = ClipboardWindowController()

    func start() {
        service.start()
    }

    func stop() {
        service.stop()
        window.hide()
    }

    var entry: ToolEntry {
        .popover { [service] in AnyView(ClipboardHistoryView(clipboard: service)) }
    }

    func hotkeyFired() {
        window.toggle(clipboard: service)
    }
}

/// Disk usage explorer. Opens in a real, reusable window (not an auto-closing
/// popover) so an in-progress analysis survives focus changes. The view owns
/// its service and scans on first open — the lazy pattern the other tools
/// generalize.
@MainActor
final class DiskTool: Tool {
    let id = "disk"
    let title = "Disk"
    let icon = "chart.pie"
    let category = ToolCategory.system
    let summary = "See what is filling the disk. Anything you delete goes to the Trash."
    let hotkey: HotKeyChord? = nil

    private let window = DiskWindowController()

    var entry: ToolEntry {
        .action { [window] in window.show() }
    }

    /// Live-disable: closing the window cancels the home-folder walk, which the
    /// window owns — unregistering the tool alone left it crawling.
    func stop() {
        window.close()
    }
}

/// Toggles the companion panel. It has no tile of its own — you don't open the
/// panel from inside it — but it registers a rebindable global hotkey (⌃⇧P)
/// through the same registry machinery as every tool, so conflict detection and
/// the recorder row work unchanged. Firing posts `.pearTogglePanel`, which the
/// PanelController turns into open/close; the indirection avoids a launch-order
/// dependency between the environment (which offers this tool) and the
/// controller (created afterward by the AppDelegate).
@MainActor
final class PanelTool: Tool {
    let id = "panel"
    let title = "Companion Panel"
    let icon = "macwindow"
    let category = ToolCategory.system
    let summary = "Open or close the Pear panel from anywhere."
    let hotkey: HotKeyChord? = HotKeyChord(
        keyCode: kVK_ANSI_P, modifiers: controlKey | shiftKey, label: "⌃⇧P")
    var showsTile: Bool { false }

    var entry: ToolEntry {
        .action { NotificationCenter.default.post(name: .pearTogglePanel, object: nil) }
    }
}
