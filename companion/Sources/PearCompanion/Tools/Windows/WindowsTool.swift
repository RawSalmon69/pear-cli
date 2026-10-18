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
    /// The registry finds the Windows chords' owner by this id.
    static let toolID = "windows"
    let id = WindowsTool.toolID
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
    /// registers them itself in `start()`. The registry reads them from
    /// `WindowSettings` for its conflict check, and restarts this tool when one
    /// changes so the new chord is live.
    var hotkey: HotKeyChord? { nil }

    // Built on first use. Tool inits run at launch for every registered tool, so
    // none of this — an event tap, a panel, an AX client — may exist until the
    // tool is actually activated.
    private var mover: (any WindowMover)?
    private var ring: RingOverlayWindow?
    private var trigger: WindowTrigger?

    /// Without Accessibility every move is a silent no-op, so a snap says why
    /// instead. Both injected: the real ones read TCC and raise its prompt.
    private let accessibilityTrusted: @MainActor () -> Bool
    private let refuseUntrusted: @MainActor () -> Void

    /// A test hands in a recording mover so the ring and the chords can be
    /// driven with no Accessibility client and no real window — the real one is
    /// still built in `start()`, and the init stays as cheap as the `Tool`
    /// contract requires.
    init(mover: (any WindowMover)? = nil,
         accessibilityTrusted: @escaping @MainActor () -> Bool = { Permissions.accessibilityTrusted },
         refuseUntrusted: @escaping @MainActor () -> Void = WindowsTool.showNeedsAccessibility) {
        self.mover = mover
        self.accessibilityTrusted = accessibilityTrusted
        self.refuseUntrusted = refuseUntrusted
    }

    /// The action the ring is currently pointing at, so `ringClosed(commit:)`
    /// knows what to apply without asking the ring again.
    private var pending: WindowAction?

    var acceptsHotkey: Bool { false }

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
        apply(action)
    }

    func snapRequested(_ action: WindowAction) {
        apply(action)
    }

    private func apply(_ action: WindowAction) {
        guard accessibilityTrusted() else {
            ToolRegistry.live?.reportError("Windows needs Accessibility", for: id)
            refuseUntrusted()
            return
        }
        mover?.commit(action, on: nil)
    }

    /// The HUD at the pointer, then the system prompt: the user just asked for
    /// a move, which is the moment to ask.
    static func showNeedsAccessibility() {
        CopyToast.show(message: "Windows needs Accessibility")
        Permissions.requestAccessibility()
    }
}

/// The tile's popover: the chord list, and the Accessibility grant when it is
/// missing. Moving another app's windows and watching for Fn both need that
/// permission, and the prompt lives here rather than at launch so the app never
/// asks for it before the user has touched the feature.
private struct WindowsPopover: View {
    @State private var trusted = Permissions.accessibilityTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            PopoverHeader(title: "Windows")
            SectionLabel(text: "Snap the front window")
            ForEach(WindowSettings.chords()) { binding in
                HStack(spacing: Theme.Space.small) {
                    Text(RingLabel.text(for: binding.action))
                        .font(Theme.Typography.body())
                    Spacer(minLength: Theme.Space.large)
                    Text(binding.chord.label)
                        .font(Theme.Typography.small(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("Hold Fn for the ring, then flick at a zone.")
                .font(Theme.Typography.small(.semibold))
                .foregroundStyle(.secondary)

            if !trusted {
                Divider()
                Text("Needs Accessibility to move windows.")
                    .font(Theme.Typography.small(.semibold))
                    .foregroundStyle(Theme.warn)
                Button("Grant Accessibility") { Permissions.requestAccessibility() }
                .controlSize(.small)
            }
        }
        .padding(Theme.edgePadding)
        .frame(width: 260)
        .onAppear { trusted = Permissions.accessibilityTrusted }
    }
}
