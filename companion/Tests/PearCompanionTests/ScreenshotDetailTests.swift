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

    private func details(width: Int, height: Int, dpi: Int = 72) -> ScreenshotDetails {
        ScreenshotDetails(
            pixelWidth: width, pixelHeight: height, byteCount: 1000, format: "PNG",
            capturedAt: Date(timeIntervalSince1970: 0), path: nil, colorProfile: "sRGB",
            bitsPerComponent: 8, hasAlpha: false, dpi: dpi)
    }

    func testAspectRatioReducesWhenRecognizableAndFallsBackToDecimal() {
        XCTAssertEqual(details(width: 1920, height: 1080).aspectLabel, "16:9")
        XCTAssertEqual(details(width: 2560, height: 1600).aspectLabel, "16:10")
        XCTAssertEqual(details(width: 100, height: 100).aspectLabel, "1:1")
        // Reduces to 1234:713 — exact and useless, so a decimal is shown.
        XCTAssertEqual(details(width: 1234, height: 713).aspectLabel, "1.73:1")
        XCTAssertNil(details(width: 0, height: 0).aspectLabel)
    }

    func testMegapixelsAndRetinaScale() {
        XCTAssertEqual(details(width: 2560, height: 1600).megapixelsLabel, "4.1 MP")
        XCTAssertEqual(details(width: 6016, height: 3384).megapixelsLabel, "20 MP")
        XCTAssertNil(details(width: 40, height: 25).megapixelsLabel)

        XCTAssertEqual(details(width: 100, height: 100, dpi: 144).scaleLabel, "@2x")
        XCTAssertNil(details(width: 100, height: 100, dpi: 72).scaleLabel, "1x needs no badge")
    }

    func testColorLabelDegradesWhenTheFileSaysNothing() {
        XCTAssertEqual(details(width: 10, height: 10).colorLabel, "sRGB · 8-bit")
        let bare = ScreenshotDetails(
            pixelWidth: 10, pixelHeight: 10, byteCount: 1, format: "PNG",
            capturedAt: Date(timeIntervalSince1970: 0), path: nil, colorProfile: nil,
            bitsPerComponent: 0, hasAlpha: false, dpi: 0)
        XCTAssertNil(bare.colorLabel)
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

    /// Swatches are `PickedColor`s — the same type the eyedropper tool
    /// produces — so they copy in whatever format the user picked.
    func testSwatchesAreOrdinaryPickedColors() {
        XCTAssertEqual(PickedColor(red: 1, green: 0, blue: 0).hexString, "#FF0000")
        XCTAssertEqual(ColorFormat.rgb.value(for: PickedColor(red: 1, green: 1, blue: 1)),
                       "rgb(255, 255, 255)")
    }

    func testZeroCountAndGarbageDataYieldNoSwatches() {
        XCTAssertTrue(DominantColors.palette(from: Data([0x00]), count: 6).isEmpty)
    }
}

/// The detail view's eyedropper: a point in image pixel space, a color out.
final class PixelSamplerTests: XCTestCase {
    /// 2×2 image: red top-left, green top-right, blue bottom-left, white
    /// bottom-right. Sampling must respect top-left origin, not AppKit's
    /// bottom-left one.
    private func quadrants() throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        // CGContext origin is bottom-left, so the "top" row is drawn last.
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 1, width: 1, height: 1))
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
        return try XCTUnwrap(context.makeImage())
    }

    func testSamplesEachPixelByTopLeftCoordinates() throws {
        let image = try quadrants()
        XCTAssertEqual(PixelSampler.color(in: image, atX: 0, y: 0)?.hexString, "#FF0000")
        XCTAssertEqual(PixelSampler.color(in: image, atX: 1, y: 0)?.hexString, "#00FF00")
        XCTAssertEqual(PixelSampler.color(in: image, atX: 0, y: 1)?.hexString, "#0000FF")
        XCTAssertEqual(PixelSampler.color(in: image, atX: 1, y: 1)?.hexString, "#FFFFFF")
    }

    func testOutOfBoundsSamplesAreRejected() throws {
        let image = try quadrants()
        XCTAssertNil(PixelSampler.color(in: image, atX: -1, y: 0))
        XCTAssertNil(PixelSampler.color(in: image, atX: 0, y: 2))
        XCTAssertNil(PixelSampler.color(in: image, atX: 99, y: 99))
    }
}
