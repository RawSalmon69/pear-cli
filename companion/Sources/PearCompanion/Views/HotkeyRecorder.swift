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
        case kVK_Delete: "⌫"
        case kVK_ForwardDelete: "⌦"
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

    func toggle(registry: ToolRegistry, owner: ShortcutOwner) {
        isRecording ? cancel() : start(registry: registry, owner: owner)
    }

    private func start(registry: ToolRegistry, owner: ShortcutOwner) {
        message = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Fail OPEN if the model died without teardown (SwiftUI can skip
            // onDisappear on abrupt popover teardown): a leaked monitor that
            // kept returning nil would eat every keyDown in the app forever.
            guard let self else { return event }
            self.handle(event, registry: registry, owner: owner)
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

    private func handle(_ event: NSEvent, registry: ToolRegistry, owner: ShortcutOwner) {
        let keyCode = Int(event.keyCode)
        // Esc cancels the recording outright.
        if keyCode == kVK_Escape {
            cancel()
            return
        }
        let carbon = HotkeyRecording.carbonModifiers(from: event.modifierFlags)
        // A bare Delete/⌫ removes the binding entirely — no chord fires, not even
        // the default. The row's reset arrow brings the default back. With a
        // modifier it is an ordinary chord (Windows' Restore is ⌃⌥⌫).
        if keyCode == kVK_Delete || keyCode == kVK_ForwardDelete, carbon == 0 {
            registry.removeShortcut(owner)
            teardown()
            return
        }
        // A global chord needs at least one of ⌃⌥⇧⌘, or a bare letter would
        // fire constantly; keep recording so the user can try again.
        guard carbon != 0 else {
            message = "Hold ⌃ ⌥ ⇧ or ⌘ with a key"
            return
        }
        let label = HotkeyRecording.label(
            keyCode: keyCode, carbonModifiers: carbon,
            characters: event.charactersIgnoringModifiers)
        let chord = HotKeyChord(keyCode: keyCode, modifiers: carbon, label: label)
        if let conflict = registry.conflictingTool(for: chord, excluding: owner) {
            message = "Used by \(conflict)"
            return
        }
        registry.setShortcut(chord, for: owner)
        teardown()
    }
}

/// The recorder's view of the registry: one verb set for both kinds of owner,
/// so the row and the model never branch on which one they are editing.
extension ToolRegistry {
    func shortcutLabel(for owner: ShortcutOwner) -> String? {
        switch owner {
        case .tool(let id): hotkeyLabel(for: id)
        case .windows(let id): windowsChord(for: id)?.label
        }
    }

    /// Records a chord, or resets to the default with nil.
    func setShortcut(_ chord: HotKeyChord?, for owner: ShortcutOwner) {
        switch owner {
        case .tool(let id): setHotkeyOverride(id, chord)
        case .windows(let id): setWindowsChord(chord, for: id)
        }
    }

    func removeShortcut(_ owner: ShortcutOwner) {
        switch owner {
        case .tool(let id): removeHotkey(id)
        case .windows(let id): removeWindowsChord(id)
        }
    }

    /// A reset arrow only makes sense when the binding is changed and there is a
    /// default to go back to. Every Windows binding has one.
    func canResetShortcut(_ owner: ShortcutOwner) -> Bool {
        switch owner {
        case .tool(let id): hasHotkeyOverride(id) && hasDefaultHotkey(id)
        case .windows(let id): isWindowsChordCustomized(id)
        }
    }
}

/// One Shortcuts-page control: shows the effective chord (or "Record
/// Shortcut…"), records a new one live, removes it, and — when it differs from
/// a default — resets it. All changes apply immediately via the registry.
/// `name` is what VoiceOver reads ("Screenshot", "Left Half").
struct HotkeyRecorderRow: View {
    @Environment(AppEnvironment.self) private var env
    let owner: ShortcutOwner
    let name: String
    @State private var model = HotkeyRecorderModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xSmall) {
            HStack(spacing: Theme.Space.small) {
                Button {
                    model.toggle(registry: env.tools, owner: owner)
                } label: {
                    Text(buttonLabel)
                        .font(Theme.Typography.small(.semibold))
                        .frame(minWidth: 96, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.accent)
                .focusable(false)
                .accessibilityLabel("Shortcut for \(name)")
                .accessibilityValue(model.isRecording ? "Recording" : (label ?? "None"))
                .accessibilityHint("Press to record a new shortcut")

                if label != nil {
                    Button {
                        env.tools.removeShortcut(owner)
                    } label: {
                        Image(systemName: "xmark.circle").font(Theme.Typography.tiny())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove shortcut")
                    .accessibilityLabel("Remove shortcut for \(name)")
                }
                if env.tools.canResetShortcut(owner) {
                    Button {
                        env.tools.setShortcut(nil, for: owner)
                    } label: {
                        Image(systemName: "arrow.uturn.backward").font(Theme.Typography.tiny())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reset to default shortcut")
                    .accessibilityLabel("Reset shortcut for \(name) to default")
                }
                Spacer(minLength: 0)
            }
            if let message = model.message {
                Text(message)
                    .font(Theme.Typography.small(.semibold))
                    .foregroundStyle(Theme.warn)
            }
        }
        .onDisappear { model.teardown() }
    }

    private var label: String? { env.tools.shortcutLabel(for: owner) }

    private var buttonLabel: String {
        if model.isRecording { return "Press keys…" }
        return label ?? "Record Shortcut…"
    }
}
