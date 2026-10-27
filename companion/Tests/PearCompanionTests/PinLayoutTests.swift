import XCTest
import AppKit
@testable import PearCompanion

/// Initial frame of a pinned capture: on-screen size, shrunk to fit with the
/// aspect kept, centred, and cascaded so a second pin does not hide the first.
final class PinLayoutTests: XCTestCase {
    private let visible = NSRect(x: 100, y: 50, width: 1600, height: 1000)

    func testRetinaCaptureOpensAtItsOnScreenSize() {
        let frame = PinLayout.frame(pixels: NSSize(width: 800, height: 600), scale: 2,
                                    visible: visible, cascade: 0)
        XCTAssertEqual(frame.size, NSSize(width: 400, height: 300))
    }

    func testLargeCaptureFitsTheScreenWithAspectKept() {
        let pixels = NSSize(width: 6000, height: 2000)
        let frame = PinLayout.frame(pixels: pixels, scale: 1, visible: visible, cascade: 0)
        XCTAssertLessThanOrEqual(frame.width, visible.width * PinLayout.fill + 0.5)
        XCTAssertLessThanOrEqual(frame.height, visible.height * PinLayout.fill + 0.5)
        XCTAssertEqual(frame.width / frame.height, 3, accuracy: 0.01)
        XCTAssertTrue(visible.contains(frame))
    }

    func testFirstPinIsCentredAndLaterOnesCascadeOnScreen() {
        let pixels = NSSize(width: 400, height: 300)
        let first = PinLayout.frame(pixels: pixels, scale: 1, visible: visible, cascade: 0)
        XCTAssertEqual(first.midX, visible.midX, accuracy: 0.5)
        XCTAssertEqual(first.midY, visible.midY, accuracy: 0.5)
        let second = PinLayout.frame(pixels: pixels, scale: 1, visible: visible, cascade: 1)
        XCTAssertNotEqual(second.origin, first.origin)
        let big = PinLayout.frame(pixels: NSSize(width: 9000, height: 9000), scale: 1,
                                  visible: visible, cascade: 7)
        XCTAssertTrue(visible.contains(big))
    }

    func testMinimumSizeKeepsAspectAndNeverExceedsThePin() {
        let min = PinLayout.minimumSize(for: NSSize(width: 800, height: 400))
        XCTAssertEqual(min.width / min.height, 2, accuracy: 0.01)
        XCTAssertEqual(PinLayout.minimumSize(for: NSSize(width: 30, height: 20)),
                       NSSize(width: 30, height: 20))
    }

    func testCloseButtonSitsTopLeftAndHidesOnPinsTooSmallForIt() {
        let button = CGSize(width: 18, height: 18)
        let inset = Theme.Space.small
        let frame = PinLayout.closeButtonFrame(in: CGRect(x: 0, y: 0, width: 400, height: 300),
                                               button: button)
        XCTAssertEqual(frame, CGRect(x: inset, y: 300 - inset - 18, width: 18, height: 18))
        // A thin strip at the minimum size has no room: it stays all drag surface.
        XCTAssertNil(PinLayout.closeButtonFrame(in: CGRect(x: 0, y: 0, width: 80, height: 20),
                                                button: button))
        XCTAssertNotNil(PinLayout.closeButtonFrame(
            in: CGRect(x: 0, y: 0, width: 18 + 2 * inset, height: 18 + 2 * inset), button: button))
    }

    func testDegenerateInputsStillGiveAUsableFrame() {
        let frame = PinLayout.frame(pixels: .zero, scale: 0, visible: visible, cascade: 0)
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
    }
}
