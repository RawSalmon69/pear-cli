import XCTest
@testable import PearCompanion

final class ScratchpadSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ScratchpadSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsAreOnWhenUnset() {
        XCTAssertTrue(ScratchpadSettings.swipeEnabled(defaults))
        XCTAssertTrue(ScratchpadSettings.linkDetection(defaults))
    }

    func testStoredValuesOverrideDefaults() {
        defaults.set(false, forKey: ScratchpadSettings.Key.swipeEnabled)
        defaults.set(false, forKey: ScratchpadSettings.Key.linkDetection)
        XCTAssertFalse(ScratchpadSettings.swipeEnabled(defaults))
        XCTAssertFalse(ScratchpadSettings.linkDetection(defaults))

        defaults.set(true, forKey: ScratchpadSettings.Key.swipeEnabled)
        XCTAssertTrue(ScratchpadSettings.swipeEnabled(defaults))
    }
}
