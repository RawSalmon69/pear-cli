import XCTest
@testable import PearCompanion

final class QRCodeTests: XCTestCase {
    func testGenerateDecodeRoundtrip() throws {
        let payload = "https://example.com/pear?x=1"
        let image = try XCTUnwrap(QRCode.generate(from: payload))
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(QRCode.decode(in: cg), [payload])
    }

    func testGenerateEmptyStringReturnsNil() {
        XCTAssertNil(QRCode.generate(from: ""))
    }

    func testPayloadsFromImageDataRoundtrip() throws {
        let image = try XCTUnwrap(QRCode.generate(from: "hello pear"))
        let png = try XCTUnwrap(image.pngData())
        XCTAssertEqual(QRCode.payloads(inImageData: png), ["hello pear"])
    }

    func testDecodePlainImageFindsNothing() throws {
        // 32×32 solid color — no code present.
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(QRCode.decode(in: cg), [])
    }

    func testClipboardTextJoinsWithNewlines() {
        XCTAssertEqual(QRCode.clipboardText(for: ["a", "b"]), "a\nb")
        XCTAssertEqual(QRCode.clipboardText(for: ["only"]), "only")
    }

    func testOpenableURLRequiresSingleHTTPPayload() {
        XCTAssertEqual(QRCode.openableURL(in: ["https://example.com"])?.absoluteString,
                       "https://example.com")
        XCTAssertEqual(QRCode.openableURL(in: ["http://example.com"])?.absoluteString,
                       "http://example.com")
        XCTAssertNil(QRCode.openableURL(in: ["mailto:a@b.co"]))
        XCTAssertNil(QRCode.openableURL(in: ["not a url"]))
        XCTAssertNil(QRCode.openableURL(in: ["https://a.com", "https://b.com"]))
        XCTAssertNil(QRCode.openableURL(in: []))
    }
}

@MainActor
final class PreviewQRStateTests: XCTestCase {
    func testBadgeVisibility() {
        let state = PreviewQRState()
        XCTAssertFalse(state.showsBadge)
        state.payloads = ["https://example.com"]
        XCTAssertTrue(state.showsBadge)
        state.payloads = []
        XCTAssertFalse(state.showsBadge)
    }
}
