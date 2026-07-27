import XCTest
@testable import PearCompanion

final class ScreenshotNamingTests: XCTestCase {
    func testFilenameFormat() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 13
        components.hour = 14
        components.minute = 3
        components.second = 9
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = try XCTUnwrap(calendar.date(from: components))

        XCTAssertEqual(ScreenshotNaming.filename(for: date), "Pear 2026-07-13 at 14.03.09.png")
    }

    func testDefaultFolderUnderHome() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PearScreenshotNamingTests-empty"))
        defaults.removeObject(forKey: ScreenshotNaming.folderDefaultsKey)
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

        let folder = ScreenshotNaming.folder(defaults: defaults, home: home)
        XCTAssertEqual(folder.path, "/Users/someone/Documents/PearScreenshots")
    }

    func testConfiguredFolderWins() throws {
        let suite = "PearScreenshotNamingTests-configured"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("/Users/someone/Desktop/Shots", forKey: ScreenshotNaming.folderDefaultsKey)
        defer { defaults.removePersistentDomain(forName: suite) }

        let folder = ScreenshotNaming.folder(
            defaults: defaults,
            home: URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        )
        XCTAssertEqual(folder.path, "/Users/someone/Desktop/Shots")
    }

    // MARK: Collision resolution
    //
    // The filename is second-granular, so two saves inside one second resolved
    // to the same path and the second `write` truncated the first screenshot.

    func testUniqueURLPassesThroughWhenFree() {
        let target = URL(fileURLWithPath: "/shots/Pear 2026-07-27 at 14.03.09.png")
        let resolved = ScreenshotNaming.uniqueURL(preferred: target, exists: { _ in false })
        XCTAssertEqual(resolved, target)
    }

    func testUniqueURLSuffixesOnCollision() {
        let target = URL(fileURLWithPath: "/shots/Pear 2026-07-27 at 14.03.09.png")
        let taken: Set<String> = [target.path]
        let resolved = ScreenshotNaming.uniqueURL(preferred: target, exists: { taken.contains($0.path) })
        XCTAssertEqual(resolved.lastPathComponent, "Pear 2026-07-27 at 14.03.09 (1).png")
    }

    func testUniqueURLWalksPastSeveralCollisions() {
        let target = URL(fileURLWithPath: "/shots/Pear 2026-07-27 at 14.03.09.png")
        let taken: Set<String> = [
            target.path,
            "/shots/Pear 2026-07-27 at 14.03.09 (1).png",
            "/shots/Pear 2026-07-27 at 14.03.09 (2).png",
        ]
        let resolved = ScreenshotNaming.uniqueURL(preferred: target, exists: { taken.contains($0.path) })
        XCTAssertEqual(resolved.lastPathComponent, "Pear 2026-07-27 at 14.03.09 (3).png")
        XCTAssertEqual(resolved.pathExtension, "png")
    }

    func testUniqueURLKeepsExtensionSeparateFromStem() {
        // Guards the bug where the suffix lands after the extension
        // ("shot.png (1)") and the file stops being a PNG.
        let target = URL(fileURLWithPath: "/shots/shot.png")
        let resolved = ScreenshotNaming.uniqueURL(preferred: target, exists: { $0.path == target.path })
        XCTAssertEqual(resolved.deletingPathExtension().lastPathComponent, "shot (1)")
        XCTAssertEqual(resolved.pathExtension, "png")
    }
}
