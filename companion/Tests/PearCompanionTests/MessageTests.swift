import XCTest
@testable import PearCompanion

final class MessageTests: XCTestCase {
    func testMessageKindCodableRoundTrip() throws {
        for kind in [MessageKind.text, .image, .poke, .file] {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(MessageKind.self, from: data)
            XCTAssertEqual(kind, decoded)
        }
    }
}
