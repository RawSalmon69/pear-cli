import XCTest
@testable import PearCompanion

@MainActor
final class ScratchpadStoreTests: XCTestCase {
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ScratchpadStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("notes.json")
    }

    func testStartsWithOneEmptyNoteWhenNoFileExists() {
        let store = ScratchpadStore(fileURL: tempFileURL())
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.currentNote.text, "")
    }

    func testSaveNowPersistsAndReloadRoundTrips() {
        let url = tempFileURL()
        let store = ScratchpadStore(fileURL: url)
        store.updateText("hello world")
        store.saveNow()

        let reloaded = ScratchpadStore(fileURL: url)
        XCTAssertEqual(reloaded.notes.count, 1)
        XCTAssertEqual(reloaded.currentNote.text, "hello world")
    }

    func testCorruptFileIsPreservedAndSeedsOneBlankNote() throws {
        let url = tempFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Garbage bytes where valid JSON is expected.
        try Data("this is not json {[".utf8).write(to: url)

        let store = ScratchpadStore(fileURL: url)
        // A failed decode seeds exactly one blank note (never the corrupt data).
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.currentNote.text, "")

        // The garbage was renamed aside, not silently dropped, so the user's
        // notes could still be recovered.
        let dir = url.deletingLastPathComponent()
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(
            siblings.contains { $0.hasPrefix("notes.json.corrupt-") },
            "a corrupt notes.json must be preserved under a .corrupt-* sibling")
    }

    func testSaveNowCreatesMissingParentDirectory() {
        let url = tempFileURL()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))

        let store = ScratchpadStore(fileURL: url)
        store.updateText("note")
        store.saveNow()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCreateNoteInsertsAfterCurrentAndSelectsIt() {
        let store = ScratchpadStore(fileURL: tempFileURL())
        store.updateText("first")
        store.createNote()

        XCTAssertEqual(store.notes.count, 2)
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertEqual(store.notes[0].text, "first")
        XCTAssertEqual(store.currentNote.text, "")
    }

    func testDeleteCurrentNoteRemovesItButNeverLeavesTheListEmpty() {
        let store = ScratchpadStore(fileURL: tempFileURL())
        store.createNote() // index 1, empty
        store.updateText("second")
        XCTAssertEqual(store.notes.count, 2)

        // Deletes "second", leaving the original (still-empty) first note.
        store.deleteCurrentNote()
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.currentNote.text, "")

        // Deleting the only remaining note must not leave the list empty.
        store.deleteCurrentNote()
        XCTAssertEqual(store.notes.count, 1, "deleting the last note leaves one empty note, never zero")
        XCTAssertEqual(store.currentNote.text, "")
    }

    func testNextAndPreviousCycleWithWraparound() {
        let store = ScratchpadStore(fileURL: tempFileURL())
        store.createNote() // index 1
        store.createNote() // index 2
        XCTAssertEqual(store.currentIndex, 2)

        store.next()
        XCTAssertEqual(store.currentIndex, 0, "next() wraps from the last note back to the first")

        store.previous()
        XCTAssertEqual(store.currentIndex, 2, "previous() wraps from the first note back to the last")

        store.previous()
        XCTAssertEqual(store.currentIndex, 1)
    }

    func testNextAndPreviousAreNoOpsWithOnlyOneNote() {
        let store = ScratchpadStore(fileURL: tempFileURL())
        store.next()
        XCTAssertEqual(store.currentIndex, 0)
        store.previous()
        XCTAssertEqual(store.currentIndex, 0)
    }
}
