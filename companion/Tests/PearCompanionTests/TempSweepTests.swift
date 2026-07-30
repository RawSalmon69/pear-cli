import XCTest
@testable import PearCompanion

/// One-off capture files on disk. Cards are backed by files now, so most of
/// these tests need a real PNG somewhere.
enum CaptureFixture {
    static func write(_ data: Data, named name: String = "shot.png") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PearCaptureFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

/// Builds ≤ 2.14.1 kept the capture temp as the card's backing file with
/// auto-save off, and nothing ever removed it — one full-resolution PNG per
/// capture accumulated in `/var/folders/…/T/` forever. Captures live in
/// `CaptureStore` now; this sweep only clears that backlog.
final class TempSweepTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PearTempSweepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, ageSeconds: TimeInterval = 3600) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        let modified = Date().addingTimeInterval(-ageSeconds)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func testRemovesOwnStaleCaptureAndQRTemps() throws {
        let shot = try write("pear-shot-\(UUID().uuidString).png")
        let qr = try write("pear-qr-\(UUID().uuidString).png")

        let removed = ScreenshotService.sweepStaleTempFiles(in: dir)

        XCTAssertEqual(removed, 2)
        XCTAssertFalse(exists(shot))
        XCTAssertFalse(exists(qr))
    }

    func testNeverTouchesFilesPearDidNotWrite() throws {
        // The sweep runs against the shared system temp directory, so anything
        // outside Pear's own prefixes must survive untouched.
        let other = try write("screenshot.png")
        let notPNG = try write("pear-shot-notes.txt")
        let similar = try write("pear-shots-archive.png")

        let removed = ScreenshotService.sweepStaleTempFiles(in: dir)

        XCTAssertEqual(removed, 0)
        XCTAssertTrue(exists(other))
        XCTAssertTrue(exists(notPNG))
        XCTAssertTrue(exists(similar))
    }

    func testSkipsVeryRecentFiles() throws {
        let fresh = try write("pear-shot-\(UUID().uuidString).png", ageSeconds: 10)

        let removed = ScreenshotService.sweepStaleTempFiles(in: dir)

        XCTAssertEqual(removed, 0, "a just-written capture must never be swept")
        XCTAssertTrue(exists(fresh))
    }

    func testMissingDirectoryIsNotAnError() {
        let gone = dir.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(ScreenshotService.sweepStaleTempFiles(in: gone), 0)
    }
}

/// The app-owned home for captures the user has not saved. Before it existed,
/// those captures lived in the system temp dir — which macOS reaps on its own
/// schedule — so every preview card had to hold the whole PNG in memory.
final class CaptureStoreTests: XCTestCase {
    private var dir: URL!
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PearCaptureStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    private func write(_ name: String, ageDays: Double) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        let modified = Date().addingTimeInterval(-ageDays * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private var suites: [String] = []

    private func defaults(folder: String?) throws -> UserDefaults {
        let suite = "PearCaptureStoreTests-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        if let folder { defaults.set(folder, forKey: ScreenshotNaming.folderDefaultsKey) }
        return defaults
    }

    // MARK: Destination policy

    func testAutoSaveOffKeepsCapturesOutOfTheUsersFolder() throws {
        let destinations = CaptureStore.destinations(
            autoSave: false, defaults: try defaults(folder: nil), home: home, store: dir)
        XCTAssertEqual(destinations, [dir], "the user asked for captures NOT to be saved")
    }

    func testAutoSaveOnPrefersTheUsersFolderAndFallsBackToTheStore() throws {
        let destinations = CaptureStore.destinations(
            autoSave: true, defaults: try defaults(folder: "/Volumes/Ext/Shots"),
            home: home, store: dir)
        // The fallback is what stops an unmounted external folder losing a shot.
        XCTAssertEqual(destinations.map(\.path), ["/Volumes/Ext/Shots", dir.path])
    }

    // MARK: Naming

    func testSavedCapturesAreHumanReadableAndCollisionFree() throws {
        let when = Date(timeIntervalSince1970: 1_770_000_000)
        let first = try CaptureStore.save(Data("a".utf8), now: when, in: dir)
        let second = try CaptureStore.save(Data("b".utf8), now: when, in: dir)
        let qr = try CaptureStore.save(Data("c".utf8), prefix: "QR", now: when, in: dir)

        XCTAssertEqual(first.lastPathComponent, ScreenshotNaming.filename(for: when))
        XCTAssertTrue(first.lastPathComponent.hasPrefix("Pear "), "a lost capture must be findable")
        XCTAssertNotEqual(second.lastPathComponent, first.lastPathComponent)
        XCTAssertTrue(second.lastPathComponent.hasSuffix(" (1).png"))
        XCTAssertTrue(qr.lastPathComponent.hasPrefix("QR "))
        XCTAssertEqual(try Data(contentsOf: first), Data("a".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("b".utf8))
    }

    // MARK: Retention

    func testDropsCapturesPastRetentionAndKeepsTheRest() throws {
        let old = try write("Pear old.png", ageDays: 8)
        let recent = try write("Pear recent.png", ageDays: 6)

        XCTAssertEqual(CaptureStore.sweep(in: dir), 1)
        XCTAssertFalse(exists(old))
        XCTAssertTrue(exists(recent))
    }

    func testLeavesNonImagesAlone() throws {
        let notes = try write("notes.txt", ageDays: 30)

        XCTAssertEqual(CaptureStore.sweep(in: dir), 0)
        XCTAssertTrue(exists(notes))
    }

    func testNeverDeletesAFileALiveCardIsBackedBy() throws {
        let shown = try write("Pear shown.png", ageDays: 30)
        let forgotten = try write("Pear forgotten.png", ageDays: 30)

        let removed = CaptureStore.sweep(in: dir, keeping: [shown])

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(exists(shown), "a card's backing file must never be swept from under it")
        XCTAssertFalse(exists(forgotten))
    }

    func testMissingDirectoryIsNotAnError() {
        let gone = dir.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(CaptureStore.sweep(in: gone), 0)
    }

    // MARK: Filing a fresh capture

    /// The capture leaves the temp dir by being moved, so a bug here loses the
    /// shot outright — nothing else holds the bytes any more.
    @MainActor
    func testMovingACaptureLandsItUnderAPearNameAndEmptiesTheSource() throws {
        let source = try CaptureFixture.write(Data("shot".utf8), named: "pear-shot-x.png")
        defer { CaptureFixture.remove(source) }

        let filed = try ScreenshotService.file(source, into: dir, moving: true)

        XCTAssertEqual(try Data(contentsOf: filed), Data("shot".utf8))
        XCTAssertTrue(filed.lastPathComponent.hasPrefix("Pear "))
        XCTAssertEqual(filed.deletingLastPathComponent().path, dir.path)
        XCTAssertFalse(exists(source), "the temp copy must not be left behind")
    }

    @MainActor
    func testFilingTwiceInTheSameSecondKeepsBothShots() throws {
        let first = try CaptureFixture.write(Data("one".utf8))
        let second = try CaptureFixture.write(Data("two".utf8))
        defer { CaptureFixture.remove(first); CaptureFixture.remove(second) }

        let a = try ScreenshotService.file(first, into: dir, moving: true)
        let b = try ScreenshotService.file(second, into: dir, moving: true)

        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try Data(contentsOf: a), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: b), Data("two".utf8))
    }

    /// Save copies: the store copy stays until retention drops it, so the card
    /// keeps working after the user saves.
    @MainActor
    func testSavingCopiesAndLeavesTheStoreCopyInPlace() throws {
        let source = try CaptureFixture.write(Data("shot".utf8))
        defer { CaptureFixture.remove(source) }

        let filed = try ScreenshotService.file(source, into: dir, moving: false)

        XCTAssertEqual(try Data(contentsOf: filed), Data("shot".utf8))
        XCTAssertTrue(exists(source))
    }

    @MainActor
    func testFilingIntoAMissingFolderCreatesIt() throws {
        let source = try CaptureFixture.write(Data("shot".utf8))
        defer { CaptureFixture.remove(source) }
        let nested = dir.appendingPathComponent("Captures", isDirectory: true)

        let filed = try ScreenshotService.file(source, into: nested, moving: true)

        XCTAssertEqual(filed.deletingLastPathComponent().path, nested.path)
    }

    func testStoreLivesUnderApplicationSupport() {
        XCTAssertTrue(CaptureStore.root.path.hasSuffix("Application Support/PearCompanion/Captures"),
                      "unexpected store path: \(CaptureStore.root.path)")
    }
}

final class CleanerTranscriptTrimTests: XCTestCase {
    func testShortTranscriptIsUntouched() {
        let text = "line one\nline two\n"
        XCTAssertEqual(CleanerRunner.trimmed(text, to: 1000), text)
    }

    func testKeepsTheTailAndCutsAtALineBoundary() {
        let text = (1...50).map { "line \($0)" }.joined(separator: "\n")
        let trimmed = CleanerRunner.trimmed(text, to: 40)

        XCTAssertLessThanOrEqual(trimmed.count, 40)
        XCTAssertTrue(trimmed.hasSuffix("line 50"), "the newest output must survive")
        XCTAssertFalse(trimmed.hasPrefix("ne "), "must not start mid-line")
        XCTAssertTrue(text.hasSuffix(trimmed))
    }

    func testSingleHugeLineStillBounded() {
        let text = String(repeating: "x", count: 5_000)
        let trimmed = CleanerRunner.trimmed(text, to: 100)
        XCTAssertEqual(trimmed.count, 100, "no newline to cut at — bound it anyway")
    }
}

/// Getting Pear's own floating UI out of the shot. A capture started from a panel
/// tile used to leave the panel over the region being grabbed — and inside a
/// full-screen shot — because the panel is non-activating and so never loses
/// focus to `screencapture`.
final class CaptureCurtainTests: XCTestCase {
    /// Thread-safe: the launcher runs on a global queue, the notifications on main.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        func add(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
    }

    func testPanelsAreHiddenBeforeTheCaptureStartsAndRestoredAfter() async {
        let recorder = Recorder()
        let center = NotificationCenter.default
        let hide = center.addObserver(forName: .pearHideForCapture, object: nil, queue: nil) { _ in
            recorder.add("hide")
        }
        let restore = center.addObserver(
            forName: .pearRestoreAfterCapture, object: nil, queue: nil) { _ in
            recorder.add("restore")
        }
        defer { center.removeObserver(hide); center.removeObserver(restore) }

        // A launcher that grabs nothing: calling the real screencapture from a
        // test would take a screenshot of whoever is running the suite.
        let wrote = await ScreenCapture.run(
            ["-x", "/dev/null"],
            writing: URL(fileURLWithPath: "/nonexistent/pear-capture-test.png"),
            launch: { _ in recorder.add("launch") })

        XCTAssertFalse(wrote, "no file was written, so the capture must report failure")
        // The ordering is the whole fix. A `queue: .main` observer would land
        // AFTER the launch here, which is exactly the bug being pinned.
        XCTAssertEqual(Array(recorder.all.prefix(2)), ["hide", "launch"])

        var waited = 0
        while !recorder.all.contains("restore"), waited < 50 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        XCTAssertEqual(recorder.all, ["hide", "launch", "restore"],
                       "the preview stack has to come back after the capture")
    }
}
