import XCTest
import AppKit
@testable import PearCompanion

/// Window-sizing clamp for the screenshot detail view.
final class ScreenshotDetailLayoutTests: XCTestCase {
    private let visible = NSRect(x: 0, y: 0, width: 1800, height: 1000)

    func testWideImageFitsInsideTheAllowedShare() {
        let size = ScreenshotDetailLayout.windowSize(
            image: NSSize(width: 4000, height: 2000), visible: visible)
        // Image area capped at 70% of the frame minus the sidebar.
        XCTAssertLessThanOrEqual(size.width, visible.width * ScreenshotDetailLayout.fill)
        XCTAssertLessThanOrEqual(size.height, visible.height * ScreenshotDetailLayout.fill)
        XCTAssertGreaterThan(size.width, ScreenshotDetailLayout.sidebarWidth)
    }

    func testTallImageIsHeightBound() {
        let size = ScreenshotDetailLayout.windowSize(
            image: NSSize(width: 800, height: 4000), visible: visible)
        XCTAssertLessThanOrEqual(size.height, visible.height * ScreenshotDetailLayout.fill)
    }

    func testSmallImageStillGetsTheMinimumWindow() {
        let size = ScreenshotDetailLayout.windowSize(
            image: NSSize(width: 120, height: 90), visible: visible)
        XCTAssertEqual(size, ScreenshotDetailLayout.minimum)
    }

    func testDegenerateInputsFallBackToTheMinimum() {
        XCTAssertEqual(
            ScreenshotDetailLayout.windowSize(image: .zero, visible: visible),
            ScreenshotDetailLayout.minimum)
        XCTAssertEqual(
            ScreenshotDetailLayout.windowSize(
                image: NSSize(width: 800, height: 600), visible: .zero),
            ScreenshotDetailLayout.minimum)
    }
}

final class ScreenshotDetailsTests: XCTestCase {
    /// Built through CGContext, not `NSImage.lockFocus`, so the PNG is exactly
    /// the requested pixel size — lockFocus draws at the backing scale (2× on a
    /// Retina test host) and would double the dimensions under test.
    private func png(width: Int, height: Int) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = try XCTUnwrap(context.makeImage())
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testFormatSniffing() throws {
        XCTAssertEqual(ScreenshotDetails.format(sniffing: try png(width: 4, height: 4)), "PNG")
        XCTAssertEqual(
            ScreenshotDetails.format(sniffing: Data([0xFF, 0xD8, 0xFF, 0xE0])), "JPEG")
        XCTAssertEqual(ScreenshotDetails.format(sniffing: Data([0x01, 0x02])), "Image")
        XCTAssertEqual(ScreenshotDetails.format(sniffing: Data()), "Image")
    }

    func testDetailsReadDimensionsAndLabels() throws {
        let data = try png(width: 40, height: 25)
        let when = Date(timeIntervalSince1970: 1_770_000_000)
        let details = ScreenshotDetails.from(
            imageData: data, fileURL: URL(fileURLWithPath: "/tmp/shot.png"), now: when)

        XCTAssertEqual(details.pixelWidth, 40)
        XCTAssertEqual(details.pixelHeight, 25)
        XCTAssertEqual(details.dimensionsLabel, "40 × 25")
        XCTAssertEqual(details.byteCount, data.count)
        XCTAssertEqual(details.format, "PNG")
        XCTAssertEqual(details.path, "/tmp/shot.png")
        XCTAssertFalse(details.sizeLabel.isEmpty)
        XCTAssertFalse(details.timeLabel.isEmpty)
    }

    func testDetailsSurviveUnreadableBytes() {
        let details = ScreenshotDetails.from(imageData: Data([0x00, 0x01]), fileURL: nil)
        XCTAssertEqual(details.pixelWidth, 0)
        XCTAssertEqual(details.dimensionsLabel, "0 × 0")
        XCTAssertNil(details.path)
    }
}

final class DominantColorsTests: XCTestCase {
    /// Two solid halves must come back as two swatches in reading order.
    func testPaletteReadsHorizontalBands() throws {
        let width = 64
        let height = 16
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        let cgImage = try XCTUnwrap(context.makeImage())

        // The resample smooths across the seam, so the bands are dominant rather
        // than pure — assert the dominance, not an exact color.
        let palette = DominantColors.palette(from: cgImage, count: 2)
        XCTAssertEqual(palette.count, 2)
        XCTAssertGreaterThan(palette[0].red, 0.8)
        XCTAssertLessThan(palette[0].blue, 0.2)
        XCTAssertGreaterThan(palette[1].blue, 0.8)
        XCTAssertLessThan(palette[1].red, 0.2)
    }

    func testHexFormatting() {
        XCTAssertEqual(PaletteColor(red: 1, green: 0, blue: 0).hex, "#FF0000")
        XCTAssertEqual(PaletteColor(red: 0, green: 1, blue: 0).hex, "#00FF00")
        XCTAssertEqual(PaletteColor(red: 0, green: 0, blue: 0).hex, "#000000")
        XCTAssertEqual(PaletteColor(red: 1, green: 1, blue: 1).hex, "#FFFFFF")
    }

    func testZeroCountAndGarbageDataYieldNoSwatches() {
        XCTAssertTrue(DominantColors.palette(from: Data([0x00]), count: 6).isEmpty)
    }
}
