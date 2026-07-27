import XCTest
import AppKit
@testable import PearCompanion

/// The capture pasteboard write. Every assertion runs against a PRIVATE named
/// pasteboard — never `.general`, which is the user's real clipboard and feeds
/// clipboard history.
@MainActor
final class ScreenshotPasteboardTests: XCTestCase {
    private func pngFixture() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return try XCTUnwrap(image.pngData())
    }

    private func board(_ name: String) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.pear.tests.\(name)"))
        pb.clearContents()
        return pb
    }

    func testAdvertisesFileURLPNGAndTIFF() throws {
        let (item, _) = ScreenshotService.pasteboardItem(
            pngData: try pngFixture(),
            fileURL: URL(fileURLWithPath: "/shots/Pear.png"))
        // A file paste (terminals, Finder) needs the URL type; editors need a
        // bitmap. Losing any of these silently breaks one paste target.
        XCTAssertTrue(item.types.contains(.fileURL))
        XCTAssertTrue(item.types.contains(.png))
        XCTAssertTrue(item.types.contains(.tiff), "TIFF must still be offered, promised or not")
    }

    func testFileURLPastesAsThePath() throws {
        let pb = board("fileurl")
        let (item, _) = ScreenshotService.pasteboardItem(
            pngData: try pngFixture(),
            fileURL: URL(fileURLWithPath: "/shots/Pear 2026-07-27 at 14.03.09.png"))
        pb.writeObjects([item])

        let url = try XCTUnwrap(pb.string(forType: .fileURL))
        XCTAssertEqual(URL(string: url)?.path, "/shots/Pear 2026-07-27 at 14.03.09.png")
    }

    func testTIFFIsNotEncodedUntilSomethingAsksForIt() throws {
        let pb = board("lazy")
        let png = try pngFixture()
        let (item, promise) = ScreenshotService.pasteboardItem(
            pngData: png, fileURL: URL(fileURLWithPath: "/shots/Pear.png"))
        pb.writeObjects([item])

        // A capture that is never pasted as TIFF must not pay for the decode +
        // uncompressed re-encode (~81 MB on a 6K shot) that used to run on the
        // main actor between the shutter and the preview card.
        XCTAssertNotNil(pb.data(forType: .png), "PNG is eager")
        XCTAssertEqual(promise.fulfillments, 0, "reading PNG must not force the TIFF")
    }

    func testTIFFResolvesWhenRequested() throws {
        let pb = board("resolve")
        let (item, promise) = ScreenshotService.pasteboardItem(
            pngData: try pngFixture(), fileURL: URL(fileURLWithPath: "/shots/Pear.png"))
        pb.writeObjects([item])

        let tiff = try XCTUnwrap(pb.data(forType: .tiff), "a TIFF-only editor must still get bytes")
        XCTAssertGreaterThan(tiff.count, 0)
        XCTAssertNotNil(NSImage(data: tiff), "the promised bytes must be a decodable image")
        XCTAssertEqual(promise.fulfillments, 1)
    }
}
