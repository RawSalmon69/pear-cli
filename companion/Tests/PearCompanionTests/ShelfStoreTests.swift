import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import PearCompanion

@MainActor
final class ShelfStoreTests: XCTestCase {
    /// A fresh temp shelf root, torn down after the test. Never the real
    /// Application Support directory.
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Each source lives in its own temp subdirectory so its filename stays
    /// clean (e.g. "notes.txt") — two calls with the same name then collide
    /// only inside the shelf root, which is what the suffix logic must handle.
    private func makeSourceFile(named name: String, contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testAddCopiesAndPersistsAcrossReload() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try makeSourceFile(named: "notes.txt", contents: "hello shelf")
        defer { try? FileManager.default.removeItem(at: source) }

        let store = ShelfStore(root: root)
        store.add(source)

        XCTAssertEqual(store.items.count, 1)
        let added = try XCTUnwrap(store.items.first)
        XCTAssertEqual(added.originalName, "notes.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: added.url.path))

        // The copy must survive the source being deleted.
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try String(contentsOf: added.url, encoding: .utf8), "hello shelf")

        // A second store over the same root reloads the persisted index.
        let reloaded = ShelfStore(root: root)
        XCTAssertEqual(reloaded.items.count, 1)
        let restored = try XCTUnwrap(reloaded.items.first)
        XCTAssertEqual(restored.id, added.id)
        XCTAssertEqual(restored.originalName, "notes.txt")
        XCTAssertEqual(restored.storedPath, added.storedPath)
    }

    func testCollidingNamesGetUniqueSuffix() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let a = try makeSourceFile(named: "photo.png", contents: "a")
        let b = try makeSourceFile(named: "photo.png", contents: "b")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }

        let store = ShelfStore(root: root)
        store.add(a)
        store.add(b)

        XCTAssertEqual(store.items.count, 2)
        let storedNames = Set(store.items.map { $0.url.lastPathComponent })
        XCTAssertEqual(storedNames, ["photo.png", "photo (1).png"])
        // Both display under their original name.
        XCTAssertEqual(store.items.map(\.originalName), ["photo.png", "photo.png"])
    }

    // MARK: - Paste-in ingestion mapping

    /// A throwaway private pasteboard so tests never touch the general one.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard.withUniqueName()
    }

    private func makePNGData() throws -> Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testIngestSourcesMapsFileURLsAsNonTemporary() throws {
        let a = try makeSourceFile(named: "one.txt", contents: "a")
        let b = try makeSourceFile(named: "two.txt", contents: "b")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let pb = makePasteboard()
        pb.writeObjects([a as NSURL, b as NSURL])

        let sources = ShelfStore.ingestSources(from: pb)
        XCTAssertEqual(sources.map(\.url.lastPathComponent), ["one.txt", "two.txt"])
        XCTAssertEqual(sources.map(\.isTemporary), [false, false])
    }

    func testIngestSourcesMaterializesImageAsTempPNG() throws {
        let pb = makePasteboard()
        pb.setData(try makePNGData(), forType: .png)

        let sources = ShelfStore.ingestSources(from: pb)
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(sources.count, 1)
        XCTAssertTrue(source.isTemporary)
        XCTAssertEqual(source.url.pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.url.path))
        try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent())
    }

    func testIngestSourcesMaterializesPlainTextAsTempTxt() throws {
        let pb = makePasteboard()
        pb.setString("clipboard note", forType: .string)

        let sources = ShelfStore.ingestSources(from: pb)
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(sources.count, 1)
        XCTAssertTrue(source.isTemporary)
        XCTAssertEqual(source.url.pathExtension, "txt")
        XCTAssertEqual(try String(contentsOf: source.url, encoding: .utf8), "clipboard note")
        try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent())
    }

    func testIngestSourcesIgnoresBlankAndEmpty() {
        let blank = makePasteboard()
        blank.setString("   \n ", forType: .string)
        XCTAssertTrue(ShelfStore.ingestSources(from: blank).isEmpty)
        XCTAssertTrue(ShelfStore.ingestSources(from: makePasteboard()).isEmpty)
    }

    func testIngestCopiesTextIntoShelfAndCleansTemp() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pb = makePasteboard()
        pb.setString("hello from clipboard", forType: .string)

        let store = ShelfStore(root: root)
        let added = store.ingest(from: pb)

        XCTAssertEqual(added, 1)
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.originalName, "Pasted Text.txt")
        // The copy lives in the shelf and holds the pasted text.
        XCTAssertEqual(try String(contentsOf: item.url, encoding: .utf8), "hello from clipboard")
    }

    // MARK: - Copy-out

    func testCopyPutsFileURLOnPasteboard() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSourceFile(named: "notes.txt", contents: "x")
        defer { try? FileManager.default.removeItem(at: source) }

        let store = ShelfStore(root: root)
        store.add(source)
        let entry = try XCTUnwrap(store.items.first)

        let pb = makePasteboard()
        store.copy(entry, to: pb)

        let urls = try XCTUnwrap(pb.readObjects(forClasses: [NSURL.self]) as? [URL])
        XCTAssertEqual(urls.map(\.path), [entry.url.path])
        // A non-image entry vends no image representation.
        let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage]
        XCTAssertTrue(images?.isEmpty ?? true)
    }

    func testCopyImageAlsoVendsImageData() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("shot.png")
        try makePNGData().write(to: source)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ShelfStore(root: root)
        store.add(source)
        let entry = try XCTUnwrap(store.items.first)

        let pb = makePasteboard()
        store.copy(entry, to: pb)

        let urls = try XCTUnwrap(pb.readObjects(forClasses: [NSURL.self]) as? [URL])
        XCTAssertEqual(urls.map(\.path), [entry.url.path])
        let images = try XCTUnwrap(pb.readObjects(forClasses: [NSImage.self]) as? [NSImage])
        XCTAssertFalse(images.isEmpty)
    }

    func testCopyHoveredFallsBackToTopItem() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try makeSourceFile(named: "a.txt", contents: "a")
        let b = try makeSourceFile(named: "b.txt", contents: "b")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let store = ShelfStore(root: root)
        store.add(a)
        store.add(b) // b is now on top

        // No hover → top item copied.
        let pb = makePasteboard()
        XCTAssertTrue(store.copyHovered(to: pb))
        let top = try XCTUnwrap((pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first)
        XCTAssertEqual(top.lastPathComponent, "b.txt")

        // Hovering the second row copies that one instead.
        store.hoveredID = store.items[1].id
        let pb2 = makePasteboard()
        XCTAssertTrue(store.copyHovered(to: pb2))
        let hovered = try XCTUnwrap((pb2.readObjects(forClasses: [NSURL.self]) as? [URL])?.first)
        XCTAssertEqual(hovered.lastPathComponent, "a.txt")
    }
}
