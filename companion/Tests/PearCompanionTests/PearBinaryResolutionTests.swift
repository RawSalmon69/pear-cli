import XCTest

@testable import PearCompanion

/// Resolution order for the pear CLI the app shells out to: the copy bundled in
/// Contents/Resources wins (it's version-matched to the app, so every flag the
/// companion invokes is present), and installed copies are the fallback for
/// `swift run`/tests or a build with no bundle.
final class PearBinaryResolutionTests: XCTestCase {
    func testBundledCopyWinsOverInstalled() {
        let found = PearStatsService.pearBinary(isExecutable: { _ in true })
        XCTAssertEqual(found?.hasSuffix("pear-cli/pear"), true)
    }

    func testInstalledCopyUsedWhenNoBundle() {
        // Bundle absent (nothing ending in pear-cli/pear is executable).
        let found = PearStatsService.pearBinary(isExecutable: { path in
            !path.hasSuffix("pear-cli/pear")
        })
        XCTAssertEqual(found, "/usr/local/bin/pear")
    }

    func testHomebrewCopyUsedWhenOnlyItInstalled() {
        let found = PearStatsService.pearBinary(isExecutable: { path in
            path == "/opt/homebrew/bin/pear"
        })
        XCTAssertEqual(found, "/opt/homebrew/bin/pear")
    }

    func testNoCopyAnywhereResolvesNil() {
        XCTAssertNil(PearStatsService.pearBinary(isExecutable: { _ in false }))
    }
}
