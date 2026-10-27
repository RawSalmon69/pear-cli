import XCTest
import AppKit
@testable import PearCompanion

/// Markup's undo/redo over whole-editor snapshots: one stack pair covers
/// annotation edits and crops, which also swap the base image.
final class MarkupHistoryTests: XCTestCase {

    private let base = NSImage(size: NSSize(width: 100, height: 80))

    private func snapshot(_ annotations: [Annotation], image: NSImage? = nil) -> MarkupSnapshot {
        let image = image ?? base
        return MarkupSnapshot(image: image, pixelSize: image.size, pixelated: nil, annotations: annotations)
    }

    private func arrow(_ x: CGFloat) -> Annotation {
        Annotation(kind: .arrow(start: CGPoint(x: x, y: x), end: CGPoint(x: x + 10, y: x),
                                color: .red, width: 4))
    }

    func testUndoRedoRoundTrip() {
        var history = MarkupHistory()
        let empty = snapshot([])
        let one = snapshot([arrow(10)])
        history.record(empty) // drawing the arrow replaces the empty state

        let undone = history.undo(from: one)
        XCTAssertEqual(undone?.annotations.count, 0)
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(history.canRedo)

        let redone = history.redo(from: empty)
        XCTAssertEqual(redone?.annotations.map(\.id), one.annotations.map(\.id))
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    func testNewEditClearsRedo() {
        var history = MarkupHistory()
        history.record(snapshot([]))
        _ = history.undo(from: snapshot([arrow(10)]))
        XCTAssertTrue(history.canRedo)

        history.record(snapshot([]))
        XCTAssertFalse(history.canRedo)
        XCTAssertNil(history.redo(from: snapshot([arrow(20)])))
    }

    func testEmptyStacksReturnNil() {
        var history = MarkupHistory()
        XCTAssertNil(history.undo(from: snapshot([])))
        XCTAssertNil(history.redo(from: snapshot([])))
    }

    func testCropUndoRedoRestoresImageAndAnnotations() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 80, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let original = NSImage(size: NSSize(width: 100, height: 80))
        original.addRepresentation(rep)
        let before = MarkupSnapshot(image: original, pixelSize: original.pixelSize,
                                    pixelated: nil, annotations: [arrow(30)])

        // The editor's crop: record, then swap the image and shift annotations.
        var history = MarkupHistory()
        history.record(before)
        let cropped = try XCTUnwrap(ImageCrop.crop(original, to: CGRect(x: 20, y: 20, width: 50, height: 40)))
        let after = MarkupSnapshot(image: cropped, pixelSize: cropped.pixelSize, pixelated: nil,
                                   annotations: before.annotations.map { $0.translated(by: CGSize(width: -20, height: -20)) })

        let undone = try XCTUnwrap(history.undo(from: after))
        XCTAssertTrue(undone.image === original)
        XCTAssertEqual(undone.pixelSize, CGSize(width: 100, height: 80))
        guard case let .arrow(start, _, _, _) = undone.annotations.first?.kind else { return XCTFail("arrow lost") }
        XCTAssertEqual(start, CGPoint(x: 30, y: 30))

        let redone = try XCTUnwrap(history.redo(from: undone))
        XCTAssertTrue(redone.image === cropped)
        XCTAssertEqual(redone.pixelSize, CGSize(width: 50, height: 40))
        guard case let .arrow(movedStart, _, _, _) = redone.annotations.first?.kind else { return XCTFail("arrow lost") }
        XCTAssertEqual(movedStart, CGPoint(x: 10, y: 10))
    }
}
