import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PearCompanion

/// The HD matte compositing, without the model: a matte applied to a generated
/// image, encoded and read back the way any app reading the PNG would.
final class HDMatteCompositeTests: XCTestCase {
    /// A solid `width`×`height` opaque image of `rgb` in `space`.
    private func solid(_ rgb: (CGFloat, CGFloat, CGFloat), width: Int = 4, height: Int = 4,
                       space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(colorSpace: space, components: [rgb.0, rgb.1, rgb.2, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func pixel(of png: Data, x: Int = 0, y: Int = 0) throws -> [Int] {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        var px = [Int](repeating: 0, count: 4)
        rep.getPixel(&px, atX: x, y: y)
        return px
    }

    /// The halo bug: the matte went into the alpha byte of a PREMULTIPLIED
    /// buffer with RGB left alone, so the encoder un-premultiplied
    /// (100,50,30)@63 into (255,202,121). Every channel must scale by the matte.
    func testMattePremultipliesEveryChannel() {
        var px: [UInt8] = [100, 50, 30, 255]
        px.withUnsafeMutableBufferPointer {
            BEN2Model.applyMatte([63.0 / 255], side: 1, to: $0.baseAddress!, width: 1, height: 1, bytesPerRow: 4)
        }
        XCTAssertEqual(px, [25, 12, 7, 63])
    }

    /// A source pixel that was already partly transparent keeps that: the
    /// matte multiplies the existing alpha rather than replacing it.
    func testMatteMultipliesExistingAlpha() {
        var px: [UInt8] = [50, 0, 0, 128] // premultiplied 100 @ ~half
        px.withUnsafeMutableBufferPointer {
            BEN2Model.applyMatte([0.5], side: 1, to: $0.baseAddress!, width: 1, height: 1, bytesPerRow: 4)
        }
        XCTAssertEqual(px, [25, 0, 0, 64])
    }

    func testHalfMatteColourSurvivesThePNGRoundTrip() throws {
        let image = try solid((100 / 255, 50 / 255, 30 / 255))
        let matte = [Float](repeating: 63.0 / 255, count: 4)
        let png = try XCTUnwrap(BEN2Model.composite(cg: image, matte: matte, maskSide: 2, dpi: [:]))
        let px = try pixel(of: png, x: 1, y: 1)
        XCTAssertEqual(px[3], 63)
        for (got, want) in zip(px.prefix(3), [100, 50, 30]) {
            XCTAssertEqual(got, want, accuracy: 4, "colour washed out: \(px)")
        }
    }

    // MARK: Bilinear sampling (the blocky-edge bug: nearest-neighbour upsampling)

    func testSampleIsLinearBetweenNeighbours() {
        let matte: [Float] = [0, 1,
                              0, 1]
        XCTAssertEqual(BEN2Model.sample(matte, side: 2, x: 0.5, y: 0), 0.5, accuracy: 1e-6)
        XCTAssertEqual(BEN2Model.sample(matte, side: 2, x: 0.25, y: 0.5), 0.25, accuracy: 1e-6)
    }

    func testSampleClampsAtTheEdges() {
        let matte: [Float] = [0.2, 0.8,
                              0.2, 0.8]
        XCTAssertEqual(BEN2Model.sample(matte, side: 2, x: -3, y: -3), 0.2, accuracy: 1e-6)
        XCTAssertEqual(BEN2Model.sample(matte, side: 2, x: 5, y: 5), 0.8, accuracy: 1e-6)
    }

    /// Upsampling a 2-wide hard step to 8 wide gives a ramp, not a 4|4 block.
    func testUpsampledStepIsARampNotABlock() {
        var px = [UInt8](repeating: 255, count: 8 * 4)
        px.withUnsafeMutableBufferPointer {
            BEN2Model.applyMatte([0, 1, 0, 1], side: 2, to: $0.baseAddress!, width: 8, height: 1, bytesPerRow: 32)
        }
        let alphas = stride(from: 3, to: px.count, by: 4).map { px[$0] }
        XCTAssertEqual(alphas.first, 0)
        XCTAssertEqual(alphas.last, 255)
        XCTAssertEqual(alphas, alphas.sorted(), "alpha must rise monotonically: \(alphas)")
        XCTAssertGreaterThan(Set(alphas).count, 4, "a ramp has intermediate steps: \(alphas)")
    }

    // MARK: Colour space (P3 used to be clipped to Device RGB)

    func testOutputKeepsTheSourceColourSpace() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let image = try solid((0, 1, 0), space: p3)
        let png = try XCTUnwrap(BEN2Model.composite(cg: image, matte: [1], maskSide: 1, dpi: [:]))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let out = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(out.colorSpace?.name, CGColorSpace.displayP3)
    }
}

/// Decode and encode shared by the Vision and HD cutouts: orientation and DPI
/// must survive, or a phone photo comes out sideways and a Retina capture
/// pastes at twice its size.
final class BackgroundRemovalIOTests: XCTestCase {
    private func encode(width: Int, height: Int, as type: UTType,
                        properties: [CFString: Any]) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func dpiWidth(of png: Data) -> Double? {
        let source = CGImageSourceCreateWithData(png as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
    }

    func testDecodeAppliesTheEXIFOrientation() throws {
        let jpeg = try encode(width: 40, height: 20, as: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let decoded = try XCTUnwrap(BackgroundRemovalService.decode(jpeg))
        XCTAssertEqual(decoded.image.width, 20)
        XCTAssertEqual(decoded.image.height, 40)
    }

    func testDecodeLeavesAnUprightImageAtFullSize() throws {
        let png = try encode(width: 40, height: 20, as: .png, properties: [:])
        let decoded = try XCTUnwrap(BackgroundRemovalService.decode(png))
        XCTAssertEqual(decoded.image.width, 40)
        XCTAssertEqual(decoded.image.height, 20)
    }

    func testDPICarriesFromSourceToCutoutPNG() throws {
        let source = try encode(width: 8, height: 8, as: .png,
                                properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
        let decoded = try XCTUnwrap(BackgroundRemovalService.decode(source))
        let png = try XCTUnwrap(BackgroundRemovalService.png(decoded.image, dpi: decoded.dpi))
        XCTAssertEqual(try XCTUnwrap(dpiWidth(of: png)), 144, accuracy: 0.5)
    }

    func testHDCompositeKeepsTheDPI() throws {
        let source = try encode(width: 8, height: 8, as: .png,
                                properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
        let decoded = try XCTUnwrap(BackgroundRemovalService.decode(source))
        let png = try XCTUnwrap(BEN2Model.composite(cg: decoded.image, matte: [1], maskSide: 1, dpi: decoded.dpi))
        XCTAssertEqual(try XCTUnwrap(dpiWidth(of: png)), 144, accuracy: 0.5)
    }
}

/// The HD model download's transfer, driven offline only (a `file:` URL), so
/// no test ever fetches the model.
final class ModelDownloadCancelTests: XCTestCase {
    private func run(_ delegate: DownloadProgressDelegate, _ url: URL) async -> Result<URL, Error> {
        await withCheckedContinuation { cont in delegate.start(url) { cont.resume(returning: $0) } }
    }

    /// Remove before the transfer starts: it fails at once, never connecting.
    func testCancelBeforeStartFailsWithoutStarting() async {
        let delegate = DownloadProgressDelegate(progress: { _ in })
        delegate.cancel()
        let result = await run(delegate, URL(string: "https://example.invalid/never")!)
        guard case .failure(let error) = result else { return XCTFail("a cancelled download must not start") }
        XCTAssertTrue(error is CancellationError, "\(error)")
    }

    func testCancelAfterFinishingIsHarmless() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        try Data("weights".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let delegate = DownloadProgressDelegate(progress: { _ in })

        let result = await run(delegate, file)
        delegate.cancel()

        let moved = try result.get()
        defer { try? FileManager.default.removeItem(at: moved) }
        XCTAssertEqual(try Data(contentsOf: moved), Data("weights".utf8))
    }
}

/// The remover window's model, with the engine stood in so no model or Vision
/// request runs.
@MainActor
final class BackgroundRemoverModelTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackgroundRemoverModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A tiny real PNG (so `NSImage(data:)` accepts it), distinct per `gray`.
    private func imageFile(_ name: String, gray: CGFloat) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(gray: gray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let png = try XCTUnwrap(BackgroundRemovalService.png(try XCTUnwrap(ctx.makeImage()), dpi: [:]))
        let url = dir.appendingPathComponent(name)
        try png.write(to: url)
        return url
    }

    /// Runs with sounds off so a passing test plays nothing.
    private func quietly(_ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Prefs.soundsKey)
        defaults.set(false, forKey: Prefs.soundsKey)
        defer {
            if let previous { defaults.set(previous, forKey: Prefs.soundsKey) }
            else { defaults.removeObject(forKey: Prefs.soundsKey) }
        }
        try await body()
    }

    /// The badge shows the engine that actually produced the cutout, not the
    /// one that was asked for (HD silently falls back to Vision).
    func testBadgeFollowsTheEngineThatProducedTheResult() async throws {
        try await quietly {
            let url = try imageFile("a.png", gray: 0.2)
            let model = BackgroundRemoverModel { data in .init(png: data, usedHD: false) }
            model.load(url)
            await model.job?.value
            XCTAssertEqual(model.state, .done)
            XCTAssertFalse(model.usedHD)

            let hd = BackgroundRemoverModel { data in .init(png: data, usedHD: true) }
            hd.load(url)
            await hd.job?.value
            XCTAssertTrue(hd.usedHD)
        }
    }

    /// A slow first image finishing after a second drop must not replace the
    /// second image's result.
    func testOnlyTheLatestDropWritesTheResult() async throws {
        try await quietly {
            let slowURL = try imageFile("slow.png", gray: 0.1)
            let fastURL = try imageFile("fast.png", gray: 0.9)
            let slowData = try Data(contentsOf: slowURL)
            let fastData = try Data(contentsOf: fastURL)
            var held: CheckedContinuation<Void, Never>?
            let model = BackgroundRemoverModel { data in
                if data == slowData { await withCheckedContinuation { held = $0 } }
                return .init(png: data, usedHD: false)
            }

            model.load(slowURL)
            let first = model.job
            while held == nil { await Task.yield() }
            model.load(fastURL)
            await model.job?.value
            XCTAssertEqual(model.cutoutData, fastData)

            held?.resume()
            await first?.value
            XCTAssertEqual(model.cutoutData, fastData, "the earlier, slower image overwrote the newer result")
            XCTAssertEqual(model.state, .done)
        }
    }

    /// Save reports a failed write instead of offering Reveal for a file that
    /// was never written.
    func testSaveOnlyCountsAWriteThatHappened() async throws {
        try await quietly {
            let model = BackgroundRemoverModel { data in .init(png: data, usedHD: false) }
            model.load(try imageFile("a.png", gray: 0.5))
            await model.job?.value

            model.save(to: dir.appendingPathComponent("missing-folder/cutout.png"))
            XCTAssertFalse(model.isSaved)
            XCTAssertNotNil(model.saveError)

            let good = dir.appendingPathComponent("cutout.png")
            model.save(to: good)
            XCTAssertTrue(model.isSaved)
            XCTAssertNil(model.saveError)
            XCTAssertTrue(FileManager.default.fileExists(atPath: good.path))
        }
    }
}
