import AppKit
import Foundation

/// Draws the running-cat run cycle as template `NSImage`s for the menu bar.
///
/// We deliberately draw the frames in code (Core Graphics via `NSBezierPath`)
/// rather than shipping bitmaps: template images tint themselves for the
/// light/dark menu bar automatically, and a procedural gallop keeps the whole
/// feature to a few hundred bytes with no asset catalog.
///
/// The frames are a right-facing cat silhouette — body, head, ears, and tail
/// stay put while four legs swing through a rotary-gallop cycle (rear pair and
/// front pair a half-cycle apart) and the torso bobs a hair. Five frames read
/// as a smooth loop at menu-bar size; more detail just muddies at 18 pt.
enum RunnerFrames {
    /// Canvas is a touch wider than tall — a running animal is a horizontal
    /// shape — but the height matches the pear icon so the item never jumps.
    static let size = NSSize(width: 20, height: 18)

    /// The number of frames in one run cycle.
    static let count = 5

    /// One full run cycle as template images. Built once; the model holds the
    /// array for the app's lifetime.
    static func frames() -> [NSImage] {
        (0..<count).map { frame(phase: 2 * .pi * Double($0) / Double(count)) }
    }

    // MARK: - One frame

    private static func frame(phase: Double) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            // Torso bobs up and down a fraction of a point over the cycle; the
            // paws stay on the ground, so only the body/head/tail carry the bob.
            let bob = 0.45 * sin(phase * 2)

            drawLegs(phase: phase)
            drawBody(bob: bob)
            drawHead(bob: bob)
            drawTail(bob: bob)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Fixed parts (torso bobs together)

    private static func drawBody(bob: Double) {
        NSBezierPath(ovalIn: NSRect(x: 3, y: 7 + bob, width: 12, height: 6)).fill()
    }

    private static func drawHead(bob: Double) {
        // Head circle at the front (right), with two ear triangles on top.
        NSBezierPath(ovalIn: NSRect(x: 13.2, y: 8.7 + bob, width: 5.6, height: 5.6)).fill()

        let ears = NSBezierPath()
        ears.move(to: NSPoint(x: 14.3, y: 13.4 + bob))
        ears.line(to: NSPoint(x: 15.7, y: 13.4 + bob))
        ears.line(to: NSPoint(x: 14.4, y: 15.9 + bob))
        ears.close()
        ears.move(to: NSPoint(x: 16.3, y: 13.4 + bob))
        ears.line(to: NSPoint(x: 17.7, y: 13.4 + bob))
        ears.line(to: NSPoint(x: 17.6, y: 15.9 + bob))
        ears.close()
        ears.fill()
    }

    private static func drawTail(bob: Double) {
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 3.4, y: 9.5 + bob))
        tail.curve(
            to: NSPoint(x: 0.9, y: 14.2 + bob),
            controlPoint1: NSPoint(x: 1.6, y: 9.8 + bob),
            controlPoint2: NSPoint(x: 0.6, y: 12.0 + bob)
        )
        tail.lineWidth = 1.8
        tail.lineCapStyle = .round
        tail.stroke()
    }

    // MARK: - Legs (the animated part)

    /// Four legs on a rotary gallop: the rear pair leads, the front pair is a
    /// half-cycle behind, and the two legs within each pair are a hair apart so
    /// they don't stamp as one. Each foot swings horizontally and lifts when it
    /// is forward in the stride.
    private static func drawLegs(phase: Double) {
        // (hipX, phaseOffset). Rear pair near the tail, front pair near the head.
        let legs: [(hipX: Double, offset: Double)] = [
            (5.0, 0.0), (6.8, 0.5),          // rear pair
            (12.0, .pi), (13.8, .pi + 0.5),  // front pair
        ]
        let hipY = 7.4
        let groundY = 2.0
        for leg in legs {
            let a = phase + leg.offset
            let footX = leg.hipX + 2.0 * sin(a)
            let footY = groundY + 2.2 * max(0, cos(a))
            let path = NSBezierPath()
            path.move(to: NSPoint(x: leg.hipX, y: hipY))
            path.line(to: NSPoint(x: footX, y: footY))
            path.lineWidth = 1.7
            path.lineCapStyle = .round
            path.stroke()
        }
    }
}
