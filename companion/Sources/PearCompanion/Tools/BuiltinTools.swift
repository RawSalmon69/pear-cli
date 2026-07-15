import SwiftUI
import Carbon.HIToolbox

// The four launch tools. Each holds its heavy service lazily; only the
// clipboard collector runs from launch (its history is worthless otherwise).

/// Region screenshot → clipboard + preview + markup + send. ⌃⇧P.
@MainActor
final class ScreenshotTool: Tool {
    let id = "screenshot"
    let title = "Screenshot"
    let icon = "camera.viewfinder"
    let hotkey: HotKeyChord? = HotKeyChord(
        keyCode: kVK_ANSI_P, modifiers: controlKey | shiftKey, label: "⌃⇧P")

    private let messaging: MessagingService
    private var service: ScreenshotService?

    init(messaging: MessagingService) {
        self.messaging = messaging
    }

    var entry: ToolEntry {
        .action { [weak self] in
            guard let self else { return }
            Task { await self.resolveService().capture() }
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

/// Region capture → Vision OCR → clipboard. ⌃⇧O.
@MainActor
final class OCRTool: Tool {
    let id = "ocr"
    let title = "Grab Text"
    let icon = "text.viewfinder"
    let hotkey: HotKeyChord? = HotKeyChord(
        keyCode: kVK_ANSI_O, modifiers: controlKey | shiftKey, label: "⌃⇧O")

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
    let hotkey: HotKeyChord? = HotKeyChord(
        keyCode: kVK_ANSI_C, modifiers: controlKey | shiftKey, label: "⌃⇧C")

    let service = ClipboardHistoryService()
    private let window = ClipboardWindowController()

    func start() {
        service.start()
    }

    var entry: ToolEntry {
        .popover { [service] in AnyView(ClipboardHistoryView(clipboard: service)) }
    }

    func hotkeyFired() {
        window.toggle(clipboard: service)
    }
}

/// Disk usage explorer. The view owns its service and scans on first open —
/// the lazy pattern the other tools generalize.
@MainActor
final class DiskTool: Tool {
    let id = "disk"
    let title = "Disk"
    let icon = "chart.pie"
    let hotkey: HotKeyChord? = nil

    var entry: ToolEntry {
        .popover { AnyView(DiskAnalyzeView()) }
    }
}
