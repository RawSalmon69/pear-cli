import AppKit

/// The menu-bar pear, drawn as a template image so macOS tints it for light,
/// dark and the highlighted state on its own.
///
/// The outline is the **same path as the website's mark** (`site/index.html`,
/// `#i-pear`), converted from its 120×138 viewBox rather than approximated:
/// the earlier icon was two overlapping ovals and read as a blob at 18 pt, next
/// to a site logo with an actual pear silhouette. If the brand mark changes,
/// re-convert the path instead of nudging control points by hand.
enum MenuBarIcon {
    private static let box = NSSize(width: 18, height: 18)

    static func image(unread: Bool) -> NSImage {
        let image = NSImage(size: box, flipped: false) { _ in
            draw(unread: unread)
            return true
        }
        // Template: the menu bar owns the colour, including the inverted look
        // while the panel is open.
        image.isTemplate = true
        return image
    }

    private static func draw(unread: Bool) {
        let body = NSBezierPath()
        body.move(to: NSPoint(x: 9.00, y: 12.36))
        body.curve(
            to: NSPoint(x: 7.26, y: 10.39),
            controlPoint1: NSPoint(x: 7.96, y: 12.36),
            controlPoint2: NSPoint(x: 7.49, y: 11.43))
        body.curve(
            to: NSPoint(x: 5.87, y: 7.61),
            controlPoint1: NSPoint(x: 7.03, y: 9.23),
            controlPoint2: NSPoint(x: 6.68, y: 8.65))
        body.curve(
            to: NSPoint(x: 5.17, y: 3.32),
            controlPoint1: NSPoint(x: 4.83, y: 6.33),
            controlPoint2: NSPoint(x: 4.48, y: 4.71))
        body.curve(
            to: NSPoint(x: 9.00, y: 1.46),
            controlPoint1: NSPoint(x: 5.87, y: 2.04),
            controlPoint2: NSPoint(x: 7.38, y: 1.46))
        body.curve(
            to: NSPoint(x: 12.83, y: 3.32),
            controlPoint1: NSPoint(x: 10.62, y: 1.46),
            controlPoint2: NSPoint(x: 12.13, y: 2.04))
        body.curve(
            to: NSPoint(x: 12.13, y: 7.61),
            controlPoint1: NSPoint(x: 13.52, y: 4.71),
            controlPoint2: NSPoint(x: 13.17, y: 6.33))
        body.curve(
            to: NSPoint(x: 10.74, y: 10.39),
            controlPoint1: NSPoint(x: 11.32, y: 8.65),
            controlPoint2: NSPoint(x: 10.97, y: 9.23))
        body.curve(
            to: NSPoint(x: 9.00, y: 12.36),
            controlPoint1: NSPoint(x: 10.51, y: 11.43),
            controlPoint2: NSPoint(x: 10.04, y: 12.36))
        body.close()

        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: 9.00, y: 12.01))
        stem.curve(
            to: NSPoint(x: 9.46, y: 14.33),
            controlPoint1: NSPoint(x: 9.00, y: 13.06),
            controlPoint2: NSPoint(x: 9.00, y: 13.64))

        let leaf = NSBezierPath()
        leaf.move(to: NSPoint(x: 9.46, y: 14.22))
        leaf.curve(
            to: NSPoint(x: 13.06, y: 15.14),
            controlPoint1: NSPoint(x: 10.39, y: 15.49),
            controlPoint2: NSPoint(x: 12.13, y: 15.72))
        leaf.curve(
            to: NSPoint(x: 9.58, y: 13.99),
            controlPoint1: NSPoint(x: 12.59, y: 13.87),
            controlPoint2: NSPoint(x: 11.09, y: 13.29))
        leaf.close()

        NSColor.black.setFill()
        NSColor.black.setStroke()
        body.fill()
        leaf.fill()
        // Stroked, not filled: the stem is a line in the source mark. 0.58 pt is
        // the source's 5 pt scaled by the same factor as the rest of the glyph.
        stem.lineWidth = 0.58
        stem.lineCapStyle = .round
        stem.stroke()

        if unread {
            // Punch a ring out of the body first so the dot still reads when it
            // overlaps the fruit.
            let badge = NSRect(x: 12.4, y: 0.4, width: 5.2, height: 5.2)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: badge.insetBy(dx: -1.2, dy: -1.2)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: badge).fill()
        }
    }
}
