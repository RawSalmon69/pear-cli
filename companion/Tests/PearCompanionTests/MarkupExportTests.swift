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

}
