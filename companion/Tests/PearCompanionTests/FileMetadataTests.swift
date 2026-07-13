import XCTest
@testable import PearCompanion

final class FileMetadataTests: XCTestCase {
    func testCodecRoundTrip() throws {
        let metadata = FileMetadata(filename: "vacation plan 🏝️.pdf", bytes: 48_213)
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(FileMetadata.self, from: data)
        XCTAssertEqual(decoded, metadata)
    }

    func testDecodesExpectedWireFormat() throws {
        // The sealed metadata payload other devices produce.
        let json = Data(#"{"filename":"pear.png","bytes":1024}"#.utf8)
        let decoded = try JSONDecoder().decode(FileMetadata.self, from: json)
        XCTAssertEqual(decoded, FileMetadata(filename: "pear.png", bytes: 1024))
    }
}
