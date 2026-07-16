import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Window snapping. Tile opens a zone grid (or the Accessibility onboarding
/// card); the real work is a set of global zone hotkeys registered at launch.
///
/// The tool has no single `hotkey` on the protocol — it owns a *set* of chords,
/// so it registers them itself in `start()` and keeps the tokens alive while
/// enabled. Registration is cheap (Carbon `RegisterEventHotKey`); the AX engine
/// stays lazy — `WindowEngine` is stateless and touches AX only when a chord
/// fires or a grid button is tapped. A user-assigned custom chord (registered
/// by the registry, not here) toggles the zone grid via `hotkeyFired()`.
@MainActor
final class WindowsTool: Tool {
    let id = "windows"
    let title = "Windows"
    let icon = "rectangle.split.2x1"
    let category = ToolCategory.system
    let summary = "Snap windows to halves, quarters, and thirds."
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

    /// Modifier shared by every zone chord.
    static let zoneModifiers = controlKey | optionKey

    /// Whether a chord collides with a zone shortcut — used by the registry's
    /// conflict check, since these chords never appear as the protocol's single
    /// `hotkey`.
    static func isZoneChord(keyCode: Int, modifiers: Int) -> Bool {
        modifiers == zoneModifiers && chords.contains { $0.keyCode == keyCode }
    }

    private var tokens: [HotKeyManager.Token] = []
    /// Loop-style hold-trigger ring. Lives while the tool is enabled: it owns
    /// the always-on flagsChanged monitor plus the ring/preview panels, and
    /// installs its mouse/key monitors only while the trigger is held.
    private var radialTrigger: RadialTrigger?
    /// Floating zone grid summoned by a custom chord (Windows has no default
    /// single hotkey; a user who binds one gets the grid at the cursor).
    private let window = WindowsWindowController()

    var entry: ToolEntry {
        .popover { AnyView(WindowsView()) }
    }

    func start() {
        // ponytail: drag-to-edge snapping and the trackpad title-bar swipe
        // (both out of scope for v1) would install a global mouse monitor /
        // event tap here and drive WindowEngine from cursor position.
        for chord in Self.chords {
            let zone = chord.zone
            let token = HotKeyManager.shared.register(keyCode: chord.keyCode, modifiers: Self.zoneModifiers) {
                WindowEngine.apply(zone)
            }
            tokens.append(token)
        }

        let trigger = RadialTrigger()
        trigger.start()
        radialTrigger = trigger
    }

    func stop() {
        for token in tokens { HotKeyManager.shared.unregister(token) }
        tokens.removeAll()
        radialTrigger?.stop()
        radialTrigger = nil
        window.hide()
    }

    func hotkeyFired() {
        window.toggle()
    }
}

/// Floating zone grid opened by a custom hotkey. Mirrors
/// `ScratchpadWindowController`: borderless, joins every Space, and does NOT
/// auto-hide on focus loss — WindowsView's trigger-key menu picker would close
/// the panel on the resignKey a menu popup causes. Positioned near the mouse
/// (clamped on-screen); a second hotkey press or Esc closes it.
@MainActor
final class WindowsWindowController {
    private var panel: NSPanel?

    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func show() {
        let view = WindowsView().glassCard(cornerRadius: 16)
        let host = FirstMouseHostingView(rootView: view)
        host.clipToCard()
        let size = host.fittingSize

        let panel = WindowsPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.onCancel = { [weak self] in self?.hide() }
        panel.contentView = host

        // Near the mouse, clamped on-screen.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 8)
            let vis = screen.visibleFrame
            origin.x = min(max(vis.minX + 8, origin.x), vis.maxX - size.width - 8)
            origin.y = min(max(vis.minY + 8, origin.y), vis.maxY - size.height - 8)
            panel.setFrameOrigin(origin)
        }

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    /// First click lands on a zone button instead of only focusing the panel.
    private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// Borderless panel that takes key focus (so the grid's controls work) and
/// closes on Esc. No resignKey auto-hide, so the trigger-key menu picker
/// doesn't dismiss the panel when it opens.
private final class WindowsPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    // One dismissal grammar across every floating surface: Esc closes.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
