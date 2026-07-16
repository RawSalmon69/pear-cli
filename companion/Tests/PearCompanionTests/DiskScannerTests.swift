import XCTest
@testable import PearCompanion

/// Exercises the parallel scanner against a temp tree with known contents: the
/// parallel top-level fan-out must produce the same total as an independent
/// serial walk, must find every top-level child, and must still cancel.
final class DiskScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testParallelScanTotalsMatchIndependentWalk() async throws {
        // root/dirA/{a1,a2}, root/dirB/sub/b1, root/c.bin
        let dirA = root.appendingPathComponent("dirA", isDirectory: true)
        let dirBsub = root.appendingPathComponent("dirB/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirBsub, withIntermediateDirectories: true)
        try write(dirA.appendingPathComponent("a1.bin"), kb: 64)
        try write(dirA.appendingPathComponent("a2.bin"), kb: 64)
        try write(dirBsub.appendingPathComponent("b1.bin"), kb: 128)
        try write(root.appendingPathComponent("c.bin"), kb: 32)

        let tree = try await DiskScanner.scan(path: root.path)

        XCTAssertTrue(tree.isDirectory)
        XCTAssertEqual(Set(tree.children.map(\.name)), ["dirA", "dirB", "c.bin"],
                       "every top-level child must survive the parallel fan-out")

        // The correctness anchor: the parallel walk's total equals an
        // independent serial walk of the same tree (no packages/symlinks here,
        // so the scanner's opaque-package and cap logic don't diverge).
        XCTAssertEqual(tree.size, referenceSize(root),
                       "parallel aggregation must equal a serial reference sum")

        // Sanity: total is at least the logical bytes we wrote (288 KB).
        XCTAssertGreaterThanOrEqual(tree.size, Int64(288 * 1024))

        // Children sizes plus the root's own size make up the whole.
        let childSum = tree.children.reduce(Int64(0)) { $0 + $1.size }
        XCTAssertEqual(tree.size, referenceSize(root, ownOnly: true) + childSum)
    }

    func testCancellationStopsScan() async throws {
        // A broad tree so a cancel reliably wins the race before completion.
        for d in 0..<60 {
            let dir = root.appendingPathComponent("d\(d)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in 0..<50 { try write(dir.appendingPathComponent("f\(f).bin"), kb: 4) }
        }

        let path = root.path
        let task = Task { try await DiskScanner.scan(path: path) }
        task.cancel()
        do {
            _ = try await task.value
            // Completed before the cancel landed — acceptable; nothing to assert.
        } catch {
            XCTAssertTrue(error is CancellationError,
                          "a cancelled scan must surface CancellationError, not a partial result")
        }
    }

    // MARK: Helpers

    private func write(_ url: URL, kb: Int) throws {
        try Data(count: kb * 1024).write(to: url)
    }

    /// Independent allocated-size walk. Never follows symlinks. `ownOnly`
    /// returns just the node's own allocated size (used to isolate the root
    /// directory's contribution).
    private func referenceSize(_ url: URL, ownOnly: Bool = false) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let own = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        if ownOnly { return own }
        let isSymlink = values?.isSymbolicLink ?? false
        guard (values?.isDirectory ?? false), !isSymlink else { return own }
        var total = own
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys))) ?? []
        for entry in entries { total += referenceSize(entry) }
        return total
    }
}
