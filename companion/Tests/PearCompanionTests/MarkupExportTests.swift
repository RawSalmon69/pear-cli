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
}
