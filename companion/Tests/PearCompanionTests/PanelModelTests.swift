import XCTest

@testable import PearCompanion

/// What the panel shows and does for a given set of tools, query, key presses
/// and problems. Pure: no AppKit, no registry.
final class PanelModelTests: XCTestCase {
    private let tools: [PanelModel.Entry] = [
        .init(id: "screenshot", title: "Screenshot", icon: "camera",
              summary: "Select a region. Copy it, mark it up, or save it.", shortcut: "⌃⇧S"),
        .init(id: "ocr", title: "Grab Text", icon: "text.viewfinder",
              summary: "Copy text out of any region on screen.", aliases: ["ocr"], shortcut: "⌃⇧T"),
        .init(id: "clipboard", title: "Clipboard", icon: "doc.on.clipboard",
              summary: "Everything you copied, searchable.", shortcut: "⌃⇧C"),
        .init(id: "shelf", title: "Shelf", icon: "tray",
              summary: "Drop files here and drag them out later.", shortcut: "⌃⇧V"),
        .init(id: "keyclu", title: "Shortcuts", icon: "keyboard",
              summary: "Show the keyboard shortcuts of the app in front.",
              aliases: ["keyclu", "cheat sheet"], shortcut: "⌃⇧K"),
        .init(id: "switches", title: "Switches", icon: "switch.2",
              summary: "System toggles: keep awake, lock the screen, hide the desktop."),
    ]

    private func model(_ keys: [PanelModel.Key] = [], problems: [PanelProblem] = [],
                       pins: [String] = Prefs.defaultPinnedTools,
                       without hidden: Set<String> = []) -> PanelModel {
        var model = PanelModel(entries: tools.filter { !hidden.contains($0.id) },
                               problems: problems, pins: pins)
        for key in keys { _ = model.handle(key) }
        return model
    }

    private func ids(_ model: PanelModel) -> [String] { model.rows.map(\.id) }
    private func pinnedIDs(_ model: PanelModel) -> [String] { model.pinned.map(\.id) }

    // MARK: - Rows and search

    func testEmptySearchListsEveryUnpinnedToolInOrder() {
        XCTAssertEqual(ids(model()), ["keyclu", "switches"])
    }

    func testSearchMatchesTitleIgnoringCase() {
        XCTAssertEqual(ids(model([.typed("GRAB")])), ["ocr"])
    }

    func testSearchMatchesSummary() {
        // "text" is in Grab Text's title and its summary; "region" only in summaries.
        XCTAssertEqual(ids(model([.typed("region")])), ["screenshot", "ocr"])
        XCTAssertEqual(ids(model([.typed("keep awake")])), ["switches"])
    }

    func testSearchMatchesAliases() {
        XCTAssertEqual(ids(model([.typed("ocr")])), ["ocr"])
        XCTAssertEqual(ids(model([.typed("Cheat Sheet")])), ["keyclu"])
    }

    func testSearchIgnoresSurroundingWhitespace() {
        XCTAssertEqual(ids(model([.typed("  ocr ")])), ["ocr"])
    }

    func testNoMatchShowsNoRowsAndSaysSo() {
        let model = model([.typed("zebra")])
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.showsNoMatch)
        XCTAssertNil(model.selectedID)
    }

    func testEmptySearchNeverSaysNoMatch() {
        XCTAssertFalse(model().showsNoMatch)
        XCTAssertFalse(PanelModel(entries: [], problems: []).showsNoMatch)
    }

    func testShortcutLabelOrNoShortcut() {
        let entries = model().entries
        XCTAssertEqual(entries.first { $0.id == "screenshot" }?.shortcutText, "⌃⇧S")
        XCTAssertEqual(entries.first { $0.id == "switches" }?.shortcutText, "no shortcut")
    }

    // MARK: - Selection and Return

    func testFirstRowSelectedOnOpen() {
        XCTAssertEqual(model().selectedID, "screenshot")
    }

    func testDownMovesAndClampsAtLastRow() {
        XCTAssertEqual(model([.down]).selectedID, "ocr")
        XCTAssertEqual(model([.down, .down, .down, .down, .down]).selectedID, "switches")
    }

    func testUpClampsAtFirstRow() {
        XCTAssertEqual(model([.up]).selectedID, "screenshot")
        XCTAssertEqual(model([.down, .down, .up]).selectedID, "ocr")
        XCTAssertEqual(model([.down, .down, .down, .down, .down, .up]).selectedID, "keyclu")
    }

    func testTypingResetsSelectionToFirstResult() {
        XCTAssertEqual(model([.down, .down, .typed("region")]).selectedID, "screenshot")
    }

    func testReturnRunsTheSelectedTool() {
        var model = model([.typed("region"), .down])
        XCTAssertEqual(model.handle(.enter), .run("ocr"))
    }

    func testReturnWithNoResultsDoesNothing() {
        var model = model([.typed("zebra")])
        XCTAssertNil(model.handle(.enter))
    }

    func testSelectionStaysInRangeWhenToolsShrink() {
        var model = model([.down, .down, .down])
        model.entries = Array(tools.prefix(2))
        XCTAssertEqual(model.selectedID, "ocr")
        XCTAssertEqual(model.handle(.enter), .run("ocr"))
    }

    func testArrowsWalkThePinnedTilesThenTheList() {
        // One linear order, tiles left to right, then the list: Return on open
        // runs the first pinned tool, and four downs reach the first list row.
        var opened = model()
        XCTAssertEqual(opened.selectedID, "screenshot")
        XCTAssertEqual(opened.handle(.enter), .run("screenshot"))
        var walked = model([.down, .down, .down, .down])
        XCTAssertEqual(walked.selectedID, "keyclu")
        XCTAssertEqual(walked.handle(.enter), .run("keyclu"))
    }

    // MARK: - Pinned tools

    func testDefaultPinsAreScreenshotGrabTextClipboardShelf() {
        XCTAssertEqual(Prefs.defaultPinnedTools, ["screenshot", "ocr", "clipboard", "shelf"])
        XCTAssertEqual(pinnedIDs(model()), ["screenshot", "ocr", "clipboard", "shelf"])
    }

    func testUserPinsShowInTheirOrderAndTheRestFillInOfferOrder() {
        let model = model(pins: ["switches", "ocr"])
        XCTAssertEqual(pinnedIDs(model), ["switches", "ocr", "screenshot", "clipboard"])
        XCTAssertEqual(ids(model), ["shelf", "keyclu"])
    }

    func testDisabledPinIsSkippedAndItsSlotFilled() {
        let model = model(without: ["clipboard"])
        XCTAssertEqual(pinnedIDs(model), ["screenshot", "ocr", "shelf", "keyclu"])
        XCTAssertEqual(ids(model), ["switches"])
    }

    func testUnknownAndDuplicatePinIdsAreIgnored() {
        let model = model(pins: ["gone", "shelf", "shelf"])
        XCTAssertEqual(pinnedIDs(model), ["shelf", "screenshot", "ocr", "clipboard"])
    }

    func testFewerThanFourEnabledToolsGiveFewerTilesAndNoPlaceholders() {
        let model = model(without: ["clipboard", "shelf", "keyclu"])
        XCTAssertEqual(pinnedIDs(model), ["screenshot", "ocr", "switches"])
        XCTAssertEqual(ids(model), [])
        XCTAssertFalse(model.showsNoMatch)
    }

    func testSearchSpansPinnedAndUnpinnedToolsAndHidesThePinnedRow() {
        // Screenshot and Shelf are pinned, Shortcuts is not.
        let model = model([.typed("sh")])
        XCTAssertEqual(pinnedIDs(model), [])
        XCTAssertEqual(ids(model), ["screenshot", "shelf", "keyclu"])
        XCTAssertEqual(ids(self.model([.typed("ocr")])), ["ocr"])
    }

    func testUnpinRemovesTheToolFromTheRowAndTheNextToolFillsIt() {
        var model = model()
        XCTAssertTrue(model.isPinned("clipboard"))
        model.togglePin("clipboard")
        XCTAssertFalse(model.isPinned("clipboard"))
        XCTAssertEqual(model.pins, ["screenshot", "ocr", "shelf", "keyclu"])
        XCTAssertEqual(pinnedIDs(model), ["screenshot", "ocr", "shelf", "keyclu"])
        XCTAssertEqual(ids(model), ["clipboard", "switches"])
    }

    func testUnpinWithOnlyFourToolsKeepsAllFourShowing() {
        var model = model(without: ["keyclu", "switches"])
        // Nothing else can take the slot, so Clipboard fills it again, last.
        model.togglePin("clipboard")
        XCTAssertEqual(pinnedIDs(model), ["screenshot", "ocr", "shelf", "clipboard"])
        XCTAssertEqual(ids(model), [])
    }

    func testPinningAFilledTileMakesItARealPin() {
        var model = model(pins: ["screenshot", "ocr", "clipboard"])
        XCTAssertEqual(pinnedIDs(model).last, "shelf")
        XCTAssertFalse(model.isPinned("shelf"))
        model.togglePin("shelf")
        XCTAssertEqual(model.pins, ["screenshot", "ocr", "clipboard", "shelf"])
        XCTAssertEqual(pinnedIDs(model), ["screenshot", "ocr", "clipboard", "shelf"])
    }

    func testPinningAFifthToolReplacesTheLastPinnedTile() {
        var model = model()
        model.togglePin("switches")
        XCTAssertEqual(model.pins, ["screenshot", "ocr", "clipboard", "switches"])
        XCTAssertEqual(pinnedIDs(model), ["screenshot", "ocr", "clipboard", "switches"])
        XCTAssertEqual(ids(model), ["shelf", "keyclu"])
    }

    func testPinningKeepsADisabledPinForWhenItComesBack() {
        // Clipboard is off, so only three pins show: a fourth goes in beside them
        // and Clipboard stays remembered.
        var model = model(without: ["clipboard"])
        model.togglePin("switches")
        XCTAssertEqual(model.pins, ["screenshot", "ocr", "clipboard", "shelf", "switches"])
        XCTAssertEqual(pinnedIDs(model), ["screenshot", "ocr", "shelf", "switches"])
    }

    func testStoredPinPastTheFourthTileOffersPinAndPinningShowsIt() {
        var model = model(pins: ["screenshot", "ocr", "clipboard", "shelf", "switches"])
        XCTAssertEqual(ids(model), ["keyclu", "switches"])
        XCTAssertFalse(model.isPinned("switches"))
        model.togglePin("switches")
        XCTAssertEqual(model.pins, ["screenshot", "ocr", "clipboard", "switches"])
        XCTAssertEqual(pinnedIDs(model), ["screenshot", "ocr", "clipboard", "switches"])
    }

    func testSelectionFollowsTheToolAfterPinning() {
        var model = model([.down, .down, .down, .down])
        XCTAssertEqual(model.selectedID, "keyclu")
        model.togglePin("keyclu")
        XCTAssertEqual(pinnedIDs(model), ["screenshot", "ocr", "clipboard", "keyclu"])
        XCTAssertEqual(model.selectedID, "keyclu")
        XCTAssertEqual(model.handle(.enter), .run("keyclu"))
    }

    func testSelectionFollowsTheToolAfterUnpinning() {
        var model = model([.down, .down])
        XCTAssertEqual(model.selectedID, "clipboard")
        model.togglePin("clipboard")
        XCTAssertEqual(ids(model), ["clipboard", "switches"])
        XCTAssertEqual(model.selectedID, "clipboard")
        XCTAssertEqual(model.handle(.enter), .run("clipboard"))
    }

    func testSelectionFallsToTheFirstItemWhenTheToggledToolIsNotShown() {
        // Searching hides the tiles; a pin toggled from a result that no longer
        // matches anything visible lands on the first result, not a stray one.
        var model = model([.typed("sh"), .down, .down])
        model.togglePin("ocr")
        XCTAssertEqual(model.selectedID, "screenshot")
    }

    // MARK: - "Pick your four"

    func testPickYourFourShowsUntilDismissed() {
        var model = model()
        XCTAssertTrue(model.showsPickYourFour)
        model.dismissPickYourFour()
        XCTAssertFalse(model.showsPickYourFour)
    }

    func testAnyPinChangeRetiresPickYourFour() {
        var pinned = model()
        pinned.togglePin("switches")
        XCTAssertFalse(pinned.showsPickYourFour)
        var unpinned = model()
        unpinned.togglePin("ocr")
        XCTAssertFalse(unpinned.showsPickYourFour)
    }

    func testDismissedPickYourFourNeverShowsAgain() {
        let model = PanelModel(entries: tools, problems: [], pickYourFourDismissed: true)
        XCTAssertFalse(model.showsPickYourFour)
    }

    func testPickYourFourHidesWhileSearching() {
        XCTAssertFalse(model([.typed("sh")]).showsPickYourFour)
        XCTAssertTrue(model([.typed("sh"), .escape]).showsPickYourFour)
    }

    // MARK: - Pins and the card in Prefs

    private func withSuite(_ body: (UserDefaults) -> Void) {
        let name = "PanelModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    func testPrefsPinsDefaultUntilSetThenRoundTrip() {
        withSuite { defaults in
            XCTAssertEqual(Prefs.pinnedTools(defaults: defaults), Prefs.defaultPinnedTools)
            Prefs.setPinnedTools(["switches", "ocr"], defaults: defaults)
            XCTAssertEqual(Prefs.pinnedTools(defaults: defaults), ["switches", "ocr"])
        }
    }

    func testPrefsUnpinningEverythingStaysEmptyNotDefault() {
        withSuite { defaults in
            Prefs.setPinnedTools([], defaults: defaults)
            XCTAssertEqual(Prefs.pinnedTools(defaults: defaults), [])
        }
    }

    func testPrefsPickYourFourDismissalPersists() {
        withSuite { defaults in
            XCTAssertFalse(Prefs.isPickYourFourDismissed(defaults: defaults))
            Prefs.dismissPickYourFour(defaults: defaults)
            XCTAssertTrue(Prefs.isPickYourFourDismissed(defaults: defaults))
        }
    }

    func testPrefsSettingPinsRetiresPickYourFour() {
        withSuite { defaults in
            Prefs.setPinnedTools(["shelf"], defaults: defaults)
            XCTAssertTrue(Prefs.isPickYourFourDismissed(defaults: defaults))
        }
    }

    // MARK: - Recent captures

    private func capture(_ name: String) -> URL { URL(fileURLWithPath: "/captures/\(name).png") }

    func testRecentsShowAtMostThreeNewestFirst() {
        let all = (1...5).map { capture("shot\($0)") }
        let model = PanelModel(entries: tools, problems: [], recentCaptures: all)
        XCTAssertEqual(model.recents, Array(all.prefix(3)))
    }

    func testRecentsHiddenWhenEmpty() {
        XCTAssertEqual(PanelModel(entries: tools, problems: []).recents, [])
    }

    /// Missing files are dropped on read, so a list whose files are all gone
    /// reaches the model empty and the strip hides.
    func testPrefsRecentCapturesDropMissingFiles() {
        withSuite { defaults in
            for name in ["a", "b", "c"] { Prefs.recordCapture(capture(name), defaults: defaults) }
            let gone: Set<URL> = [capture("b")]
            XCTAssertEqual(Prefs.recentCaptures(defaults: defaults, exists: { !gone.contains($0) }),
                           [capture("c"), capture("a")])
            let none = Prefs.recentCaptures(defaults: defaults, exists: { _ in false })
            XCTAssertEqual(PanelModel(entries: tools, problems: [], recentCaptures: none).recents, [])
        }
    }

    func testRecentsHideWhileSearching() {
        var model = PanelModel(entries: tools, problems: [], recentCaptures: [capture("a")])
        _ = model.handle(.typed("sh"))
        XCTAssertEqual(model.recents, [])
        _ = model.handle(.escape)
        XCTAssertEqual(model.recents, [capture("a")])
    }

    /// Thumbnails are click-and-drag only: the arrows still walk tiles then list.
    func testRecentsStayOutOfTheKeyboardOrder() {
        var model = PanelModel(entries: tools, problems: [], recentCaptures: [capture("a")])
        XCTAssertEqual(model.handle(.enter), .run("screenshot"))
    }

    func testPrefsRecentCapturesNewestFirstDedupedCappedAtTen() {
        withSuite { defaults in
            let all: (URL) -> Bool = { _ in true }
            XCTAssertEqual(Prefs.recentCaptures(defaults: defaults, exists: all), [])
            for i in 1...12 { Prefs.recordCapture(capture("shot\(i)"), defaults: defaults) }
            Prefs.recordCapture(capture("shot5"), defaults: defaults)
            let recents = Prefs.recentCaptures(defaults: defaults, exists: all)
            XCTAssertEqual(recents.count, Prefs.recentCapturesKept)
            XCTAssertEqual(recents.prefix(3), [capture("shot5"), capture("shot12"), capture("shot11")])
            XCTAssertEqual(recents.filter { $0 == capture("shot5") }.count, 1)
            XCTAssertFalse(recents.contains(capture("shot2")))
        }
    }

    // MARK: - Esc

    func testEscClearsSearchFirstThenCloses() {
        var model = model([.typed("ocr")])
        XCTAssertNil(model.handle(.escape))
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(pinnedIDs(model), ["screenshot", "ocr", "clipboard", "shelf"])
        XCTAssertEqual(ids(model), ["keyclu", "switches"])
        XCTAssertEqual(model.handle(.escape), .close)
    }

    func testEscWithEmptySearchCloses() {
        var model = model()
        XCTAssertEqual(model.handle(.escape), .close)
    }

    // MARK: - The cat's line and mood

    func testNoProblemsMeansEmptyLineAndIdleCat() {
        let model = model()
        XCTAssertEqual(model.catLine, "")
        XCTAssertEqual(model.mood, .idle)
    }

    func testProblemBecomesTheCatsLineAndWorriesIt() {
        let model = model(problems: [.diskNearlyFull])
        XCTAssertEqual(model.catLine, "Your disk is nearly full")
        XCTAssertEqual(model.mood, .worried)
    }

    func testDiskOverNinetyPercentIsAProblem() {
        XCTAssertEqual(PanelProblem.current(diskUsedFraction: 0.95), [.diskNearlyFull])
        XCTAssertEqual(PanelProblem.current(diskUsedFraction: 0.9), [])
        XCTAssertEqual(PanelProblem.current(diskUsedFraction: 0.4), [])
        XCTAssertEqual(PanelProblem.current(diskUsedFraction: nil), [])
    }

    // MARK: - Permission problems

    func testProblemsComeInPriorityOrderScreenRecordingFirst() {
        let problems = PanelProblem.current(
            diskUsedFraction: 0.95, screenRecordingMissing: true,
            accessibilityTrusted: false, enabledTools: ["keyclu"])
        XCTAssertEqual(problems, [.screenRecordingMissing, .accessibilityMissing, .diskNearlyFull])
        let model = model(problems: problems.reversed())
        XCTAssertEqual(model.catLine, "Screenshots need Screen Recording")
        XCTAssertEqual(model.fix, .screenRecording)
        XCTAssertEqual(model.mood, .worried)
    }

    func testAccessibilityOutranksTheDiskAndOffersItsPane() {
        let model = model(problems: [.diskNearlyFull, .accessibilityMissing])
        XCTAssertEqual(model.catLine, "Some tools need Accessibility")
        XCTAssertEqual(model.fix, .accessibility)
    }

    func testDiskProblemHasNoFix() {
        XCTAssertNil(model(problems: [.diskNearlyFull]).fix)
        XCTAssertNil(model().fix)
    }

    func testAccessibilityIsAProblemOnlyForAnEnabledToolThatNeedsIt() {
        XCTAssertEqual(PanelProblem.current(
            diskUsedFraction: nil, accessibilityTrusted: false,
            enabledTools: ["screenshot", "clipboard", "colorPicker"]), [])
        for id in ["keyclu", "windows", "highlightcopy"] {
            XCTAssertEqual(PanelProblem.current(
                diskUsedFraction: nil, accessibilityTrusted: false, enabledTools: ["clipboard", id]),
                [.accessibilityMissing], id)
        }
    }

    func testAffectedToolsSayNeedsPermission() {
        let screen = model(problems: [.screenRecordingMissing])
        XCTAssertTrue(screen.needsPermission("screenshot"))
        XCTAssertTrue(screen.needsPermission("ocr"))
        for id in ["screenshot-full", "screenshot-window", "qr"] {
            XCTAssertTrue(screen.needsPermission(id), id)
        }
        XCTAssertFalse(screen.needsPermission("colorPicker"), "the system color sampler needs no grant")
        XCTAssertFalse(screen.needsPermission("keyclu"))
        XCTAssertFalse(screen.needsPermission("clipboard"))

        let access = model(problems: [.accessibilityMissing])
        XCTAssertTrue(access.needsPermission("keyclu"))
        XCTAssertFalse(access.needsPermission("screenshot"))

        XCTAssertFalse(model(problems: [.diskNearlyFull]).needsPermission("screenshot"))
    }

    func testProblemsClearWhenTheInputsSayGranted() {
        let problems = PanelProblem.current(
            diskUsedFraction: 0.4, screenRecordingMissing: false,
            accessibilityTrusted: true, enabledTools: Set(tools.map(\.id) + ["windows"]))
        XCTAssertEqual(problems, [])
        let model = model(problems: problems)
        XCTAssertEqual(model.catLine, "")
        XCTAssertEqual(model.mood, .idle)
        XCTAssertFalse(model.needsPermission("screenshot"))
        XCTAssertFalse(model.needsPermission("keyclu"))
    }

    /// The capture rule: attempt first, and only "no file while preflight says
    /// no" is a problem. A file always wins, and then preflight is not even read.
    func testCaptureIsAPermissionProblemOnlyWhenNothingWasWrittenAndPreflightSaysNo() {
        XCTAssertTrue(ScreenCapture.deniedByPermission(wroteFile: false, granted: false))
        XCTAssertFalse(ScreenCapture.deniedByPermission(wroteFile: false, granted: true),
                       "Esc with the permission granted is a plain cancel")
        var asked = false
        XCTAssertFalse(ScreenCapture.deniedByPermission(
            wroteFile: true, granted: { asked = true; return false }()))
        XCTAssertFalse(asked, "a written file never consults preflight")
    }

    func testUnseenNoteExcitesTheCatOnlyWithoutAProblem() {
        var calm = model()
        calm.hasUnseenNote = true
        XCTAssertEqual(calm.mood, .excited)
        XCTAssertEqual(calm.catLine, "")

        var worried = model(problems: [.diskNearlyFull])
        worried.hasUnseenNote = true
        XCTAssertEqual(worried.mood, .worried)
    }
}
