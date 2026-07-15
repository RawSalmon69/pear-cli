import AppKit
import SwiftUI

/// Transparent overlay that starts a real `NSDraggingSession` for one stored
/// file, and reports a plain click. Adapted from Dropshit (MIT),
/// `ShelfDragSource.swift`, trimmed to a single item with a Finder-icon drag
/// image (no tile snapshot, no file promises).
///
/// AppKit is used here because SwiftUI's `.onDrag` / `.draggable` silently
/// fail to begin a session inside a non-activating `NSPanel` — the shelf's
/// window type. Vending the real file URL as the pasteboard writer means
/// Finder and other apps receive the actual stored file on drop.
struct ShelfDragOverlay: NSViewRepresentable {
    /// Resolved at drag-start so the overlay always vends the current file.
    let provider: () -> URL?
    /// Fired on a click that never became a drag (used to reveal in Finder).
    let onClick: () -> Void

    func makeNSView(context: Context) -> DragInitiatorView {
        let view = DragInitiatorView()
        view.provider = provider
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: DragInitiatorView, context: Context) {
        nsView.provider = provider
        nsView.onClick = onClick
    }
}

final class DragInitiatorView: NSView, NSDraggingSource {
    var provider: (() -> URL?)?
    var onClick: (() -> Void)?

    private var mouseDownPoint: NSPoint?
    private var sessionActive = false
    private let dragThreshold: CGFloat = 4

    override var isFlipped: Bool { false }

    // Don't let the panel's window-background drag steal our gesture.
    override var mouseDownCanMoveWindow: Bool { false }

    // Take the first click even when the panel isn't key, so a drag can begin
    // immediately on a non-activating panel.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only claim the mouse when there's a file to drag.
        provider?() != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard !sessionActive, let start = mouseDownPoint else { return }
        let loc = event.locationInWindow
        if hypot(loc.x - start.x, loc.y - start.y) > dragThreshold {
            mouseDownPoint = nil
            beginDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let start = mouseDownPoint, !sessionActive {
            let loc = event.locationInWindow
            if hypot(loc.x - start.x, loc.y - start.y) < dragThreshold {
                onClick?()
            }
        }
        mouseDownPoint = nil
    }

    private func beginDrag(with event: NSEvent) {
        guard let url = provider?(),
              FileManager.default.fileExists(atPath: url.path) else { return }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 48, height: 48)

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let frame = NSRect(
            x: bounds.midX - 24, y: bounds.midY - 24, width: 48, height: 48)
        item.setDraggingFrame(frame, contents: icon)

        sessionActive = true
        beginDraggingSession(with: [item], event: event, source: self)
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        sessionActive = false
    }
}
