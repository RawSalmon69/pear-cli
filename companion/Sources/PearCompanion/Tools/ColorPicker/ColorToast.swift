import AppKit

/// A small non-activating floating panel that confirms a color copy: the
/// picked swatch plus the copied value, shown at the cursor and auto-fading
/// after ~1.5 s. Both the tile "Pick color" button and the global hotkey copy
/// through here, so the feedback is identical whether or not a popover was
/// open — the eyedropper closes the popover the instant it opens, so an
/// in-popover confirmation would never be seen.
///
/// Built in plain AppKit, NOT SwiftUI. An `NSHostingView` as a small panel's
/// content view enters a constraint-update runaway on macOS 26 (its
/// `updateWindowContentSizeExtremaIfNecessary` re-evaluates the SwiftUI graph
/// mid-pass, which invalidates its own transform and re-marks the window until
/// AppKit's per-window update limit throws — the crash lldb pinned to this
/// exact 92×47 toast panel, 2.5.x). A plain `NSView` tree has no view graph and
/// no `updateConstraints` hosting behavior, so that loop cannot occur.
@MainActor
enum ColorToast {
    private static var panel: NSPanel?
    private static var dismissTask: Task<Void, Never>?

    static func show(color: PickedColor, text: String) {
        hide() // one toast at a time

        let content = makeToast(
            swatch: NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1),
            text: text)
        let size = content.frame.size

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
        panel.contentView = content
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

    /// The card: a frosted rounded background with a color swatch, a "Copied"
    /// caption, and the copied value. Laid out with explicit frames (no Auto
    /// Layout, no SwiftUI) so it cannot trigger the hosting-view constraint loop.
    private static func makeToast(swatch: NSColor, text: String) -> NSView {
        let hPad: CGFloat = 12, vPad: CGFloat = 8, gap: CGFloat = 8, chip: CGFloat = 22

        let copied = NSTextField(labelWithString: "Copied")
        copied.font = .systemFont(ofSize: 10)
        copied.textColor = .secondaryLabelColor
        copied.sizeToFit()

        let value = NSTextField(labelWithString: text)
        value.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        value.textColor = .labelColor
        value.sizeToFit()

        let textW = max(copied.frame.width, value.frame.width)
        let textH = copied.frame.height + 1 + value.frame.height
        let contentH = max(chip, textH)
        let width = (hPad + chip + gap + textW + hPad).rounded()
        let height = (vPad + contentH + vPad).rounded()

        let card = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.masksToBounds = true

        let chipView = NSView(frame: NSRect(x: hPad, y: (height - chip) / 2, width: chip, height: chip))
        chipView.wantsLayer = true
        chipView.layer?.backgroundColor = swatch.cgColor
        chipView.layer?.cornerRadius = 5
        chipView.layer?.borderWidth = 1
        chipView.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor

        // AppKit's origin is bottom-left: the value sits lower, "Copied" above it.
        let textX = hPad + chip + gap
        let blockBottom = (height - textH) / 2
        value.frame.origin = NSPoint(x: textX, y: blockBottom)
        copied.frame.origin = NSPoint(x: textX, y: blockBottom + value.frame.height + 1)

        card.addSubview(chipView)
        card.addSubview(value)
        card.addSubview(copied)
        return card
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
