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
        // General and Menu Bar (now Appearance) were always offered; the old
        // Tools tab is now one page per tool.
        for page in [SettingsPage.general, .appearance, .about] {
            XCTAssertTrue(SettingsPage.visible.contains(page), "\(page) missing")
        }
    }

    // MARK: - Tool pages

    func testTheSidebarHasOnePagePerToolInOfferOrderBetweenShortcutsAndAbout() throws {
        try XCTSkipIf(FeatureFlags.paywall, "Licence is offered in a paid build")
        XCTAssertEqual(
            SettingsPage.visible(toolIDs: ["screenshot", "menubar", "cleanmode"]),
            [.general, .appearance, .shortcuts,
             .tool("screenshot"), .tool("menubar"), .tool("cleanmode"), .about])
    }

    func testAStoredToolPageReadsBackWhileThatToolIsOffered() {
        withSuite { defaults in
            Prefs.setSettingsPage(.tool("menubar"), defaults: defaults)
            XCTAssertEqual(
                Prefs.settingsPage(defaults: defaults, toolIDs: ["screenshot", "menubar"]),
                .tool("menubar"))
        }
    }

    func testARemovedToolsStoredPageFallsBackToGeneral() {
        withSuite { defaults in
            Prefs.setSettingsPage(.tool("monitor"), defaults: defaults)
            XCTAssertEqual(Prefs.settingsPage(defaults: defaults, toolIDs: ["menubar"]), .general)
        }
        // And the temporary "tools" page from before per-tool pages.
        XCTAssertEqual(SettingsPage.resolved("tools", toolIDs: ["menubar"]), .general)
    }

    // MARK: - Pins picker

    private let entries: [PanelModel.Entry] = ["a", "b", "c", "d", "e", "f"].map {
        PanelModel.Entry(id: $0, title: $0.uppercased(), icon: "circle", summary: "")
    }

    private func pinned(_ pins: [String]) -> [String] {
        PanelModel(entries: entries, problems: [], pins: pins).pinned.map(\.id)
    }

    func testPickingAToolForASlotReplacesThatSlot() {
        let model = PanelModel(entries: entries, problems: [], pins: ["a", "b", "c", "d"])
        XCTAssertEqual(model.pins(placing: "e", inSlot: 1), ["a", "e", "c", "d"])
    }

    func testPickingAToolAlreadyPinnedSwapsTheTwoSlots() {
        let model = PanelModel(entries: entries, problems: [], pins: ["a", "b", "c", "d"])
        XCTAssertEqual(model.pins(placing: "c", inSlot: 0), ["c", "b", "a", "d"])
    }

    /// Slots the panel filled from offer order become real pins, so the row the
    /// user chose is exactly the row the panel shows, never more than four.
    func testTheChosenRowIsWhatThePanelShows() {
        let model = PanelModel(entries: entries, problems: [], pins: [])
        let pins = model.pins(placing: "f", inSlot: 3)
        XCTAssertEqual(pins, ["a", "b", "c", "f"])
        XCTAssertEqual(pinned(pins), ["a", "b", "c", "f"])
    }

    /// A pin of a tool that is off stays stored, as the panel's own Pin/Unpin keeps it.
    func testAPinOfAToolThatIsOffIsKept() {
        let model = PanelModel(entries: entries, problems: [], pins: ["x", "a", "b"])
        let pins = model.pins(placing: "e", inSlot: 0)
        XCTAssertEqual(pins, ["e", "b", "c", "d", "x"])
        XCTAssertEqual(pinned(pins), ["e", "b", "c", "d"])
    }

    func testASlotPastTheRowChangesNothing() {
        let model = PanelModel(entries: Array(entries.prefix(2)), problems: [], pins: ["a"])
        XCTAssertEqual(model.pins(placing: "b", inSlot: 3), ["a"])
    }

    /// The picker saves through `Prefs.setPinnedTools`, which also retires the
    /// "Pick your four" card, and the panel's next open reads the new row.
    func testSavingThePickerRetiresTheCardAndThePanelReadsIt() {
        withSuite { defaults in
            let model = PanelModel(
                entries: entries, problems: [], pins: Prefs.pinnedTools(defaults: defaults))
            Prefs.setPinnedTools(model.pins(placing: "e", inSlot: 2), defaults: defaults)
            XCTAssertTrue(Prefs.isPickYourFourDismissed(defaults: defaults))
            XCTAssertEqual(pinned(Prefs.pinnedTools(defaults: defaults)), ["a", "b", "e", "d"])
        }
    }
}
