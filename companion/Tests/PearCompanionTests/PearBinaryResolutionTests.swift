import XCTest

@testable import PearCompanion

/// Resolution order for the pear CLI the app shells out to: installed copies
/// (kept fresh by `pe update`) beat the copy bundled in Contents/Resources,
/// and the bundled copy backstops a Mac with no installed pear at all.
final class PearBinaryResolutionTests: XCTestCase {
    func testInstalledCopyWinsOverBundled() {
        let found = PearStatsService.pearBinary(isExecutable: { _ in true })
        XCTAssertEqual(found, "/usr/local/bin/pear")
    }

    func testHomebrewCopyWinsOverBundled() {
        let found = PearStatsService.pearBinary(isExecutable: { path in
            path != "/usr/local/bin/pear"
        })
        XCTAssertEqual(found, "/opt/homebrew/bin/pear")
    }

    func testBundledCopyBackstopsWhenNothingInstalled() {
        let found = PearStatsService.pearBinary(isExecutable: { path in
            path.hasSuffix("pear-cli/pear")
        })
        XCTAssertEqual(found?.hasSuffix("pear-cli/pear"), true)
    }

    func testNoCopyAnywhereResolvesNil() {
        XCTAssertNil(PearStatsService.pearBinary(isExecutable: { _ in false }))
    }
}
