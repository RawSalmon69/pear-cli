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
}
