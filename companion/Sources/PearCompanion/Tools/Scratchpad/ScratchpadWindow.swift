import SwiftUI
import AppKit

/// Floating scratchpad panel: non-activating, joins every Space, and does
/// NOT auto-hide on resignKey (unlike `ClipboardWindowController`) — a quick
/// note must survive switching to another app while you copy from it.
@MainActor
final class ScratchpadWindowController {
    let store: ScratchpadStore
    private var panel: NSPanel?
    /// Local scroll monitor, live only while the panel is open — zero cost
    /// closed (mirrors ShelfWindow's key monitor). Feeds `swipe`.
    private var scrollMonitor: Any?
    private var swipe = SwipeAccumulator()

    /// `store` created here, not at `ScratchpadTool` init — both the window
    /// and its store are lazy, built together on first activation.
    init(store: ScratchpadStore = ScratchpadStore()) {
        self.store = store
    }

    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func hide() {
        store.saveNow()
        removeScrollMonitor()
        panel?.orderOut(nil)
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        installScrollMonitor()
    }

    // MARK: - Swipe to switch / create notes

    private func installScrollMonitor() {
        swipe = SwipeAccumulator()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event) ?? event
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    /// Returns the event to pass through, or `nil` to consume it. Only
    /// horizontal-dominant frames over our own panel are consumed (so the text
    /// view never also pans sideways); vertical frames pass through untouched so
    /// the editor scrolls normally.
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel, ScratchpadSettings.swipeEnabled(),
            let phase = Self.swipePhase(for: event)
        else { return event }

        if let direction = swipe.feed(
            deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, phase: phase) {
            apply(direction)
        }

        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        return horizontal ? nil : event
    }

    private func apply(_ direction: SwipeDirection) {
        switch direction {
        case .next:
            // Antinote's swipe-to-new-note: a forward swipe past the last note
            // creates one; otherwise advance (the store handles wrapping).
            if store.currentIndex == store.notes.count - 1 {
                store.createNote()
            } else {
                store.next()
            }
        case .previous:
            store.previous()
        }
    }

    /// Maps an `NSEvent` scroll to a `SwipePhase`, or `nil` for a classic mouse
    /// wheel (no phase, no momentum) — those keep the editor's normal scrolling,
    /// since swipe-to-switch is a trackpad gesture.
    private static func swipePhase(for event: NSEvent) -> SwipePhase? {
        if !event.momentumPhase.isEmpty { return .momentum }
        if event.phase.contains(.began) { return .began }
        if event.phase.contains(.changed) { return .changed }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { return .ended }
        return nil
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 320, height: 300)
        let panel = ScratchpadPanel(
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
        // No title bar to drag by; let the whole card move the window.
        panel.isMovableByWindowBackground = true
        panel.onCancel = { [weak self] in self?.hide() }
        let host = NSHostingView(
            rootView: ScratchpadView(store: store, onClose: { [weak self] in self?.hide() })
        )
        // Clip the rectangular backing to the card's corner radius so no
        // hairline edge shows past the rounded glass.
        host.wantsLayer = true
        host.layer?.cornerRadius = 16
        host.layer?.masksToBounds = true
        panel.contentView = host

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - size.width - 20,
                y: visible.minY + 20
            ))
        }
        return panel
    }
}

/// Borderless panel that both takes key focus (so typing works) and keeps
/// it — no `resignKey` auto-hide, so focus loss doesn't close the note.
private final class ScratchpadPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    // One dismissal grammar across every floating surface: Esc closes
    // (and the controller's hide() saves first).
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
