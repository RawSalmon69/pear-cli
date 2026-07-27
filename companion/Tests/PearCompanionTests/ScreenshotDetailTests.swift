import XCTest
import AppKit
import Vision
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

@MainActor
final class ScreenshotInsightsNonBlockingTests: XCTestCase {
    /// The detail window must open mid-scan. `scan()` therefore has to return
    /// to its caller immediately, leaving the sections to fill in later — this
    /// is the invariant behind "I can open the big view before it's done".
    func testScanReturnsImmediatelyAndDetailsAreReadyFirst() throws {
        let png = try XCTUnwrap(QRCode.generate(from: "https://example.com")?.pngData())
        let insights = ScreenshotInsights(imageData: png, fileURL: nil)

        insights.scan()

        // Synchronously after scan(): nothing recognized yet, but the window
        // already has details to draw and a scanning state to show.
        XCTAssertTrue(insights.isScanning)
        XCTAssertTrue(insights.text.isEmpty)
        XCTAssertTrue(insights.payloads.isEmpty)
        XCTAssertGreaterThan(insights.details.pixelWidth, 0)
        XCTAssertEqual(insights.details.format, "PNG")
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

/// Vision's default `recognitionLanguages` is `["en_US"]`, which returns
/// *nothing at all* for Thai, Japanese, Korean, or Chinese — measured on
/// macOS 26, Vision revision 3. `OCRText` therefore sets
/// `automaticallyDetectsLanguage`, and this pins it: delete that line and these
/// fail. A narrow explicit language list is deliberately NOT used — it drops
/// scripts outside the list (also measured).
final class OCRLanguageTests: XCTestCase {
    private func render(_ text: String) throws -> CGImage {
        let size = NSSize(width: 900, height: 200)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 64),
            .foregroundColor: NSColor.black,
        ]).draw(at: NSPoint(x: 20, y: 60))
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(context.makeImage())
    }

    private func skipUnlessSupported(_ language: String) throws {
        let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .accurate, revision: VNRecognizeTextRequest.currentRevision)) ?? []
        try XCTSkipUnless(
            supported.contains(language),
            "\(language) recognition unavailable on this host")
    }

    func testRecognizesThai() throws {
        try skipUnlessSupported("th-TH")
        let text = OCRText.recognize(in: try render("สวัสดีครับ"))
        XCTAssertTrue(text.contains("สวัสดี"), "expected Thai text, got \(text.debugDescription)")
    }

    func testRecognizesJapanese() throws {
        try skipUnlessSupported("ja-JP")
        let text = OCRText.recognize(in: try render("こんにちは"))
        XCTAssertFalse(text.isEmpty, "Japanese came back empty")
    }

    /// Scripts mixed in one shot must all survive — the common case for a
    /// screenshot of a localized UI.
    func testRecognizesMixedScripts() throws {
        try skipUnlessSupported("th-TH")
        let text = OCRText.recognize(in: try render("Hello สวัสดี"))
        XCTAssertTrue(text.contains("Hello"), "lost the English half: \(text.debugDescription)")
        XCTAssertTrue(text.contains("สวัสดี"), "lost the Thai half: \(text.debugDescription)")
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
