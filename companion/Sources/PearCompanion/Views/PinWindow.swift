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
}

/// A capture pinned to the screen: a borderless, always-on-top panel showing
/// just the shot, dragged by its body and resized from its edges with the
/// aspect locked. Esc or ⌘W closes it while it is key.
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
    private static var observingCaptures = false

    private let panel: PinPanel

    private init(panel: PinPanel) {
        self.panel = panel
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
            cascade: open.count)

        let imageView = PinImageView(frame: NSRect(origin: .zero, size: frame.size))
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
        panel.isMovableByWindowBackground = true
        panel.contentAspectRatio = frame.size
        panel.contentMinSize = PinLayout.minimumSize(for: frame.size)
        panel.contentView = imageView

        let controller = PinController(panel: panel)
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
                        if visible { pin.panel.orderFrontRegardless() } else { pin.panel.orderOut(nil) }
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
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// `NSImageView` is a control and keeps its mouse-downs, which would leave a
/// pin that cannot be dragged by its only surface. Hand them to the window.
private final class PinImageView: NSImageView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
