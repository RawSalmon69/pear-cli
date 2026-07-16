import AppKit
import Foundation

/// The procedurally-drawn runners the menu-bar animation can use. Each case is a
/// right-facing silhouette drawn in code (Core Graphics via `NSBezierPath`)
/// rather than shipped as bitmaps: template images tint themselves for the
/// light/dark menu bar automatically, and a procedural cycle keeps the whole
/// feature to a few hundred bytes with no asset catalog.
///
/// Every style renders five frames at the same 20×18 pt canvas so the menu-bar
/// item never jumps when the user switches runners. Drawing stays minimal —
/// clean silhouettes read better than detail at 18 pt.
enum RunnerStyle: String, CaseIterable, Identifiable {
    /// A galloping cat — the original runner. Round head, ears, curled tail.
    case cat
    /// A hopping rabbit — long ears, powerful hind legs, the body arcs on each hop.
    case rabbit
    /// A galloping horse — long legs, an arched neck and muzzle, a flowing tail.
    case horse

    var id: String { rawValue }

    /// Human-readable label for the settings picker.
    var name: String {
        switch self {
        case .cat: return "Cat"
        case .rabbit: return "Rabbit"
        case .horse: return "Horse"
        }
    }

    /// Canvas is a touch wider than tall — a running animal is a horizontal
    /// shape — but the height matches the pear icon so the item never jumps.
    static let size = NSSize(width: 20, height: 18)

    /// The number of frames in one cycle, shared by every style.
    static let count = 5

    /// One full cycle as template images. Built on demand; the model holds the
    /// array for the selected style only and rebuilds it when the style changes.
    func frames() -> [NSImage] {
        (0..<Self.count).map { frame(phase: 2 * .pi * Double($0) / Double(Self.count)) }
    }

    // MARK: - One frame

    private func frame(phase: Double) -> NSImage {
        let image = NSImage(size: Self.size, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            switch self {
            case .cat: Self.drawCat(phase: phase)
            case .rabbit: Self.drawRabbit(phase: phase)
            case .horse: Self.drawHorse(phase: phase)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Cat (original)

    /// Body, head, ears, and tail stay put while four legs swing through a
    /// rotary-gallop cycle (rear pair and front pair a half-cycle apart) and the
    /// torso bobs a hair.
    private static func drawCat(phase: Double) {
        // Torso bobs up and down a fraction of a point over the cycle; the paws
        // stay on the ground, so only the body/head/tail carry the bob.
        let bob = 0.45 * sin(phase * 2)

        // Legs: rear pair leads, front pair a half-cycle behind, the two legs in
        // each pair a hair apart so they don't stamp as one.
        let legs: [(hipX: Double, offset: Double)] = [
            (5.0, 0.0), (6.8, 0.5),          // rear pair
            (12.0, .pi), (13.8, .pi + 0.5),  // front pair
        ]
        for l in legs {
            let a = phase + l.offset
            let footX = l.hipX + 2.0 * sin(a)
            let footY = 2.0 + 2.2 * max(0, cos(a))
            leg(from: NSPoint(x: l.hipX, y: 7.4), to: NSPoint(x: footX, y: footY), width: 1.7)
        }

        // Body.
        NSBezierPath(ovalIn: NSRect(x: 3, y: 7 + bob, width: 12, height: 6)).fill()

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

        // Tail curling up behind.
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

    // MARK: - Rabbit (hop cycle)

    /// The whole rabbit rises and falls on an arc: grounded and gathered for part
    /// of the cycle, airborne with legs tucked at the top of the leap. Long ears
    /// and a powerful haunch read as a rabbit even at menu-bar size.
    private static func drawRabbit(phase: Double) {
        // `airborne` climbs 0→1 through the leap and sits at 0 while grounded.
        let airborne = max(0, sin(phase))
        let hop = 4.0 * airborne
        let tuck = airborne
        let ground = 1.5

        // Hind leg (thick, powerful): extended down-back when grounded, tucked up
        // under the body at the top of the hop.
        let hindFootX = 5.5 + (8.0 - 5.5) * tuck
        let hindFootY = ground + (6.5 + hop - ground) * tuck
        leg(from: NSPoint(x: 6.5, y: 6 + hop), to: NSPoint(x: hindFootX, y: hindFootY), width: 2.0)

        // Front leg (slender): reaches for the ground, folds up in flight.
        let frontFootX = 13.5 + (12.0 - 13.5) * tuck
        let frontFootY = ground + (6.0 + hop - ground) * tuck
        leg(from: NSPoint(x: 12.5, y: 6 + hop), to: NSPoint(x: frontFootX, y: frontFootY), width: 1.5)

        // Haunch bump, body, and a puff tail.
        NSBezierPath(ovalIn: NSRect(x: 4.5, y: 5 + hop, width: 4, height: 4)).fill()
        NSBezierPath(ovalIn: NSRect(x: 4, y: 5.5 + hop, width: 10, height: 6)).fill()
        NSBezierPath(ovalIn: NSRect(x: 2.8, y: 6.5 + hop, width: 2.6, height: 2.6)).fill()

        // Head at the front, two long ears swept up and back.
        NSBezierPath(ovalIn: NSRect(x: 12.5, y: 8 + hop, width: 5, height: 5)).fill()
        leg(from: NSPoint(x: 14.5, y: 12.5 + hop), to: NSPoint(x: 12.6, y: 17 + hop), width: 1.6)
        leg(from: NSPoint(x: 15.6, y: 12.5 + hop), to: NSPoint(x: 14.1, y: 17.2 + hop), width: 1.6)
    }

    // MARK: - Horse (gallop)

    /// A longer-legged gallop with an arched neck and low flowing tail. Same
    /// rotary-gallop legs as the cat, but taller and thinner, and no cat ears —
    /// the neck-and-muzzle read carries the silhouette.
    private static func drawHorse(phase: Double) {
        let bob = 0.5 * sin(phase * 2)

        // Four long legs.
        let legs: [(hipX: Double, offset: Double)] = [
            (3.5, 0.0), (5.0, 0.5),          // rear pair
            (9.5, .pi), (11.0, .pi + 0.5),   // front pair
        ]
        for l in legs {
            let a = phase + l.offset
            let footX = l.hipX + 2.5 * sin(a)
            let footY = 1.0 + 2.8 * max(0, cos(a))
            leg(from: NSPoint(x: l.hipX, y: 8.5), to: NSPoint(x: footX, y: footY), width: 1.5)
        }

        // Body.
        NSBezierPath(ovalIn: NSRect(x: 2.5, y: 8 + bob, width: 10, height: 5)).fill()

        // Flowing tail low behind.
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 2.8, y: 10 + bob))
        tail.curve(
            to: NSPoint(x: 0.6, y: 5.5 + bob),
            controlPoint1: NSPoint(x: 1.4, y: 9 + bob),
            controlPoint2: NSPoint(x: 0.6, y: 7.5 + bob)
        )
        tail.lineWidth = 1.8
        tail.lineCapStyle = .round
        tail.stroke()

        // Arched neck, muzzle, and one small ear.
        leg(from: NSPoint(x: 11, y: 11 + bob), to: NSPoint(x: 16.5, y: 15.5 + bob), width: 3.5)
        NSBezierPath(ovalIn: NSRect(x: 15.3, y: 13.8 + bob, width: 4.2, height: 3)).fill()
        let ear = NSBezierPath()
        ear.move(to: NSPoint(x: 15.6, y: 16.4 + bob))
        ear.line(to: NSPoint(x: 16.9, y: 16.4 + bob))
        ear.line(to: NSPoint(x: 15.9, y: 18 + bob))
        ear.close()
        ear.fill()
    }

    // MARK: - Shared

    /// Draws one limb as a round-capped stroke. Shared by every style.
    private static func leg(from: NSPoint, to: NSPoint, width: Double) {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = width
        path.lineCapStyle = .round
        path.stroke()
    }
}
