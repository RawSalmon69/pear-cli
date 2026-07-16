import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// Pure translation between AppKit key events and the Carbon values / display
/// labels a `HotKeyChord` stores. Split out from the view so the formatting is
/// unit-testable without a live event.
enum HotkeyRecording {
    /// NSEvent modifier flags → the Carbon OR-mask `HotKeyManager` registers.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var carbon = 0
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        if flags.contains(.command) { carbon |= cmdKey }
        return carbon
    }

    /// Standard-order modifier symbols: ⌃⌥⇧⌘.
    static func modifierSymbols(_ carbon: Int) -> String {
        var symbols = ""
        if carbon & controlKey != 0 { symbols += "⌃" }
        if carbon & optionKey != 0 { symbols += "⌥" }
        if carbon & shiftKey != 0 { symbols += "⇧" }
        if carbon & cmdKey != 0 { symbols += "⌘" }
        return symbols
    }

    /// Key glyph: a small special-case map for keys with no printable
    /// character, otherwise the uppercased character the event carried.
    static func keyName(keyCode: Int, characters: String?) -> String {
        switch keyCode {
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Escape: "esc"
        default: characters?.uppercased() ?? "?"
        }
    }

    static func label(keyCode: Int, carbonModifiers: Int, characters: String?) -> String {
        modifierSymbols(carbonModifiers) + keyName(keyCode: keyCode, characters: characters)
    }
}

/// Recording state for one row. A reference type (held by the view as `@State`)
/// so the escaping keyDown monitor mutates the *same* instance instead of a
/// captured struct copy — and so the monitor can be torn down deterministically.
@MainActor
@Observable
final class HotkeyRecorderModel {
    private(set) var isRecording = false
    /// Inline note: a rejected chord (no modifier) or a conflict.
    private(set) var message: String?
    @ObservationIgnored private var monitor: Any?

    func toggle(registry: ToolRegistry, id: String) {
        isRecording ? cancel() : start(registry: registry, id: id)
    }

    private func start(registry: ToolRegistry, id: String) {
        message = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event, registry: registry, id: id)
            return nil // swallow: the key must not type into whatever is focused
        }
    }

    func cancel() {
        teardown()
        message = nil
    }

    /// Remove the monitor and leave recording — called on cancel, on success,
    /// and from the view's `onDisappear` so a monitor never outlives the row.
    func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent, registry: ToolRegistry, id: String) {
        let keyCode = Int(event.keyCode)
        // Esc cancels the recording outright.
        if keyCode == kVK_Escape {
            cancel()
            return
        }
        // Delete/⌫ clears the override — reverting to the default, or (for a
        // tool with no default) removing the binding entirely.
        if keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
            registry.setHotkeyOverride(id, nil)
            teardown()
            return
        }
        // A global chord needs at least one of ⌃⌥⇧⌘, or a bare letter would
        // fire constantly; keep recording so the user can try again.
        let carbon = HotkeyRecording.carbonModifiers(from: event.modifierFlags)
        guard carbon != 0 else {
            message = "Hold ⌃ ⌥ ⇧ or ⌘ with a key"
            return
        }
        let label = HotkeyRecording.label(
            keyCode: keyCode, carbonModifiers: carbon,
            characters: event.charactersIgnoringModifiers)
        let chord = HotKeyChord(keyCode: keyCode, modifiers: carbon, label: label)
        if let conflict = registry.conflictingTool(for: chord, excluding: id) {
            message = "Used by \(conflict)"
            return
        }
        registry.setHotkeyOverride(id, chord)
        teardown()
    }
}

/// The shortcut control under a tool's toggle: shows the effective chord (or
/// "Record Shortcut…"), records a new one live, and — for a tool with a
/// default — offers a reset. All changes apply immediately via the registry.
struct HotkeyRecorderRow: View {
    @Environment(AppEnvironment.self) private var env
    let id: String
    @State private var model = HotkeyRecorderModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    model.toggle(registry: env.tools, id: id)
                } label: {
                    Text(buttonLabel)
                        .font(Theme.caption)
                        .frame(minWidth: 96, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.accent)

                if env.tools.hasHotkeyOverride(id), env.tools.hasDefaultHotkey(id) {
                    Button {
                        env.tools.setHotkeyOverride(id, nil)
                    } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reset to default shortcut")
                }
                Spacer(minLength: 0)
            }
            if let message = model.message {
                Text(message)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warn)
            }
        }
        .onDisappear { model.teardown() }
    }

    private var buttonLabel: String {
        if model.isRecording { return "Press keys…" }
        return env.tools.hotkeyLabel(for: id) ?? "Record Shortcut…"
    }
}
