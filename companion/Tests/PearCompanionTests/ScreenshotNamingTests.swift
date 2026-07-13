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
        XCTAssertEqual(folder.path, "/Users/someone/Pictures/Pear Screenshots")
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
}
