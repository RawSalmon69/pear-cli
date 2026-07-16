import Carbon.HIToolbox
import SwiftUI

/// Window snapping. Tile opens a zone grid (or the Accessibility onboarding
/// card); the real work is a set of global zone hotkeys registered at launch.
///
/// The tool has no single `hotkey` on the protocol — it owns a *set* of chords,
/// so it registers them itself in `start()` and keeps the tokens alive for the
/// process lifetime. Registration is cheap (Carbon `RegisterEventHotKey`); the
/// AX engine stays lazy — `WindowEngine` is stateless and touches AX only when
/// a chord fires or a grid button is tapped.
@MainActor
final class WindowsTool: Tool {
    let id = "windows"
    let title = "Windows"
    let icon = "rectangle.split.2x1"
    let hotkey: HotKeyChord? = nil

    /// ⌃⌥ chords → zone. Two-thirds zones are grid-only (no chord), matching
    /// the requested key map.
    private static let chords: [(keyCode: Int, zone: WindowZone)] = [
        (kVK_LeftArrow, .leftHalf),
        (kVK_RightArrow, .rightHalf),
        (kVK_UpArrow, .maximize),
        (kVK_DownArrow, .center),
        (kVK_ANSI_U, .topLeftQuarter),
        (kVK_ANSI_I, .topRightQuarter),
        (kVK_ANSI_J, .bottomLeftQuarter),
        (kVK_ANSI_K, .bottomRightQuarter),
        (kVK_ANSI_D, .leftThird),
        (kVK_ANSI_F, .centerThird),
        (kVK_ANSI_G, .rightThird),
    ]

    private var tokens: [HotKeyManager.Token] = []
    /// Loop-style hold-trigger ring. Lives for the process lifetime: it owns
    /// the always-on flagsChanged monitor plus the ring/preview panels, and
    /// installs its mouse/key monitors only while the trigger is held.
    private var radialTrigger: RadialTrigger?

    var entry: ToolEntry {
        .popover { AnyView(WindowsView()) }
    }

    func start() {
        // ponytail: drag-to-edge snapping and the trackpad title-bar swipe
        // (both out of scope for v1) would install a global mouse monitor /
        // event tap here and drive WindowEngine from cursor position.
        let modifiers = controlKey | optionKey
        for chord in Self.chords {
            let zone = chord.zone
            let token = HotKeyManager.shared.register(keyCode: chord.keyCode, modifiers: modifiers) {
                WindowEngine.apply(zone)
            }
            tokens.append(token)
        }

        let trigger = RadialTrigger()
        trigger.start()
        radialTrigger = trigger
    }
}
