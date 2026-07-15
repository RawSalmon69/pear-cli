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
}
