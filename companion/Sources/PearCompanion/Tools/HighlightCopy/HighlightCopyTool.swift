import AppKit
import ApplicationServices
import SwiftUI

/// Installing and removing the read-only global mouse monitors, behind a seam so
/// tests can exercise the bookkeeping without putting a real monitor on a live
/// session.
///
/// `NSEvent`'s global monitor and nothing else. A `CGEventTap` would see the
/// same clicks, but a tap can also swallow or rewrite them; a global monitor is
/// structurally incapable of it, so no bug in this tool can break clicking or
/// text selection. That property is worth more than anything a tap would buy.
@MainActor
struct GlobalMouseMonitor {
    var add: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any?
    var remove: (Any) -> Void

    static let system = GlobalMouseMonitor(
        add: { NSEvent.addGlobalMonitorForEvents(matching: $0, handler: $1) },
        remove: { NSEvent.removeMonitor($0) })
}

/// Highlight to copy: selecting text with the mouse puts it on the clipboard,
/// the way X11's primary selection works.
///
/// The tool is only wiring — two mouse monitors forwarding into
/// `HighlightCopyEngine`, which owns every decision. Off by default: enabling it
/// rewrites the clipboard whenever you drag across text, squarely the
/// "mutates system state on launch is opt-in" invariant.
@MainActor
final class HighlightCopyTool: Tool {
    let id = "highlightcopy"
    let title = "Highlight Copy"
    let icon = "highlighter"
    let category = ToolCategory.utilities
    let summary = "Selecting text with the mouse puts it on the clipboard."
    let defaultEnabled = false
    /// No chord: there is nothing to fire. The tool is either watching or not,
    /// which is what the registry's on/off already is.
    let hotkey: HotKeyChord? = nil

    private let engine: HighlightCopyEngine
    private let monitor: GlobalMouseMonitor
    private var tokens: [Any] = []

    init(engine: HighlightCopyEngine = HighlightCopyEngine(), monitor: GlobalMouseMonitor = .system) {
        self.engine = engine
        self.monitor = monitor
    }

    var entry: ToolEntry {
        .popover { AnyView(HighlightCopyPopover()) }
    }

    /// Whether the monitors are installed. `stop()` must bring this back to
    /// false: a disabled tool leaves the machine exactly as it found it.
    var isWatching: Bool { !tokens.isEmpty }

    func start() {
        guard tokens.isEmpty else { return }
        // `NSEvent.mouseLocation` rather than the event's own location: a global
        // monitor's event carries no window to be relative to, and the two agree
        // to well inside the drag threshold anyway.
        let down = monitor.add(.leftMouseDown) { [engine] _ in
            MainActor.assumeIsolated { engine.mouseDown(at: NSEvent.mouseLocation) }
        }
        let up = monitor.add(.leftMouseUp) { [engine] event in
            MainActor.assumeIsolated {
                engine.mouseUp(at: NSEvent.mouseLocation, clickCount: event.clickCount)
            }
        }
        tokens = [down, up].compactMap { $0 }
    }

    func stop() {
        tokens.forEach(monitor.remove)
        tokens = []
    }
}

/// The tile's popover: what the tool does, what it refuses to copy, and the
/// Accessibility grant when it is missing. The prompt lives here rather than at
/// launch so the app never asks before the user has touched the feature — the
/// same shape `KeyCluTool` and the Windows popover use.
private struct HighlightCopyPopover: View {
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Highlight to copy")
            Text("Select text with the mouse and it lands on the clipboard, ready for ⌘V — no ⌘C.")
                .font(Theme.body)
                .fixedSize(horizontal: false, vertical: true)
            Text("Password fields are never copied, and auto-copies are marked as generated so they stay out of your clipboard history.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Named because the silence is otherwise unreadable: a Firefox-based
            // browser with its accessibility tree off looks exactly like a
            // broken feature, and that is where the first real report came from.
            Text("Apps that don't expose their selection to Accessibility are skipped — Firefox-based browsers ship that tree off (about:config → accessibility.force_disabled → 0).")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !trusted {
                Divider()
                Text("Needs Accessibility to read the selection.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warn)
                Button("Grant Accessibility") {
                    // String key: the constant is not exported to Swift. Same
                    // call KeyCluTool and the Windows popover make.
                    _ = AXIsProcessTrustedWithOptions(
                        ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                }
                .controlSize(.small)
            }
        }
        .padding(Theme.cardPadding)
        .frame(width: 260)
        .onAppear { trusted = AXIsProcessTrusted() }
    }
}
