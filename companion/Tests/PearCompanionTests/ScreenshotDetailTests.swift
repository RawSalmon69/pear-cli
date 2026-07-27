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
        let url = try CaptureFixture.write(png)
        defer { CaptureFixture.remove(url) }
        let insights = ScreenshotInsights(url: url)

        insights.scan()

        // Synchronously after scan(): nothing recognized yet, but the window
        // already has details to draw and a scanning state to show.
        XCTAssertTrue(insights.isScanning)
        XCTAssertTrue(insights.text.isEmpty)
        XCTAssertTrue(insights.payloads.isEmpty)
        XCTAssertGreaterThan(insights.details.pixelWidth, 0)
        XCTAssertEqual(insights.details.format, "PNG")
    }

    /// Scanning reads the capture off disk now, so the file can be gone by the
    /// time the pass runs. It must finish empty, not trap.
    func testScanningAMissingFileFinishesEmpty() async throws {
        let png = try XCTUnwrap(QRCode.generate(from: "https://example.com")?.pngData())
        let url = try CaptureFixture.write(png)
        CaptureFixture.remove(url)
        let insights = ScreenshotInsights(url: url)

        insights.scan()
        // Proves the pass really ran (and then found nothing) rather than the
        // empties below being the untouched initial state.
        XCTAssertTrue(insights.isScanning)
        var waited = 0
        while insights.isScanning, waited < 100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }

        XCTAssertFalse(insights.isScanning, "scan never finished")
        XCTAssertTrue(insights.text.isEmpty)
        XCTAssertTrue(insights.payloads.isEmpty)
        XCTAssertTrue(insights.colors.isEmpty)
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

    func testFormatFromImageIOType() {
        XCTAssertEqual(ScreenshotDetails.format(uti: "public.png"), "PNG")
        XCTAssertEqual(ScreenshotDetails.format(uti: "public.jpeg"), "JPEG")
        XCTAssertEqual(ScreenshotDetails.format(uti: "com.compuserve.gif"), "Image")
        XCTAssertEqual(ScreenshotDetails.format(uti: nil), "Image")
    }

    func testDetailsReadDimensionsAndLabels() throws {
        let data = try png(width: 40, height: 25)
        let url = try CaptureFixture.write(data)
        defer { CaptureFixture.remove(url) }
        let when = Date(timeIntervalSince1970: 1_770_000_000)
        let details = ScreenshotDetails.from(url: url, now: when)

        XCTAssertEqual(details.pixelWidth, 40)
        XCTAssertEqual(details.pixelHeight, 25)
        XCTAssertEqual(details.dimensionsLabel, "40 × 25")
        // Read off the file, not a `Data` the card is holding on to.
        XCTAssertEqual(details.byteCount, data.count)
        XCTAssertEqual(details.format, "PNG")
        XCTAssertEqual(details.path, url.path)
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

    func testDetailsSurviveUnreadableBytes() throws {
        let url = try CaptureFixture.write(Data([0x00, 0x01]))
        defer { CaptureFixture.remove(url) }
        let details = ScreenshotDetails.from(url: url)
        XCTAssertEqual(details.pixelWidth, 0)
        XCTAssertEqual(details.dimensionsLabel, "0 × 0")
        XCTAssertEqual(details.format, "Image")
    }

    /// A card can outlive its file. Reading one that has gone must come back
    /// empty rather than trap — the caller then dismisses the card.
    func testDetailsSurviveAMissingFile() {
        let gone = FileManager.default.temporaryDirectory
            .appendingPathComponent("PearMissing-\(UUID().uuidString).png")
        let details = ScreenshotDetails.from(url: gone)
        XCTAssertEqual(details.pixelWidth, 0)
        XCTAssertEqual(details.byteCount, 0)
        XCTAssertEqual(details.format, "Image")
        XCTAssertNil(CaptureImage.decode(at: gone))
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

/// The zoom state machine's one piece of arithmetic. It shipped unfitted with a
/// missing upscale cap, which also broke double-click-to-toggle on small grabs.
final class ZoomFitTargetTests: XCTestCase {
    private func fit(viewport: CGSize, document: CGSize) -> CGFloat? {
        ZoomableImageScrollView.fitTarget(viewport: viewport, document: document)
    }

    func testLargeCaptureScalesDownToFit() throws {
        let target = try XCTUnwrap(fit(viewport: CGSize(width: 460, height: 436),
                                      document: CGSize(width: 6016, height: 3384)))
        XCTAssertEqual(target, 460.0 / 6016.0, accuracy: 0.0001)
        XCTAssertLessThan(target, 1, "a 6K shot must be scaled down, not up")
    }

    func testTightDimensionWins() throws {
        // Tall document: the height ratio is the binding constraint.
        let target = try XCTUnwrap(fit(viewport: CGSize(width: 800, height: 200),
                                      document: CGSize(width: 1000, height: 4000)))
        XCTAssertEqual(target, 200.0 / 4000.0, accuracy: 0.0001)
    }

    func testTinyCaptureIsNeverUpscaled() {
        // A 30×30 region grab used to fill the window at ~1450%.
        XCTAssertEqual(fit(viewport: CGSize(width: 460, height: 436),
                           document: CGSize(width: 30, height: 30)), 1)
    }

    func testFitStaysBelowMaxMagnificationSoDoubleClickToggleWorks() throws {
        // With an unclamped fit, `fitMagnification` (21.8) exceeded the 16×
        // ceiling `setMagnification` clamps to, so `magnification >
        // fitMagnification * 1.05` was permanently false and double-click could
        // never return to fit.
        let target = try XCTUnwrap(fit(viewport: CGSize(width: 436, height: 436),
                                      document: CGSize(width: 20, height: 20)))
        XCTAssertLessThanOrEqual(target, 16)
    }

    func testDegenerateSizesYieldNoTarget() {
        XCTAssertNil(fit(viewport: CGSize(width: 460, height: 436),
                         document: CGSize(width: 0, height: 100)))
        XCTAssertNil(fit(viewport: CGSize(width: 460, height: 436),
                         document: CGSize(width: 100, height: 0)))
        XCTAssertNil(fit(viewport: .zero, document: CGSize(width: 100, height: 100)))
    }
}

/// The live zoom state machine, driven the way AppKit drives it. `fitTarget` is
/// pure arithmetic and was already covered; what was NOT covered is when the
/// auto-fit is allowed to run, which is where "my zoom doesn't stick" lives.
@MainActor
final class ZoomStateMachineTests: XCTestCase {
    private func scrollView(document: NSSize, viewport: NSSize) -> ZoomableImageScrollView {
        let scrollView = ZoomableImageScrollView(frame: NSRect(origin: .zero, size: viewport))
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = NSView(frame: NSRect(origin: .zero, size: document))
        scrollView.allowsMagnification = true
        scrollView.maxMagnification = 16
        return scrollView
    }

    /// `layout()` defers its fit by a runloop turn, so the test has to let that
    /// turn happen before asserting.
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    func testFirstLayoutFitsTheImage() {
        let scrollView = self.scrollView(document: NSSize(width: 6016, height: 3384),
                                        viewport: NSSize(width: 1200, height: 700))
        scrollView.layout()
        settle()

        XCTAssertEqual(scrollView.magnification, 1200.0 / 6016.0, accuracy: 0.001)
    }

    /// ⌘-scroll and two-finger magnify-by-scroll do NOT go through
    /// `magnify(with:)` — AppKit changes `magnification` from `scrollWheel`. So
    /// nothing marks the zoom as user-owned, and the next layout pass throws it
    /// away. From the user's side the gesture simply does not take.
    func testACommandScrollZoomSurvivesTheNextLayoutPass() {
        let scrollView = self.scrollView(document: NSSize(width: 6016, height: 3384),
                                        viewport: NSSize(width: 1200, height: 700))
        scrollView.layout()
        settle()

        scrollView.magnification = 1.0 // what ⌘-scroll leaves behind
        scrollView.layout()
        settle()

        XCTAssertEqual(scrollView.magnification, 1.0, accuracy: 0.001,
                       "a zoom the user asked for must not be undone by a relayout")
    }

    /// The ownership guard specifically: a resize is a real geometry change, so
    /// the geometry guard lets it through, and only "does the magnification still
    /// match the fit we applied?" stops the user's scroll zoom being discarded.
    func testAResizeDoesNotUndoAScrollWheelZoom() {
        let scrollView = self.scrollView(document: NSSize(width: 6016, height: 3384),
                                        viewport: NSSize(width: 1200, height: 700))
        scrollView.layout()
        settle()

        scrollView.magnification = 1.0 // ⌘-scroll, never sees magnify(with:)
        scrollView.setFrameSize(NSSize(width: 1000, height: 600))
        scrollView.layout()
        settle()

        XCTAssertEqual(scrollView.magnification, 1.0, accuracy: 0.001,
                       "resizing the window must not discard a deliberate zoom")
    }

    /// The other side of that guard: while the user has NOT zoomed, a resize
    /// should still re-fit. This is the behaviour the guards must not break.
    func testAResizeStillRefitsWhenTheUserHasNotZoomed() {
        let scrollView = self.scrollView(document: NSSize(width: 6016, height: 3384),
                                        viewport: NSSize(width: 1200, height: 700))
        scrollView.layout()
        settle()

        scrollView.setFrameSize(NSSize(width: 600, height: 350))
        scrollView.layout()
        settle()

        XCTAssertEqual(scrollView.magnification, 600.0 / 6016.0, accuracy: 0.001,
                       "an unzoomed image should keep fitting the window")
    }

    /// A layout pass with unchanged geometry has no fitting to do. Re-fitting
    /// anyway calls back into the controller, which invalidates the SwiftUI body
    /// that owns the readout, which lays out again.
    func testRepeatedLayoutAtTheSameSizeDoesNotKeepRefitting() {
        let scrollView = self.scrollView(document: NSSize(width: 6016, height: 3384),
                                        viewport: NSSize(width: 1200, height: 700))
        scrollView.layout()
        settle()
        let fits = scrollView.fitCount

        for _ in 0..<5 {
            scrollView.layout()
            settle()
        }

        XCTAssertEqual(scrollView.fitCount, fits, "nothing changed; nothing to re-fit")
    }
}

/// How the HD background-removal model is loaded. Measured on an M-series Mac:
/// `MLModel.compileModel` takes 0.24s and writes a fresh **196 MB** copy into
/// the temp directory on EVERY call, while reloading an already-compiled
/// directory takes 0.08s. So the compile is cached on disk and the loaded model
/// is never retained between cutouts.
@MainActor
final class HDModelLoadingTests: XCTestCase {
    func testPreparingNeverLoadsOrCompiles() {
        let manager = HDBackgroundModelManager.shared

        manager.prepare()

        XCTAssertNotEqual(manager.state, .preparing,
                          "launch must only stat the model, never compile or load it")
        XCTAssertTrue(manager.state == .ready || manager.state == .absent,
                      "unexpected state after prepare(): \(manager.state)")
    }

    /// Skipped where the model was never downloaded (CI). Where it is present,
    /// this is the anti-litter guarantee: two cutouts must not leave two 196 MB
    /// compiled copies behind in the temp directory.
    func testTheCompileIsCachedSoNoTempCopiesAccumulate() async throws {
        let manager = HDBackgroundModelManager.shared
        try XCTSkipUnless(manager.isDownloaded, "HD model not downloaded on this machine")
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Prefs.hdBackgroundRemovalKey)
        defaults.set(true, forKey: Prefs.hdBackgroundRemovalKey)
        defer {
            if let previous { defaults.set(previous, forKey: Prefs.hdBackgroundRemovalKey) }
            else { defaults.removeObject(forKey: Prefs.hdBackgroundRemovalKey) }
        }

        let before = Self.tempCompiledCopies()
        let first = await manager.prepared()
        let second = await manager.prepared()

        XCTAssertNotNil(first, "the model is on disk and enabled; it must load")
        XCTAssertNotNil(second)
        XCTAssertFalse(first === second, "each cutout gets its own instance, so ARC can free it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.compiledDir.path),
                      "the compile must be cached beside the download")
        XCTAssertEqual(Self.tempCompiledCopies(), before,
                       "a cached compile must not write another 196 MB copy into /tmp")
    }

    private static func tempCompiledCopies() -> Int {
        let temp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        return names.filter { $0.hasSuffix(".mlmodelc") }.count
    }
}
