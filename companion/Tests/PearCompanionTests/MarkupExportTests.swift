import XCTest
import AppKit
@testable import PearCompanion

/// What Markup hands back must match what it showed and where it showed it:
/// the window on the clicked screen, the arrowheads as previewed, and the
/// capture's dpi kept through the edit.
final class MarkupExportTests: XCTestCase {

    // MARK: Window placement

    func testCentredSitsInTheMiddleOfAnExternalScreen() {
        // An external display to the right of a 1440-wide laptop.
        let visible = NSRect(x: 1440, y: 0, width: 2560, height: 1415)
        let origin = MarkupWindowController.centred(size: NSSize(width: 1000, height: 600), in: visible)
        XCTAssertEqual(origin, NSPoint(x: 1440 + 780, y: 407.5))
    }

    func testContentSizeFitsTheGivenScreenNotAnother() {
        let small = NSSize(width: 1440, height: 875)
        let size = MarkupWindowController.initialContentSize(pixels: CGSize(width: 5120, height: 2880),
                                                            visible: small)
        XCTAssertLessThanOrEqual(size.width, small.width)
        XCTAssertLessThanOrEqual(size.height, small.height)
    }

    // MARK: Arrowheads

    func testArrowHeadMatchesBetweenPreviewAndExport() {
        // A thin arrow, where the floor decides. In image pixels the head must
        // be the same size at the live fit (0.25) and at export (1).
        let width: CGFloat = 1
        let preview: CGFloat = 0.25
        let live = arrowHeadLength(lineWidth: width * preview, scale: preview) / preview
        let export = arrowHeadLength(lineWidth: width * 1, scale: 1) / 1
        XCTAssertEqual(live, export, accuracy: 0.0001)
    }

    func testArrowHeadFollowsStrokeAboveTheFloor() {
        XCTAssertEqual(arrowHeadLength(lineWidth: 10, scale: 1), 45)
    }

    // MARK: dpi

    func testPointSizeKeepsRetinaRatioThroughACrop() {
        let size = markupPointSize(pixels: CGSize(width: 300, height: 100),
                                   sourcePixels: CGSize(width: 1000, height: 800),
                                   sourcePoints: CGSize(width: 500, height: 400))
        XCTAssertEqual(size, CGSize(width: 150, height: 50))
    }

    func testPointSizeFallsBackToPixelsForAnEmptySource() {
        let size = markupPointSize(pixels: CGSize(width: 30, height: 10),
                                   sourcePixels: .zero, sourcePoints: .zero)
        XCTAssertEqual(size, CGSize(width: 30, height: 10))
    }

    func testRetinaShotComesOutOfMarkupAt144Dpi() throws {
        // A 144-dpi PNG: 40×20 pixels tagged as 20×10 points.
        let source = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        source.size = NSSize(width: 20, height: 10)
        let png = try XCTUnwrap(source.representation(using: .png, properties: [:]))
        let image = try XCTUnwrap(NSImage(data: png))

        // The export path: a pixel-sized render (as ImageRenderer at scale 1
        // produces, so 72 dpi on its own), wrapped at the source's ratio.
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rendered = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let unfixed = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(rendered.pngData())))
        XCTAssertEqual(unfixed.size.width, 40, "the bug: a scale-1 render encodes at 72 dpi")
        let flat = try XCTUnwrap(rendered.keepingScale(sourcePixels: image.pixelSize,
                                                       sourcePoints: image.size))
        let out = try XCTUnwrap(flat.pngData())

        let rep = try XCTUnwrap(NSBitmapImageRep(data: out))
        XCTAssertEqual(rep.pixelsWide, 40)
        XCTAssertEqual(rep.size.width, 20, "pixels / points = 2 → 144 dpi")
        XCTAssertEqual(rep.size.height, 10)
    }
}
