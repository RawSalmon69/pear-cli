import AppKit
import SwiftUI

/// Window snapping: ⌃⌥ plus an arrow moves the front window, and holding Fn
/// opens a radial ring under the pointer to pick a zone by flicking at it.
///
/// This type is only the wiring. The four pieces it joins are deliberately
/// separate and independently testable: `WindowTrigger` reads input,
/// `RingOverlayWindow` draws and hit-tests the ring, `WindowZoneMath` turns an
/// action into a frame, and `AXWindowMover` applies it. Nothing here does
/// geometry, drawing, or event handling of its own.
@MainActor
final class WindowsTool: Tool, WindowTriggerDelegate {
    let id = "windows"
    let title = "Windows"
    let icon = "macwindow.on.rectangle"
    var category: ToolCategory { .system }
    var summary: String { "Snap the front window with ⌃⌥ and the arrows, or hold Fn for the ring." }

    /// Off on a fresh install, and off for everyone who auto-updates into this
    /// release. Enabling arms an event tap, claims seven global chords, and
    /// starts writing other apps' window frames over Accessibility — squarely
    /// what the "anything that mutates system state on launch is opt-in"
    /// invariant exists for. Flip this to the default once the interaction has
    /// been driven on real hardware; it is a one-line change.
    var defaultEnabled: Bool { false }

    /// Nil on purpose: this tool owns a *set* of chords plus the Fn hold, and
    /// registers them itself in `start()`. `extraChords` is what exposes them to
    /// the registry's conflict check.
    var hotkey: HotKeyChord? { nil }
    var extraChords: [HotKeyChord] { WindowSettings.chords().map(\.chord) }

    // Built on first use. Tool inits run at launch for every registered tool, so
    // none of this — an event tap, a panel, an AX client — may exist until the
    // tool is actually activated.
    private var mover: (any WindowMover)?
    private var ring: RingOverlayWindow?
    private var trigger: WindowTrigger?

    /// A test hands in a recording mover so the ring and the chords can be
    /// driven with no Accessibility client and no real window — the real one is
    /// still built in `start()`, and the init stays as cheap as the `Tool`
    /// contract requires.
    init(mover: (any WindowMover)? = nil) { self.mover = mover }

    /// The action the ring is currently pointing at, so `ringClosed(commit:)`
    /// knows what to apply without asking the ring again.
    private var pending: WindowAction?

    var entry: ToolEntry {
        .popover { AnyView(WindowsPopover()) }
    }

    // MARK: - Lifecycle

    func start() {
        guard trigger == nil else { return }
        let ring = RingOverlayWindow()
        let trigger = WindowTrigger(slotAt: { [weak ring] point in ring?.slot(at: point) })
        trigger.delegate = self
        self.ring = ring
        self.mover = mover ?? AXWindowMover()
        self.trigger = trigger
        trigger.start()
    }

    /// A disabled tool must leave the machine exactly as it found it: no tap, no
    /// hotkeys, no overlay, no preview.
    func stop() {
        trigger?.stop()
        ring?.hide()
        mover?.preview(nil, on: nil)
        trigger = nil
        ring = nil
        mover = nil
        pending = nil
    }

    // MARK: - WindowTriggerDelegate

    func ringOpened() {
        // The ring belongs under the pointer, and `NSEvent.mouseLocation` is
        // already in the AppKit screen space both the ring and its hit test use.
        ring?.show(at: NSEvent.mouseLocation)
        pending = nil
    }

    func ringHighlight(_ slot: RingSlot?) {
        ring?.highlight(slot)
        pending = slot.flatMap { WindowSettings.action(for: $0) }
        // Nil window: the ring is opened by a key, not aimed at a title bar, so
        // the focused window is the only thing it can mean.
        mover?.preview(pending, on: nil)
    }

    func ringClosed(commit: Bool) {
        ring?.hide()
        let action = pending
        pending = nil
        // A release on the dead zone, or on a slot the user cleared, is a cancel.
        guard commit, let action else {
            mover?.preview(nil, on: nil)
            return
        }
        mover?.commit(action, on: nil)
    }

    func snapRequested(_ action: WindowAction) {
        mover?.commit(action, on: nil)
    }
}

/// The tile's popover: the chord list, and the Accessibility grant when it is
/// missing. Moving another app's windows and watching for Fn both need that
/// permission, and the prompt lives here rather than at launch so the app never
/// asks for it before the user has touched the feature.
private struct WindowsPopover: View {
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "Snap the front window")
            ForEach(WindowSettings.chords()) { binding in
                HStack(spacing: Theme.itemGap) {
                    Text(RingLabel.text(for: binding.action))
                        .font(Theme.body)
                    Spacer(minLength: Theme.sectionGap)
                    Text(binding.chord.label)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("Hold Fn for the ring, then flick at a zone.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)

            if !trusted {
                Divider()
                Text("Needs Accessibility to move windows.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warn)
                Button("Grant Accessibility") {
                    // String key: the constant is not exported to Swift. Same
                    // call KeyCluTool makes for the same reason.
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
