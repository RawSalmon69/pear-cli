import XCTest
import AppKit
@testable import PearCompanion

/// Pure geometry behind the crop tool: rect clamping, handle resizing,
/// annotation re-anchoring after a crop, and the image crop's origin (the
/// pixel round-trip that keeps annotations pinned to image content).
final class MarkupCropTests: XCTestCase {

    // MARK: clampCropRect

    func testClampIntersectsBounds() {
        let r = clampCropRect(CGRect(x: -5, y: -5, width: 110, height: 50),
                              to: CGSize(width: 100, height: 80))
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 100, height: 45))
    }

    func testClampRoundsToWholePixels() {
        let r = clampCropRect(CGRect(x: 10.4, y: 20.6, width: 30.2, height: 40.9),
                              to: CGSize(width: 100, height: 100))
        XCTAssertEqual(r, CGRect(x: 10, y: 20, width: 31, height: 42))
    }

    // MARK: CropHandle.resize

    private let rect = CGRect(x: 10, y: 10, width: 80, height: 80)
    private let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

    func testTopLeftHandleMovesTopLeftEdges() {
        let r = CropHandle.topLeft.resize(rect, to: CGPoint(x: 0, y: 0), in: bounds, minSize: 20)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 90, height: 90))
    }

    func testBottomRightHandleClampsToBounds() {
        let r = CropHandle.bottomRight.resize(rect, to: CGPoint(x: 500, y: 500), in: bounds, minSize: 20)
        XCTAssertEqual(r, CGRect(x: 10, y: 10, width: 90, height: 90))
    }

    func testRightHandleMovesOnlyRightEdge() {
        let r = CropHandle.right.resize(rect, to: CGPoint(x: 60, y: 999), in: bounds, minSize: 20)
        XCTAssertEqual(r, CGRect(x: 10, y: 10, width: 50, height: 80))
    }

    func testHandleHonoursMinimumSize() {
        // Dragging the top-left grip past the opposite edge stops at minSize.
        let r = CropHandle.topLeft.resize(rect, to: CGPoint(x: 95, y: 95), in: bounds, minSize: 20)
        XCTAssertEqual(r, CGRect(x: 70, y: 70, width: 20, height: 20))
    }

    // MARK: Annotation.translated

    func testArrowTranslates() {
        let a = Annotation(kind: .arrow(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 20, y: 30),
                                        color: .red, width: 4))
        guard case let .arrow(start, end, _, _) = a.translated(by: CGSize(width: -5, height: -3)).kind else {
            return XCTFail("kind changed")
        }
        XCTAssertEqual(start, CGPoint(x: 5, y: 7))
        XCTAssertEqual(end, CGPoint(x: 15, y: 27))
    }

    func testRectangleAndBlurTranslate() {
        let rectAnn = Annotation(kind: .rectangle(rect: CGRect(x: 10, y: 10, width: 40, height: 40),
                                                  color: .blue, width: 2))
        guard case let .rectangle(r, _, _) = rectAnn.translated(by: CGSize(width: -5, height: -3)).kind else {
            return XCTFail("kind changed")
        }
        XCTAssertEqual(r, CGRect(x: 5, y: 7, width: 40, height: 40))

        let blur = Annotation(kind: .blur(rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
        guard case let .blur(br) = blur.translated(by: CGSize(width: 4, height: 6)).kind else {
            return XCTFail("kind changed")
        }
        XCTAssertEqual(br, CGRect(x: 4, y: 6, width: 10, height: 10))
    }

    func testFreehandAndTextTranslate() {
        let fh = Annotation(kind: .freehand(points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)],
                                            color: .green, width: 3))
        guard case let .freehand(points, _, _) = fh.translated(by: CGSize(width: 2, height: 3)).kind else {
            return XCTFail("kind changed")
        }
        XCTAssertEqual(points, [CGPoint(x: 2, y: 3), CGPoint(x: 12, y: 13)])

        let text = Annotation(kind: .text(origin: CGPoint(x: 5, y: 5), string: "hi",
                                          color: .white, fontSize: 20))
        guard case let .text(origin, string, _, _) = text.translated(by: CGSize(width: -5, height: -5)).kind else {
            return XCTFail("kind changed")
        }
        XCTAssertEqual(origin, CGPoint(x: 0, y: 0))
        XCTAssertEqual(string, "hi")
    }

    func testTranslatePreservesIdentity() {
        let a = Annotation(kind: .blur(rect: CGRect(x: 0, y: 0, width: 5, height: 5)))
        XCTAssertEqual(a.id, a.translated(by: CGSize(width: 1, height: 1)).id)
    }

    // MARK: ImageCrop origin

    /// Top half red, bottom half blue (top-left origin). Cropping the top
    /// 100×50 must yield red — if the crop read from the bottom, this fails,
    /// which would mean annotations and pixels disagree after a crop.
    func testCropKeepsTopLeftOrigin() throws {
        // Draw in flipped (top-left origin) space, matching annotation space
        // and how the editor renders the base image.
        let source = NSImage(size: NSSize(width: 100, height: 100))
        source.lockFocusFlipped(true)
        NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 100, height: 50).fill()   // top
        NSColor.blue.setFill(); NSRect(x: 0, y: 50, width: 100, height: 50).fill() // bottom
        source.unlockFocus()

        let cropped = try XCTUnwrap(ImageCrop.crop(source, to: CGRect(x: 0, y: 0, width: 100, height: 50)))
        XCTAssertEqual(cropped.pixelSize, CGSize(width: 100, height: 50))

        let outRep = try XCTUnwrap(NSBitmapImageRep(data: cropped.tiffRepresentation!))
        let sample = try XCTUnwrap(outRep.colorAt(x: 50, y: 25)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(sample.redComponent, 0.8)
        XCTAssertLessThan(sample.blueComponent, 0.2)
    }
}
