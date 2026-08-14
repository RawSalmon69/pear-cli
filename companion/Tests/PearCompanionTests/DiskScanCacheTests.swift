import XCTest
@testable import PearCompanion

/// The on-disk copy of the last scan, which is the only reason the Disk window
/// opens on numbers instead of a spinner: the native walk costs ~26 s warm.
/// Every test points at a temp directory — nothing here may read or write the
/// real Application Support.
final class DiskScanCacheTests: XCTestCase {
    private var dir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PearDiskScanCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("scan.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// root(100) ├ a(60) ├ a1(40) └ a1x(25)
    ///           └ b(30)
    private func tree() -> DiskNode {
        let a1x = DiskNode(id: "/r/a/a1/x", name: "x", size: 25, isDirectory: false, children: [])
        let a1 = DiskNode(id: "/r/a/a1", name: "a1", size: 40, isDirectory: true, children: [a1x])
        let a = DiskNode(id: "/r/a", name: "a", size: 60, isDirectory: true, children: [a1])
        let b = DiskNode(id: "/r/b", name: "b", size: 30, isDirectory: false, children: [])
        return DiskNode(id: "/r", name: "r", size: 100, isDirectory: true, children: [a, b])
    }

    // MARK: Round trip

    func testRoundTripKeepsTheTreeAndItsTimestamp() throws {
        let when = Date(timeIntervalSince1970: 1_770_000_000)

        DiskScanCache.save(root: tree(), scannedPath: "/r", scannedAt: when, to: url)
        let loaded = try XCTUnwrap(DiskScanCache.load(from: url))

        XCTAssertEqual(loaded.scannedPath, "/r")
        XCTAssertEqual(loaded.scannedAt.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(loaded.root, tree(), "the cached tree must come back byte-identical")
    }

    func testSavingCreatesTheFolder() throws {
        let nested = dir.appendingPathComponent("DiskScan", isDirectory: true)
            .appendingPathComponent("scan.json")

        DiskScanCache.save(root: tree(), scannedPath: "/r", scannedAt: Date(), to: nested)

        XCTAssertNotNil(DiskScanCache.load(from: nested))
    }

    // MARK: Missing and corrupt

    func testNoCacheIsNotAnError() {
        XCTAssertNil(DiskScanCache.load(from: url), "a first run just scans")
        XCTAssertNil(DiskScanCache.load(from: dir.appendingPathComponent("nope/deep.json")))
    }

    /// A corrupt cache must never be worse than no cache: the read reports
    /// nothing (so the caller scans) *and* removes the file, or every future
    /// open pays the same failed decode.
    func testCorruptCacheReportsNothingAndDeletesItself() throws {
        try Data("{not json".utf8).write(to: url)

        XCTAssertNil(DiskScanCache.load(from: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "an unreadable cache must be cleared, not left to fail again")
    }

    func testTruncatedButValidJSONIsAlsoTreatedAsCorrupt() throws {
        try Data(#"{"scannedPath":"/r"}"#.utf8).write(to: url)

        XCTAssertNil(DiskScanCache.load(from: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Depth bound

    /// The full 10-level home tree is 1.1 M nodes / 211 MB of JSON. The cap is
    /// what keeps that out of Application Support; a cut directory keeps its
    /// true size and just stops being drillable.
    func testDepthCapDropsDeepNodesButKeepsSizes() throws {
        DiskScanCache.save(root: tree(), scannedPath: "/r", scannedAt: Date(), to: url, maxDepth: 2)
        let loaded = try XCTUnwrap(DiskScanCache.load(from: url))

        let a1 = try XCTUnwrap(loaded.root.firstDescendant(id: "/r/a/a1"))
        XCTAssertEqual(a1.size, 40, "a cut directory keeps its true total")
        XCTAssertTrue(a1.children.isEmpty, "everything below the cap is dropped")
        XCTAssertNil(loaded.root.firstDescendant(id: "/r/a/a1/x"))
        XCTAssertEqual(loaded.root.size, 100, "the root total is untouched")
    }

    func testDepthZeroKeepsOnlyTheRoot() {
        let pruned = DiskScanCache.pruned(tree(), depth: 0)
        XCTAssertEqual(pruned.size, 100)
        XCTAssertTrue(pruned.children.isEmpty)
    }

    func testACapDeeperThanTheTreeChangesNothing() {
        XCTAssertEqual(DiskScanCache.pruned(tree(), depth: 99), tree())
    }

    // MARK: Age

    func testAgeReadsInWholeUnitsFromMinutesToDays() {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        func label(_ secondsAgo: TimeInterval) -> String {
            DiskScanCache.ageLabel(scannedAt: now.addingTimeInterval(-secondsAgo), now: now)
        }

        XCTAssertEqual(label(0), "scanned just now")
        XCTAssertEqual(label(59), "scanned just now")
        XCTAssertEqual(label(60), "scanned 1 minute ago")
        XCTAssertEqual(label(150), "scanned 2 minutes ago")
        XCTAssertEqual(label(3600), "scanned 1 hour ago")
        XCTAssertEqual(label(2 * 3600), "scanned 2 hours ago")
        XCTAssertEqual(label(23 * 3600), "scanned 23 hours ago")
    }

    /// The whole point of the label: week-old numbers must not read as live.
    func testAnythingPastADayIsLabelledOutOfDate() {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        func label(_ secondsAgo: TimeInterval) -> String {
            DiskScanCache.ageLabel(scannedAt: now.addingTimeInterval(-secondsAgo), now: now)
        }

        XCTAssertEqual(label(24 * 3600), "scanned 1 day ago · may be out of date")
        XCTAssertEqual(label(7 * 24 * 3600), "scanned 7 days ago · may be out of date")
        XCTAssertFalse(DiskScanCache.isStale(scannedAt: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertTrue(DiskScanCache.isStale(scannedAt: now.addingTimeInterval(-24 * 3600), now: now))
    }

    /// A clock that went backwards (NTP correction, timezone edit) must not
    /// produce "scanned -3 hours ago".
    func testAFutureTimestampReadsAsJustNow() {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        XCTAssertEqual(DiskScanCache.ageLabel(scannedAt: now.addingTimeInterval(3600), now: now),
                       "scanned just now")
    }

    // MARK: The model's use of it

    /// The feature itself: opening on a cached path paints the old tree and
    /// starts no walk.
    @MainActor
    func testAModelWithACacheShowsItInsteadOfScanning() throws {
        let when = Date(timeIntervalSince1970: 1_770_000_000)
        DiskScanCache.save(root: tree(), scannedPath: "/r", scannedAt: when, to: url)

        let model = DiskScanModel(cacheURL: url)
        model.scanIfNeeded(path: "/r")

        XCTAssertEqual(model.root?.size, 100)
        XCTAssertFalse(model.isScanning, "a cache hit must not start a walk")
        XCTAssertEqual(model.scannedAt?.timeIntervalSince1970 ?? 0,
                       when.timeIntervalSince1970, accuracy: 0.001)
    }

    /// A cache of a different folder is not this folder's answer.
    @MainActor
    func testACacheForAnotherPathIsIgnored() {
        DiskScanCache.save(root: tree(), scannedPath: "/r", scannedAt: Date(), to: url)

        let model = DiskScanModel(cacheURL: url)
        model.scanIfNeeded(path: dir.path)
        defer { model.cancel() }

        XCTAssertTrue(model.isScanning, "the wrong folder's cache must be ignored")
        XCTAssertNil(model.root)
    }
}
