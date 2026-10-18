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
        .init(id: "keyclu", title: "Shortcuts", icon: "keyboard",
              summary: "Show the keyboard shortcuts of the app in front.",
              aliases: ["keyclu", "cheat sheet"], shortcut: "⌃⇧K"),
        .init(id: "switches", title: "Switches", icon: "switch.2",
              summary: "System toggles: keep awake, lock the screen, hide the desktop."),
    ]

    private func model(_ keys: [PanelModel.Key] = [], problems: [PanelProblem] = []) -> PanelModel {
        var model = PanelModel(entries: tools, problems: problems)
        for key in keys { _ = model.handle(key) }
        return model
    }

    private func ids(_ model: PanelModel) -> [String] { model.rows.map(\.id) }

    // MARK: - Rows and search

    func testEmptySearchListsEveryToolInOrder() {
        XCTAssertEqual(ids(model()), ["screenshot", "ocr", "keyclu", "switches"])
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
        let rows = model().rows
        XCTAssertEqual(rows[0].shortcutText, "⌃⇧S")
        XCTAssertEqual(rows[3].shortcutText, "no shortcut")
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

    // MARK: - Esc

    func testEscClearsSearchFirstThenCloses() {
        var model = model([.typed("ocr")])
        XCTAssertNil(model.handle(.escape))
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(ids(model), ["screenshot", "ocr", "keyclu", "switches"])
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
