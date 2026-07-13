import SwiftUI
import AppKit
import CoreImage

// MARK: - Tools

/// The five markup tools. Exactly one is active at a time.
enum MarkupTool: String, CaseIterable, Identifiable {
    case arrow, rectangle, text, highlighter, blur

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .text: return "textformat"
        case .highlighter: return "highlighter"
        case .blur: return "square.grid.3x3.fill"
        }
    }

    var help: String {
        switch self {
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .text: return "Text"
        case .highlighter: return "Highlighter"
        case .blur: return "Pixelate region"
        }
    }

    /// Blur has no colour; every other tool draws with the current colour.
    var usesColor: Bool { self != .blur }
}

/// Stroke weight in *display* points. Committed geometry is stored in image
/// pixels, so we divide by the live render scale when a shape is created.
enum StrokeWidth: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        }
    }

    private var displayWidth: CGFloat {
        switch self {
        case .small: return 2
        case .medium: return 4
        case .large: return 7
        }
    }

    private var displayFont: CGFloat {
        switch self {
        case .small: return 15
        case .medium: return 22
        case .large: return 32
        }
    }

    func imageWidth(scale: CGFloat) -> CGFloat { displayWidth / max(scale, 0.001) }
    func imageFont(scale: CGFloat) -> CGFloat { displayFont / max(scale, 0.001) }
}

// MARK: - Annotation model

/// A single markup. All geometry is stored in *image pixel* coordinates
/// (top-left origin, y-down — matching SwiftUI), so flattening at native
/// resolution is a straight 1:1 draw with no low-res upscaling.
struct Annotation: Identifiable {
    let id = UUID()
    var kind: Kind

    enum Kind {
        case arrow(start: CGPoint, end: CGPoint, color: Color, width: CGFloat)
        case rectangle(rect: CGRect, color: Color, width: CGFloat)
        case highlighter(start: CGPoint, end: CGPoint, color: Color, width: CGFloat)
        case text(origin: CGPoint, string: String, color: Color, fontSize: CGFloat)
        case blur(rect: CGRect)
    }
}

// MARK: - Image helpers

extension NSImage {
    /// The true pixel dimensions, not the (retina-halved) point size — this is
    /// the resolution we flatten to.
    var pixelSize: CGSize {
        if let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CGSize(width: cg.width, height: cg.height)
        }
        if let rep = representations.first {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return size
    }
}

/// Produces a chunky pixelated copy of the whole image once, up front. Blur
/// annotations then draw a clipped crop of it, so the effect stays crisp at
/// native resolution and is cheap to preview live.
enum Pixelation {
    static func pixelated(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let ci = CIImage(cgImage: cg)
        let extent = ci.extent
        guard extent.width > 0, extent.height > 0,
              let filter = CIFilter(name: "CIPixellate") else { return nil }

        // Clamp so the mosaic doesn't fade out at the edges, then crop back.
        filter.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        let cellSize = max(max(extent.width, extent.height) / 60, 8)
        filter.setValue(cellSize, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: kCIInputCenterKey)

        guard let output = filter.outputImage?.cropped(to: extent) else { return nil }
        let context = CIContext()
        guard let result = context.createCGImage(output, from: extent) else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: extent.width, height: extent.height))
    }
}

// MARK: - Canvas

/// Renders the base image plus every annotation. Reused verbatim for the live
/// editor (`renderScale` < 1, fits the window) and for export via
/// `ImageRenderer` (`renderScale` = 1, drawn at native pixel size), which
/// guarantees the flattened output matches what the user saw.
struct MarkupCanvas: View {
    let base: NSImage
    let pixelated: NSImage?
    let annotations: [Annotation]
    var preview: Annotation?
    let pixelSize: CGSize
    let renderScale: CGFloat

    private var displaySize: CGSize {
        CGSize(width: pixelSize.width * renderScale, height: pixelSize.height * renderScale)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: base)
                .resizable()
                .interpolation(.high)
                .frame(width: displaySize.width, height: displaySize.height)

            Canvas { context, size in
                for annotation in annotations {
                    draw(annotation, in: context, canvas: size)
                }
                if let preview {
                    draw(preview, in: context, canvas: size)
                }
            }
            .frame(width: displaySize.width, height: displaySize.height)
        }
        .frame(width: displaySize.width, height: displaySize.height)
    }

    // MARK: Drawing

    private func draw(_ annotation: Annotation, in context: GraphicsContext, canvas: CGSize) {
        let s = renderScale
        switch annotation.kind {
        case let .blur(rect):
            guard let pixelated else { return }
            let target = scaled(rect, s)
            context.drawLayer { layer in
                layer.clip(to: Path(target))
                layer.draw(
                    Image(nsImage: pixelated),
                    in: CGRect(origin: .zero, size: canvas)
                )
            }

        case let .rectangle(rect, color, width):
            context.stroke(
                Path(scaled(rect, s)),
                with: .color(color),
                style: StrokeStyle(lineWidth: width * s, lineJoin: .round)
            )

        case let .highlighter(start, end, color, width):
            var path = Path()
            path.move(to: point(start, s))
            path.addLine(to: point(end, s))
            context.stroke(
                path,
                with: .color(color.opacity(0.35)),
                style: StrokeStyle(lineWidth: width * s * 2.4, lineCap: .round)
            )

        case let .arrow(start, end, color, width):
            drawArrow(from: point(start, s), to: point(end, s),
                      color: color, lineWidth: width * s, in: context)

        case let .text(origin, string, color, fontSize):
            guard !string.isEmpty else { return }
            let text = Text(string)
                .font(.system(size: fontSize * s, weight: .semibold, design: .rounded))
                .foregroundColor(color)
            context.draw(context.resolve(text), at: point(origin, s), anchor: .topLeading)
        }
    }

    private func drawArrow(from a: CGPoint, to b: CGPoint, color: Color,
                           lineWidth: CGFloat, in context: GraphicsContext) {
        var shaft = Path()
        shaft.move(to: a)
        shaft.addLine(to: b)
        context.stroke(shaft, with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

        let angle = atan2(b.y - a.y, b.x - a.x)
        let headLength = max(lineWidth * 4.5, 12)
        let spread = CGFloat.pi / 7
        let left = CGPoint(x: b.x - headLength * cos(angle - spread),
                           y: b.y - headLength * sin(angle - spread))
        let right = CGPoint(x: b.x - headLength * cos(angle + spread),
                            y: b.y - headLength * sin(angle + spread))
        var head = Path()
        head.move(to: left)
        head.addLine(to: b)
        head.addLine(to: right)
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }

    private func point(_ p: CGPoint, _ s: CGFloat) -> CGPoint {
        CGPoint(x: p.x * s, y: p.y * s)
    }

    private func scaled(_ rect: CGRect, _ s: CGFloat) -> CGRect {
        CGRect(x: rect.minX * s, y: rect.minY * s,
               width: rect.width * s, height: rect.height * s)
    }
}

/// Normalised rect from two arbitrary corners (any drag direction).
func markupRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
           width: abs(a.x - b.x), height: abs(a.y - b.y))
}
