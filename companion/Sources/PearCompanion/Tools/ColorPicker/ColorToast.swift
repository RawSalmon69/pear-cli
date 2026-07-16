import AppKit
import SwiftUI

/// A small non-activating floating panel that confirms a color copy: the
/// picked swatch plus the copied value, shown at the cursor and auto-fading
/// after ~1.5 s. Both the tile "Pick color" button and the global hotkey copy
/// through here, so the feedback is identical whether or not a popover was
/// open — the eyedropper closes the popover the instant it opens, so an
/// in-popover confirmation would never be seen.
@MainActor
enum ColorToast {
    private static var panel: NSPanel?
    private static var dismissTask: Task<Void, Never>?

    static func show(color: PickedColor, text: String) {
        hide() // one toast at a time

        let host = NSHostingView(rootView: ColorToastView(color: color.swiftUIColor, text: text))
        host.layout()
        let size = host.fittingSize
        host.clipToCard(radius: 12)

        let panel = NSPanel(
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
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.setFrameOrigin(Self.origin(for: size))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let panel = self.panel else { return }
            // The async form resolves inside this actor-isolated task and
            // returns once the fade finishes — no manual sleep to match it.
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    /// Just up-and-right of the cursor, clamped to the cursor's screen so the
    /// toast never lands off-screen when picking near an edge.
    private static func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var x = mouse.x + 14
        var y = mouse.y + 14
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
            y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        return NSPoint(x: x, y: y)
    }

    private static func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ColorToastView: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5)
                .fill(color)
                .frame(width: 22, height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.black.opacity(0.12), lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Copied").font(Theme.caption).foregroundStyle(.secondary)
                Text(text).font(Theme.body).monospaced()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 12)
    }
}
