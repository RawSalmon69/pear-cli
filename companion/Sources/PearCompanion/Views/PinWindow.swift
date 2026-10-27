import AppKit

/// Pure sizing for a pinned capture, so the fit is testable without a screen:
/// the shot at its on-screen size (pixels ÷ backing scale, so the PNG's dpi tag
/// does not matter), shrunk to fit a share of the visible frame with the aspect
/// kept, centred, and cascaded so a second pin does not sit exactly on the first.
enum PinLayout {
    /// Share of the visible frame a pin may claim when it opens.
    static let fill: CGFloat = 0.8
    /// The longer side a pin can be shrunk to.
    static let minimumLongSide: CGFloat = 80

    static func frame(pixels: NSSize, scale: CGFloat, visible: NSRect, cascade: Int) -> NSRect {
        let scale = scale > 0 ? scale : 1
        var size = pixels.width > 0 && pixels.height > 0
            ? NSSize(width: pixels.width / scale, height: pixels.height / scale)
            : NSSize(width: minimumLongSide, height: minimumLongSide)
        if visible.width > 0, visible.height > 0 {
            let shrink = min(1, visible.width * fill / size.width, visible.height * fill / size.height)
            size = NSSize(width: max(1, (size.width * shrink).rounded()),
                          height: max(1, (size.height * shrink).rounded()))
        }
        let offset = CGFloat(cascade % 8) * Theme.Space.xLarge
        var origin = NSPoint(x: visible.midX - size.width / 2 + offset,
                             y: visible.midY - size.height / 2 - offset)
        if visible.width > 0, visible.height > 0 {
            origin.x = min(max(visible.minX, origin.x), visible.maxX - size.width)
            origin.y = min(max(visible.minY, origin.y), visible.maxY - size.height)
        }
        return NSRect(origin: origin, size: size)
    }

    /// Smallest the user can drag a pin to: the same aspect, longer side
    /// `minimumLongSide`, and never larger than the pin itself.
    static func minimumSize(for size: NSSize) -> NSSize {
        let longer = max(size.width, size.height)
        guard longer > 0 else { return size }
        let factor = min(1, minimumLongSide / longer)
        return NSSize(width: size.width * factor, height: size.height * factor)
    }

    /// Where the hover close button sits in a pin's (unflipped) bounds: the
    /// top-left corner, where a window's close button is, inset by
    /// `Theme.Space.small`. Nil when the pin is too small to hold it with that
    /// inset all round, so a thin strip stays all drag surface; the right-click
    /// menu, Esc and ⌘W still close it.
    static func closeButtonFrame(in bounds: CGRect, button: CGSize) -> CGRect? {
        let inset = Theme.Space.small
        guard bounds.width >= button.width + 2 * inset,
              bounds.height >= button.height + 2 * inset else { return nil }
        return CGRect(x: bounds.minX + inset, y: bounds.maxY - inset - button.height,
                      width: button.width, height: button.height)
    }
}

/// A capture pinned to the screen: a borderless, always-on-top panel showing
/// just the shot, dragged by its body and resized from its edges with the
/// aspect locked. Esc or ⌘W closes it while it is key; a ✕ shows in its
/// top-left corner while the pointer is over it, and a right-click offers Close
/// and Reveal in Finder.
///
/// The pin reads its file once, at pin time, and holds that image, so the card
/// that spawned it can go and a later `CaptureStore` sweep cannot break it. Pins
/// are not restored at relaunch. Each one is owned by `open` until it closes,
/// so closing releases the window and the image together.
///
/// Pins leave the screen for a capture, like the preview stack: a full-screen
/// shot must not quietly contain one. They come back afterwards.
@MainActor
final class PinController: NSObject, NSWindowDelegate {
    private static var open: [PinController] = []
    /// Pins ever opened, for the cascade. Monotonic rather than `open.count`,
    /// which repeats after a middle pin closes and stacks the next one exactly
    /// on a survivor.
    private static var opened = 0
    private static var observingCaptures = false

    private let panel: PinPanel
    private let imageView: PinImageView

    private init(panel: PinPanel, imageView: PinImageView) {
        self.panel = panel
        self.imageView = imageView
    }

    /// Pins the capture at `url` on `screen` (the main display if nil). Returns
    /// false when the file cannot be read, so the caller can drop its card.
    @discardableResult
    static func pin(url: URL, on screen: NSScreen?) -> Bool {
        guard let image = NSImage(contentsOf: url) else { return false }
        let screen = screen ?? NSScreen.main ?? NSScreen.screens.first
        let pixels = image.representations.first.map {
            NSSize(width: $0.pixelsWide, height: $0.pixelsHigh)
        } ?? image.size
        let frame = PinLayout.frame(
            pixels: pixels.width > 0 ? pixels : image.size,
            scale: pixels.width > 0 ? screen?.backingScaleFactor ?? 2 : 1,
            visible: screen?.visibleFrame ?? .zero,
            cascade: opened)
        opened += 1

        let imageView = PinImageView(frame: NSRect(origin: .zero, size: frame.size), fileURL: url)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Theme.Radius.medium
        imageView.layer?.masksToBounds = true
        imageView.setAccessibilityLabel("Pinned screenshot")

        // `.borderless` is the empty mask; `.resizable` is what lets the
        // window server resize it from its edges.
        let panel = PinPanel(
            contentRect: frame,
            styleMask: [.resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentAspectRatio = frame.size
        panel.contentMinSize = PinLayout.minimumSize(for: frame.size)
        panel.contentView = imageView

        let controller = PinController(panel: panel, imageView: imageView)
        panel.delegate = controller
        open.append(controller)
        observeCapturesOnce()
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }

    /// Same contract as the preview stack: `queue: nil`, so the pins are off
    /// the screen before `screencapture` starts. App-lifetime, registered once.
    private static func observeCapturesOnce() {
        guard !observingCaptures else { return }
        observingCaptures = true
        for (name, visible) in [(Notification.Name.pearHideForCapture, false),
                                (Notification.Name.pearRestoreAfterCapture, true)] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: nil
            ) { _ in
                MainActor.assumeIsolated {
                    for pin in open {
                        if visible {
                            pin.panel.orderFrontRegardless()
                            // No mouseEntered comes for a window that appears
                            // under a still pointer, so ask where it is.
                            pin.imageView.setHovering(pin.panel.frame.contains(NSEvent.mouseLocation),
                                                      animated: false)
                        } else {
                            // Ordered out mid-hover, it gets no mouseExited either.
                            pin.imageView.setHovering(false, animated: false)
                            pin.panel.orderOut(nil)
                        }
                    }
                }
            }
        }
    }
}

/// Borderless panels refuse key status by default; Esc and ⌘W need it.
private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }

    /// An agent app has no File menu to supply ⌘W.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Caps Lock is in the device-independent mask; it must not block ⌘W.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock) == .command,
           event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// `NSImageView` is a control and keeps its mouse-downs, which would leave a
/// pin that cannot be dragged by its only surface. Hand them to the window with
/// `performDrag`, the one move mechanism: no `isMovableByWindowBackground` or
/// `mouseDownCanMoveWindow` beside it, so nothing races it. Edge resizing is
/// the window frame's, and only events that reach this view are drags.
///
/// The hover ✕ is a subview, so hit-testing returns it ahead of this view and
/// its press never reaches `mouseDown`; it is inset from the edges, so the
/// window's resize zones stay clear. It is hidden, not just transparent,
/// whenever it is not showing: hit-testing skips a hidden view but not a
/// zero-alpha one.
private final class PinImageView: NSImageView {
    private let fileURL: URL
    private let closeButton = PinCloseButton()
    private var showingClose = false
    /// Kept so a resize or VoiceOver starting can re-decide the ✕ without a
    /// fresh mouseEntered.
    private var hovering = false

    init(frame: NSRect, fileURL: URL) {
        self.fileURL = fileURL
        super.init(frame: frame)
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "Close pin")?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: Theme.Typography.Size.large, weight: .regular)
                    // A white cross on a dark translucent disc reads on any shot.
                    .applying(NSImage.SymbolConfiguration(
                        paletteColors: [.white, NSColor.black.withAlphaComponent(0.55)])))
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.sizeToFit()
        closeButton.target = self
        closeButton.action = #selector(closePin)
        closeButton.toolTip = "Close pin"
        closeButton.setAccessibilityLabel("Close pin")
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        closeButton.isHidden = true
        closeButton.alphaValue = 0
        addSubview(closeButton)
        // `.inVisibleRect` follows every resize, so this one area is enough.
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        setHovering(false, animated: false)
        followVoiceOver()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A resize can make the pin too small for the ✕ or big enough for it, and
    /// the ✕'s frame was only decided on hover. This view is resized by the
    /// window as its content view; it never resizes the window.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { setHovering(hovering, animated: false) }
    }

    /// VoiceOver cannot hover, so the ✕ shows while it runs; it can start or
    /// stop with a pin already up. Re-armed per change, like the menu-bar runner.
    /// A closed pin leaves one dead registration (weak, retains nothing) until
    /// VoiceOver next toggles.
    private func followVoiceOver() {
        withObservationTracking {
            _ = VoiceOverState.shared.isOn
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.setHovering(self.hovering, animated: false)
                self.followVoiceOver()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        // A control-click is the context menu, never a drag.
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        window?.performDrag(with: event)
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true, animated: true) }
    override func mouseExited(with event: NSEvent) { setHovering(false, animated: true) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "").target = self
        // The pin holds the image, not the file: a swept or moved file has
        // nothing to reveal.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealFile),
                         keyEquivalent: "").target = self
        }
        return menu
    }

    @objc private func closePin() { window?.close() }
    @objc private func revealFile() { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }

    /// Shows the ✕ while hovered (always under VoiceOver, which cannot hover)
    /// when the pin is big enough for it. Fades, unless Reduce Motion is on.
    func setHovering(_ hovering: Bool, animated: Bool) {
        self.hovering = hovering
        let frame = PinLayout.closeButtonFrame(in: bounds, button: closeButton.frame.size)
        let show = (hovering || NSWorkspace.shared.isVoiceOverEnabled) && frame != nil
        if let frame { closeButton.frame = frame }
        showingClose = show
        let button = closeButton
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            button.alphaValue = show ? 1 : 0
            button.isHidden = !show
            return
        }
        if show { button.isHidden = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            button.animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A re-enter during the fade-out keeps it.
                guard let self, !self.showingClose else { return }
                self.closeButton.isHidden = true
            }
        })
    }
}

/// The pin is a non-activating panel and Pear is rarely frontmost: the first
/// click on the ✕ must close it, not just bring it forward.
private final class PinCloseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
