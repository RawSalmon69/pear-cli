import AppKit

/// Production screen blanker. Puts one opaque black, borderless window on every
/// `NSScreen`, each carrying a hint and a Done button. PURE APPKIT — no
/// `NSHostingView`/SwiftUI anywhere in these windows (the repo's macOS-26
/// hosting-view-in-floating-panel crash rule). The mouse is never intercepted,
/// so the Done button is always clickable; that is the escape hatch the whole
/// design leans on.
@MainActor
final class CleanModeScreenBlanker: CleanModeScreenBlanking {
    private var windows: [NSWindow] = []
    private var onDone: (() -> Void)?

    func cover(onDone: @escaping () -> Void) {
        self.onDone = onDone
        rebuild()
    }

    func recover() {
        // A display was added or removed; rebuild against the current set so a
        // new screen never shows through un-blanked and a detached one leaves no
        // orphan window.
        guard onDone != nil else { return }
        rebuild()
    }

    func uncover() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        onDone = nil
    }

    // MARK: - Building

    private func rebuild() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()

        guard !CleanModeRuntime.isRunningTests else { return }

        for screen in NSScreen.screens {
            let window = makeOverlay(for: screen)
            windows.append(window)
            window.orderFrontRegardless()
        }
        // Take key so a first click anywhere actuates Done without a focus round
        // trip; other screens rely on the button's acceptsFirstMouse.
        windows.first?.makeKey()
    }

    private func makeOverlay(for screen: NSScreen) -> NSWindow {
        let frame = screen.frame

        let window = OverlayWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor

        let centerX = frame.size.width / 2
        let centerY = frame.size.height / 2

        let hint = Self.makeLabel(
            string: "Clean Mode — click Done when you're finished",
            size: 15,
            color: NSColor(white: 0.42, alpha: 1)
        )
        hint.frame = NSRect(x: centerX - 320, y: centerY + 36, width: 640, height: 24)
        content.addSubview(hint)

        let done = ClosureButton(title: "Done") { [weak self] in self?.onDone?() }
        done.frame = NSRect(x: centerX - 100, y: centerY - 48, width: 200, height: 60)
        content.addSubview(done)

        window.contentView = content
        return window
    }

    private static func makeLabel(string: String, size: CGFloat, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .systemFont(ofSize: size, weight: .medium)
        field.textColor = color
        field.alignment = .center
        field.isBezeled = false
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        return field
    }
}

/// Borderless window that can still become key, so the Done button on the
/// primary screen actuates on the first click.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// An `NSButton` that runs a closure on click and actuates on the first click
/// even when its window isn't key — essential for Done buttons on secondary
/// screens.
private final class ClosureButton: NSButton {
    private let onClick: () -> Void

    init(title: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize: 18, weight: .semibold)
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func fire() { onClick() }
}
