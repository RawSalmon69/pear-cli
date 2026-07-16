import AppKit
import SwiftUI

// Adapted from Radix (MIT), https://github.com/colinvkim/Radix, commit 6c694377
// (Features/Visualization/SunburstInteractionOverlay.swift), stripped to the
// pointer handling the sunburst needs: hover, single click, drag/scroll pan,
// and pinch/scroll zoom. Radix's discard-pile drag-and-drop (NSDraggingSource,
// NSPasteboard, drag ghosts) and multi-select machinery are dropped.
//
// AppKit is required because SwiftUI has no native scroll-wheel or precise
// magnify gesture on macOS 14. The view is flipped so its event coordinates
// match the SwiftUI Canvas it overlays (top-left origin, y-down). All callbacks
// run on the main actor via the @MainActor NSView, matching ShelfDragOverlay.

struct SunburstInteractionOverlay: NSViewRepresentable {
    let onHover: (CGPoint?) -> Void
    let onClick: (CGPoint) -> Void
    let onPan: (CGSize) -> Void
    let onMagnify: (CGPoint, CGFloat) -> Void
    let canStartPan: (CGPoint) -> Bool
    let isPanEnabled: Bool

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: InteractionView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: InteractionView) {
        view.onHover = onHover
        view.onClick = onClick
        view.onPan = onPan
        view.onMagnify = onMagnify
        view.canStartPan = canStartPan
        view.isPanEnabled = isPanEnabled
    }

    final class InteractionView: NSView {
        var onHover: (CGPoint?) -> Void = { _ in }
        var onClick: (CGPoint) -> Void = { _ in }
        var onPan: (CGSize) -> Void = { _ in }
        var onMagnify: (CGPoint, CGFloat) -> Void = { _, _ in }
        var canStartPan: (CGPoint) -> Bool = { _ in false }
        var isPanEnabled = false

        private static let dragThreshold: CGFloat = 3
        private static let lineScrollScale: CGFloat = 10
        // nonisolated: referenced from the nonisolated CGFloat clamp helper below.
        fileprivate nonisolated static let maximumScrollPanDelta: CGFloat = 80

        private var trackingArea: NSTrackingArea?
        private var mouseDownLocation: CGPoint?
        private var lastDragLocation: CGPoint?
        private var shouldPan = false
        private var didPan = false

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            onHover(eventLocation(event))
        }

        override func mouseMoved(with event: NSEvent) {
            onHover(eventLocation(event))
        }

        override func mouseExited(with event: NSEvent) {
            onHover(nil)
        }

        override func mouseDown(with event: NSEvent) {
            let location = eventLocation(event)
            mouseDownLocation = location
            lastDragLocation = location
            shouldPan = isPanEnabled && canStartPan(location)
            didPan = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let mouseDownLocation, let lastDragLocation else { return }
            let location = eventLocation(event)

            if !didPan {
                guard didExceedDragThreshold(from: mouseDownLocation, to: location) else { return }
                didPan = true
            }

            defer { self.lastDragLocation = location }
            guard shouldPan, isPanEnabled else { return }

            onPan(CGSize(
                width: location.x - lastDragLocation.x,
                height: location.y - lastDragLocation.y
            ))
            onHover(location)
        }

        override func mouseUp(with event: NSEvent) {
            let location = eventLocation(event)
            if !didPan { onClick(location) }
            mouseDownLocation = nil
            lastDragLocation = nil
            shouldPan = false
            didPan = false
        }

        override func magnify(with event: NSEvent) {
            let location = eventLocation(event)
            onMagnify(location, max(0.75, 1 + event.magnification))
            onHover(location)
        }

        override func scrollWheel(with event: NSEvent) {
            let location = eventLocation(event)
            let zoomModifiers: NSEvent.ModifierFlags = [.command, .option]

            if !event.modifierFlags.intersection(zoomModifiers).isEmpty {
                let scrollDelta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : -event.scrollingDeltaX
                guard scrollDelta != 0 else { return }
                onMagnify(location, pow(1.0025, scrollDelta))
                onHover(location)
                return
            }

            if isPanEnabled, let panDelta = panDelta(for: event) {
                onPan(panDelta)
                onHover(location)
                return
            }

            super.scrollWheel(with: event)
        }

        private func eventLocation(_ event: NSEvent) -> CGPoint {
            convert(event.locationInWindow, from: nil)
        }

        private func didExceedDragThreshold(from start: CGPoint, to end: CGPoint) -> Bool {
            let dx = end.x - start.x
            let dy = end.y - start.y
            return ((dx * dx) + (dy * dy)) >= (Self.dragThreshold * Self.dragThreshold)
        }

        private func panDelta(for event: NSEvent) -> CGSize? {
            var delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
            guard delta != .zero else { return nil }

            if !event.isDirectionInvertedFromDevice {
                delta.width *= -1
                delta.height *= -1
            }
            if !event.hasPreciseScrollingDeltas {
                delta.width *= Self.lineScrollScale
                delta.height *= Self.lineScrollScale
            }
            return CGSize(
                width: delta.width.clampedScrollPanDelta,
                height: delta.height.clampedScrollPanDelta
            )
        }
    }
}

private extension CGFloat {
    var clampedScrollPanDelta: CGFloat {
        Swift.min(
            Swift.max(self, -SunburstInteractionOverlay.InteractionView.maximumScrollPanDelta),
            SunburstInteractionOverlay.InteractionView.maximumScrollPanDelta
        )
    }
}
