import AppKit

/// Programmatic pear glyph for the menu bar. Template image so macOS tints
/// it for light/dark/active states; the unread variant adds a dot badge.
enum MenuBarIcon {
    static func image(unread: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()

            // Body: bottom lobe + top lobe blended into a pear silhouette.
            path.append(NSBezierPath(ovalIn: NSRect(x: 3.2, y: 1.5, width: 11.6, height: 11.6)))
            path.append(NSBezierPath(ovalIn: NSRect(x: 5.7, y: 8.0, width: 6.6, height: 7.2)))
            NSColor.black.setFill()
            path.fill()

            // Stem.
            let stem = NSBezierPath()
            stem.move(to: NSPoint(x: 9.0, y: 14.5))
            stem.curve(
                to: NSPoint(x: 11.2, y: 17.2),
                controlPoint1: NSPoint(x: 9.2, y: 15.8),
                controlPoint2: NSPoint(x: 10.0, y: 16.8)
            )
            stem.lineWidth = 1.4
            stem.lineCapStyle = .round
            NSColor.black.setStroke()
            stem.stroke()

            // Leaf.
            let leaf = NSBezierPath()
            leaf.move(to: NSPoint(x: 10.6, y: 15.2))
            leaf.curve(
                to: NSPoint(x: 14.6, y: 16.4),
                controlPoint1: NSPoint(x: 11.8, y: 16.8),
                controlPoint2: NSPoint(x: 13.6, y: 17.2)
            )
            leaf.curve(
                to: NSPoint(x: 10.6, y: 15.2),
                controlPoint1: NSPoint(x: 13.4, y: 14.8),
                controlPoint2: NSPoint(x: 11.6, y: 14.6)
            )
            leaf.fill()

            if unread {
                // Badge dot, punched out then filled so it reads at 18 px.
                let badgeRect = NSRect(x: 12.4, y: 0.4, width: 5.2, height: 5.2)
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.2, dy: -1.2)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: badgeRect).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
