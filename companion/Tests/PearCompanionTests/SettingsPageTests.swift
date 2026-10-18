import XCTest
@testable import PearCompanion

/// The Settings window's last-page memory and which pages it offers.
final class SettingsPageTests: XCTestCase {
    private func withSuite(_ body: (UserDefaults) -> Void) {
        let name = "SettingsPageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    func testFirstOpenLandsOnGeneral() {
        withSuite { XCTAssertEqual(Prefs.settingsPage(defaults: $0), .general) }
    }

    func testTheLastPageRoundTrips() {
        withSuite { defaults in
            Prefs.setSettingsPage(.about, defaults: defaults)
            XCTAssertEqual(Prefs.settingsPage(defaults: defaults), .about)
            Prefs.setSettingsPage(.appearance, defaults: defaults)
            XCTAssertEqual(Prefs.settingsPage(defaults: defaults), .appearance)
        }
    }

    func testAnUnknownStoredPageFallsBackToGeneral() {
        XCTAssertEqual(SettingsPage.resolved("menuBar"), .general)
        XCTAssertEqual(SettingsPage.resolved(nil), .general)
    }

    /// A free build stored "licence" (the locked card asks for it) must still
    /// open on a page that is actually offered.
    func testAStoredLicencePageIsNotShownInAFreeBuild() throws {
        try XCTSkipIf(FeatureFlags.paywall, "only meaningful in a free build")
        withSuite { defaults in
            Prefs.setSettingsPage(.licence, defaults: defaults)
            XCTAssertEqual(Prefs.settingsPage(defaults: defaults), .general)
        }
    }

    func testEveryOldPopoverTabHasAPage() {
        // General, Tools and Menu Bar (now Appearance) were always offered.
        for page in [SettingsPage.general, .appearance, .tools, .about] {
            XCTAssertTrue(SettingsPage.visible.contains(page), "\(page) missing")
        }
    }
}
