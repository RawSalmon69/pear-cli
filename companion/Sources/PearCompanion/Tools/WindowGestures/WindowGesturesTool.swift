import ApplicationServices
import SwiftUI

/// Trackpad gestures on a window's title bar: swipe to snap it, pinch to
/// maximise or restore it, squeeze it shut.
///
/// A tool of its own rather than a corner of the Windows tool, because it is a
/// different bargain with the machine. The ⌃⌥ chords are Carbon hotkeys that
/// touch nothing else; this arms an event tap that sees every scroll event on
/// the Mac. It used to hide behind a second preference *inside* Windows, so
/// reaching it meant finding two switches — the registry's own on/off is now the
/// only one.
///
/// Like `WindowsTool`, this type is only the wiring, and it shares that tool's
/// pieces without depending on it: `WindowGestureTap` decodes the input and owns
/// the swallow rule, `WindowGestureRecognizer` decides what a motion means,
/// `WindowUnderPointer` says which title bar it started on, and `AXWindowMover`
/// applies the result to that window. Nothing here does geometry, drawing, or
/// event handling of its own.
@MainActor
final class WindowGesturesTool: Tool {
    let id = "windowgestures"
    let title = "Window Gestures"
    let icon = "hand.draw"
    var category: ToolCategory { .system }
    var summary: String { "Swipe or pinch a window's title bar to snap, maximise or close it." }

    /// Off on a fresh install, and off for everyone who auto-updates into this
    /// release. Enabling arms an event tap that sees every scroll event on the
    /// machine and writes other apps' window frames over Accessibility, and it
    /// has never been driven on real hardware. Flip this once it has; it is a
    /// one-line change.
    var defaultEnabled: Bool { false }

    /// Nothing to fire: the gestures are either being watched for or they are
    /// not, which is exactly what the registry's on/off already is.
    var hotkey: HotKeyChord? { nil }

    // Built on first use. Tool inits run at launch for every registered tool, so
    // neither the event tap nor the AX client may exist until the tool is
    // actually activated. Its own mover, not the Windows tool's: the two tools
    // know nothing about each other, and a mover is cheap.
    private var mover: AXWindowMover?
    private var tap: WindowGestureTap?

    var entry: ToolEntry {
        .popover { AnyView(WindowGesturesPopover()) }
    }

    // MARK: - Lifecycle

    func start() {
        guard tap == nil else { return }
        let mover = AXWindowMover()
        let tap = WindowGestureTap(mover: mover)
        self.mover = mover
        self.tap = tap
        tap.start()
    }

    /// A disabled tool must leave the machine exactly as it found it: no tap, no
    /// monitor, no preview overlay. `stop()` on the tap cancels a gesture caught
    /// mid-swipe, and the explicit hide covers the panel the mover is holding —
    /// releasing the mover with its overlay still on screen would leave a
    /// floating window behind.
    func stop() {
        tap?.stop()
        mover?.preview(nil, on: nil)
        tap = nil
        mover = nil
    }
}

/// The tile's popover: what the gestures are, and the Accessibility grant when
/// it is missing. Moving another app's windows needs that permission, and the
/// prompt lives here rather than at launch so the app never asks for it before
/// the user has touched the feature — the same shape `WindowsTool`, `KeyCluTool`
/// and the Highlight Copy popover use.
private struct WindowGesturesPopover: View {
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.itemGap) {
            SectionLabel(text: "On a window's title bar")
            Text("Two-finger swipe to snap it to that side or corner, swipe up for full screen, down to minimise. Pinch out to maximise, pinch in to restore.")
                .font(Theme.body)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pinch in firmly to close the window; pinch in all the way to quit the app.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !trusted {
                Divider()
                Text("Needs Accessibility to move windows.")
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
