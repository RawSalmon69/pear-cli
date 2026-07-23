import XCTest
@testable import PearCompanion

@MainActor
final class QRToolTests: XCTestCase {
    func testToolIdentityAndDefaults() {
        let tool = QRTool()
        XCTAssertEqual(tool.id, "qr")
        XCTAssertEqual(tool.category, .capture)
        XCTAssertEqual(tool.hotkey?.label, "⌃⇧Q")
        XCTAssertTrue(tool.defaultEnabled)
        XCTAssertTrue(tool.showsTile)
    }
}
