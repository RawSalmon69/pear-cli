import XCTest
@testable import PearCompanion

/// The two-phase staging pile is pure model logic — stage / restore / clear /
/// removeTrashed never touch disk. These pin the guard (only home-local paths
/// stage), de-duplication, insertion order (the order "Delete all" trashes in),
/// totals math, and the post-trash reconciliation signal. No real filesystem
/// deletion happens here; `home` is injected exactly as DiskDeletionTests does.
@MainActor
final class DiskStagingModelTests: XCTestCase {
    private let home = "/Users/tester"

    @discardableResult
    private func stage(_ model: DiskStagingModel, _ name: String, _ path: String, _ size: Int64) -> Bool {
        model.stage(name: name, path: path, size: size, home: home)
    }

    func testStageAcceptsHomePathsAndTracksTotals() {
        let model = DiskStagingModel()
        XCTAssertTrue(stage(model, "a", "/Users/tester/Downloads/a.zip", 100))
        XCTAssertTrue(stage(model, "b", "/Users/tester/Documents/b.pdf", 250))
        XCTAssertEqual(model.count, 2)
        XCTAssertEqual(model.totalSize, 350, "total is the sum of staged sizes")
        XCTAssertEqual(model.stagedPaths, ["/Users/tester/Downloads/a.zip", "/Users/tester/Documents/b.pdf"])
        XCTAssertFalse(model.isEmpty)
    }

    func testStageRejectsPathsTheGuardRefuses() {
        let model = DiskStagingModel()
        XCTAssertFalse(stage(model, "sys", "/etc/passwd", 10), "outside home must be refused")
        XCTAssertFalse(stage(model, "home", home, 10), "home itself must be refused")
        XCTAssertFalse(stage(model, "lib", "/Library/Caches/x", 10), "/Library must be refused")
        XCTAssertTrue(model.isEmpty, "nothing refused was staged")
        XCTAssertEqual(model.totalSize, 0)
    }

    func testDuplicateStagingIsIgnored() {
        let model = DiskStagingModel()
        XCTAssertTrue(stage(model, "a", "/Users/tester/Downloads/a.zip", 100))
        XCTAssertFalse(stage(model, "dupe", "/Users/tester/Downloads/a.zip", 100),
                       "the same path can't be staged twice")
        XCTAssertEqual(model.count, 1)
        XCTAssertEqual(model.totalSize, 100, "a duplicate must not double the total")
    }

    func testStagePreservesInsertionOrderForDeleteAll() {
        let model = DiskStagingModel()
        stage(model, "c", "/Users/tester/c", 1)
        stage(model, "a", "/Users/tester/a", 1)
        stage(model, "b", "/Users/tester/b", 1)
        XCTAssertEqual(model.orderedPaths, ["/Users/tester/c", "/Users/tester/a", "/Users/tester/b"],
                       "Delete all trashes in stage order, not sorted order")
    }

    func testRestoreRemovesOneAndClearEmptiesAll() {
        let model = DiskStagingModel()
        stage(model, "a", "/Users/tester/a", 100)
        stage(model, "b", "/Users/tester/b", 200)
        model.restore(path: "/Users/tester/a")
        XCTAssertEqual(model.orderedPaths, ["/Users/tester/b"], "restore drops just that item")
        XCTAssertEqual(model.totalSize, 200)
        XCTAssertFalse(model.isStaged("/Users/tester/a"))
        model.clear()
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.totalSize, 0)
    }

    func testRemoveTrashedDropsTrashedKeepsFailedAndSignals() {
        let model = DiskStagingModel()
        stage(model, "a", "/Users/tester/a", 100)
        stage(model, "b", "/Users/tester/b", 200)
        stage(model, "c", "/Users/tester/c", 300)
        let before = model.trashGeneration
        // Simulate a Delete all where a and c reached the Trash but b failed.
        model.removeTrashed(["/Users/tester/a", "/Users/tester/c"])
        XCTAssertEqual(model.orderedPaths, ["/Users/tester/b"], "only the failed item stays staged")
        XCTAssertEqual(model.lastTrashed, ["/Users/tester/a", "/Users/tester/c"])
        XCTAssertEqual(model.trashGeneration, before + 1, "generation bumps so the active view prunes")
    }

    func testRemoveTrashedIsANoOpForAnEmptySet() {
        let model = DiskStagingModel()
        stage(model, "a", "/Users/tester/a", 100)
        let before = model.trashGeneration
        model.removeTrashed([])
        XCTAssertEqual(model.count, 1)
        XCTAssertEqual(model.trashGeneration, before, "an empty trashed set (all cancelled) must not signal")
    }
}
