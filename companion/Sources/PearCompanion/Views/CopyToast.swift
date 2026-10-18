import AppKit

/// A small non-activating floating panel that confirms a copy: the copied value
/// (plus a color swatch when there is one), shown at the cursor and auto-fading
/// after ~1.5 s. Both the tile "Pick color" button and the global hotkey copy
/// through here, so the feedback is identical whether or not a popover was
/// open — the eyedropper closes the popover the instant it opens, so an
/// in-popover confirmation would never be seen. Highlight-to-Copy uses the same
/// toast, swatchless: a clipboard write nobody asked for out loud is otherwise
/// indistinguishable from nothing happening at all. A window snap pressed
/// without Accessibility raises it too, as a one-line message (`show(message:)`).
///
/// Built in plain AppKit, NOT SwiftUI. An `NSHostingView` as a small panel's
/// content view enters a constraint-update runaway on macOS 26 (its
/// `updateWindowContentSizeExtremaIfNecessary` re-evaluates the SwiftUI graph
/// mid-pass, which invalidates its own transform and re-marks the window until
/// AppKit's per-window update limit throws — the crash lldb pinned to this
/// exact 92×47 toast panel, 2.5.x). A plain `NSView` tree has no view graph and
/// no `updateConstraints` hosting behavior, so that loop cannot occur.
@MainActor
enum CopyToast {
    private static var panel: NSPanel?
    private static var dismissTask: Task<Void, Never>?

    static func show(color: PickedColor, text: String) {
        show(
            text: text,
            swatch: NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
    }

    static func show(text: String, swatch: NSColor? = nil) {
        // Monospaced rather than rounded: copied values (hex codes) read as data.
        present(makeToast(swatch: swatch, caption: "Copied", text: text,
                          font: .monospacedSystemFont(
                              ofSize: Theme.Typography.Size.body, weight: .regular)))
    }

    /// A plain one-line notice, no "Copied" caption.
    static func show(message: String) {
        present(makeToast(swatch: nil, caption: nil, text: message,
                          font: Theme.roundedNSFont(Theme.Typography.Size.body)))
    }

    private static func present(_ content: NSView) {
        hide() // one toast at a time

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

    /// The card: a frosted rounded background with an optional color swatch, a
    /// "Copied" caption, and the copied value. Laid out with explicit frames (no
    /// Auto Layout, no SwiftUI) so it cannot trigger the hosting-view constraint
    /// loop. With no swatch the chip and its gap collapse to zero width, so the
    /// text sits against the same left padding.
    private static func makeToast(swatch: NSColor?, caption: String?, text: String,
                                  font: NSFont) -> NSView {
        let hPad = Theme.Space.medium, vPad = Theme.Space.small
        let gap: CGFloat = swatch == nil ? 0 : Theme.Space.small
        // Swatch size, not a spacing token: about two lines of text tall.
        let chip: CGFloat = swatch == nil ? 0 : 22

        let copied = NSTextField(labelWithString: caption ?? "")
        copied.font = Theme.roundedNSFont(Theme.Typography.Size.tiny)
        copied.textColor = .secondaryLabelColor
        copied.sizeToFit()
        // A 1 pt gap (hairline, below the spacing scale) separates caption and
        // value. No caption: it and its gap collapse, centring the one line.
        let captionH = caption == nil ? 0 : copied.frame.height + 1

        let value = NSTextField(labelWithString: text)
        value.font = font
        value.textColor = .labelColor
        value.sizeToFit()

        let textW = max(caption == nil ? 0 : copied.frame.width, value.frame.width)
        let textH = captionH + value.frame.height
        let contentH = max(chip, textH)
        let width = (hPad + chip + gap + textW + hPad).rounded()
        let height = (vPad + contentH + vPad).rounded()

        let card = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = Theme.Radius.medium
        card.layer?.masksToBounds = true

        let chipView = swatch.map { colour -> NSView in
            let view = NSView(
                frame: NSRect(x: hPad, y: (height - chip) / 2, width: chip, height: chip))
            view.wantsLayer = true
            view.layer?.backgroundColor = colour.cgColor
            view.layer?.cornerRadius = Theme.Radius.small
            view.layer?.borderWidth = 1
            view.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
            return view
        }

        // AppKit's origin is bottom-left: the value sits lower, "Copied" above it.
        let textX = hPad + chip + gap
        let blockBottom = (height - textH) / 2
        value.frame.origin = NSPoint(x: textX, y: blockBottom)
        copied.frame.origin = NSPoint(x: textX, y: blockBottom + value.frame.height + 1)

        if let chipView { card.addSubview(chipView) }
        card.addSubview(value)
        if caption != nil { card.addSubview(copied) }
        return card
    }

    /// Just up-and-right of the cursor, clamped to the cursor's screen so the
    /// toast never lands off-screen when picking near an edge.
    private static func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        // Clears the cursor arrow, not a spacing token.
        var x = mouse.x + 14
        var y = mouse.y + 14
        if let visible = screen?.visibleFrame {
            let margin = Theme.Space.small
            x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
            y = min(max(y, visible.minY + margin), visible.maxY - size.height - margin)
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
