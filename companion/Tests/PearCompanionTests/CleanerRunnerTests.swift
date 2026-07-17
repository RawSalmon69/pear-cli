import XCTest
@testable import PearCompanion

final class CleanerRunnerTests: XCTestCase {
    func testStripControlRemovesANSIEscapesAndCarriageReturns() {
        let raw = "\u{1B}[32m✓ done\u{1B}[0m 12 items\rrewrite\u{1B}[?25l"
        XCTAssertEqual(CleanerRunner.stripControl(raw), "✓ done 12 items\nrewrite")
    }

    func testStripControlPassesPlainTextThrough() {
        XCTAssertEqual(CleanerRunner.stripControl("➤ User essentials\n"), "➤ User essentials\n")
    }

    func testDecodeStreamingReassemblesSplitMultibyteGlyph() {
        let glyph = Array("✓".utf8) // E2 9C 93 — 3 bytes
        XCTAssertEqual(glyph.count, 3)

        var buffer = Data()
        // First feed ends mid-codepoint (only 2 of the 3 bytes present).
        buffer.append(contentsOf: glyph[0..<2])
        XCTAssertEqual(
            CleanerRunner.decodeStreaming(buffer: &buffer), "",
            "an incomplete trailing codepoint yields nothing yet")
        XCTAssertEqual(buffer.count, 2, "the partial bytes stay buffered for the next read")

        // Second feed completes the glyph.
        buffer.append(contentsOf: glyph[2...])
        XCTAssertEqual(CleanerRunner.decodeStreaming(buffer: &buffer), "✓")
        XCTAssertTrue(buffer.isEmpty, "a fully-decoded buffer is drained")
    }

    func testDecodeStreamingReturnsValidPrefixAndKeepsSplitTail() {
        let glyph = Array("✓".utf8)
        var buffer = Data("done ".utf8)
        buffer.append(contentsOf: glyph[0..<1]) // valid text + 1 byte of the glyph

        // The valid prefix comes through immediately; the lone glyph byte waits.
        XCTAssertEqual(CleanerRunner.decodeStreaming(buffer: &buffer), "done ")
        XCTAssertEqual(buffer.count, 1)

        buffer.append(contentsOf: glyph[1...])
        XCTAssertEqual(CleanerRunner.decodeStreaming(buffer: &buffer), "✓")
    }
}
