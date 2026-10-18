import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PearCompanion

final class ShelfConversionTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfConversionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a small generated image of `width`×`height` as `type`.
    private func makeImage(in dir: URL, named name: String, type: UTType,
                           width: Int = 101, height: Int = 60) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// Output's ImageIO type and pixel size.
    private func inspect(_ url: URL) throws -> (type: String, width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let type = try XCTUnwrap(CGImageSourceGetType(source)) as String
        let props = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (type,
                try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int),
                try XCTUnwrap(props[kCGImagePropertyPixelHeight] as? Int))
    }

    func testPNGToJPEGKeepsSizeAndLeavesOriginal() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try makeImage(in: dir, named: "photo.png", type: .png)
        let before = try Data(contentsOf: input)
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let output = try ShelfConverter.convert(input, to: .jpeg, in: outDir)

        XCTAssertEqual(output.lastPathComponent, "photo.jpg")
        let info = try inspect(output)
        XCTAssertEqual(info.type, UTType.jpeg.identifier)
        XCTAssertEqual(info.width, 101)
        XCTAssertEqual(info.height, 60)
        XCTAssertEqual(try Data(contentsOf: input), before, "the original is byte-identical")
    }

    func testTransparentPNGToJPEGComesOutWhite() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Fully transparent except an opaque square in the middle.
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.clear(CGRect(x: 0, y: 0, width: 20, height: 20))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 8, y: 8, width: 4, height: 4))
        let input = dir.appendingPathComponent("cutout.png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            input as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let output = try ShelfConverter.convert(input, to: .jpeg, in: dir)

        // Decode into a known RGBA layout and read the corner pixel.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: 20 * 20 * 4)
        let readCtx = try XCTUnwrap(CGContext(
            data: &pixels, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        readCtx.draw(decoded, in: CGRect(x: 0, y: 0, width: 20, height: 20))
        for channel in 0..<3 {
            XCTAssertGreaterThanOrEqual(pixels[channel], 250, "corner channel \(channel) is white")
        }
    }

    func testJPEGToPNG() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try makeImage(in: dir, named: "shot.jpg", type: .jpeg)
        let before = try Data(contentsOf: input)

        let output = try ShelfConverter.convert(input, to: .png, in: dir)

        XCTAssertEqual(output.lastPathComponent, "shot.png")
        let info = try inspect(output)
        XCTAssertEqual(info.type, UTType.png.identifier)
        XCTAssertEqual(info.width, 101)
        XCTAssertEqual(info.height, 60)
        XCTAssertEqual(try Data(contentsOf: input), before)
    }

    func testResizeHalvesDimensionsAndKeepsFormat() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try makeImage(in: dir, named: "photo.png", type: .png, width: 200, height: 120)
        let before = try Data(contentsOf: input)

        let output = try ShelfConverter.convert(input, to: .half, in: dir)

        XCTAssertEqual(output.lastPathComponent, "photo (50%).png")
        let info = try inspect(output)
        XCTAssertEqual(info.type, UTType.png.identifier)
        XCTAssertEqual(info.width, 100)
        XCTAssertEqual(info.height, 60)
        XCTAssertEqual(try Data(contentsOf: input), before)
    }

    func testDoesNotClobberAnExistingFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try makeImage(in: dir, named: "photo.png", type: .png)
        try Data("keep".utf8).write(to: dir.appendingPathComponent("photo.jpg"))

        let output = try ShelfConverter.convert(input, to: .jpeg, in: dir)

        XCTAssertEqual(output.lastPathComponent, "photo (1).jpg")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("photo.jpg")), Data("keep".utf8))
    }

    func testStemOverridesTheOutputName() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = try makeImage(in: dir, named: "photo (3).png", type: .png)
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let output = try ShelfConverter.convert(input, to: .jpeg, in: outDir, stem: "photo")

        XCTAssertEqual(output.lastPathComponent, "photo.jpg")
    }

    func testNonImageThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: input)

        XCTAssertThrowsError(try ShelfConverter.convert(input, to: .png, in: dir))
    }

    func testAvailableHidesTheSameFormat() {
        XCTAssertEqual(ShelfConversion.available(for: URL(fileURLWithPath: "/a.png")), [.jpeg, .half])
        XCTAssertEqual(ShelfConversion.available(for: URL(fileURLWithPath: "/a.JPG")), [.png, .half])
        XCTAssertEqual(ShelfConversion.available(for: URL(fileURLWithPath: "/a.heic")), [.png, .jpeg, .half])
    }
}
