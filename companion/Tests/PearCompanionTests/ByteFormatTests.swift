import XCTest
@testable import PearCompanion

/// Mirrors the CLI's `units.BytesSI` cases so the panel's sizes stay identical
/// to what `pear analyze` prints in the terminal.
final class ByteFormatTests: XCTestCase {
    func testDecimalSICases() {
        let cases: [(Int64, String)] = [
            (-100, "0 B"),
            (0, "0 B"),
            (512, "512 B"),
            (999, "999 B"),
            (1000, "1.0 kB"),
            (1500, "1.5 kB"),
            (10000, "10.0 kB"),
            (1_000_000, "1.0 MB"),
            (1_500_000, "1.5 MB"),
            (1_000_000_000, "1.0 GB"),
            (1_000_000_000_000, "1.0 TB"),
            (1_000_000_000_000_000, "1.0 PB"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(ByteFormat.si(input), expected, "ByteFormat.si(\(input))")
        }
    }
}
