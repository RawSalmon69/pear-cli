import XCTest
@testable import PearCompanion

@MainActor
final class MenuBarManagerTests: XCTestCase {
    /// In-memory stand-in for the status item, so state logic is exercised
    /// without a live menu bar.
    private final class FakeSeparator: MenuBarSeparating {
        var length: CGFloat = 0
        var onClick: (() -> Void)?
        private(set) var lastChevronCollapsed: Bool?
        func setChevron(collapsed: Bool) { lastChevronCollapsed = collapsed }
    }

    private func makeManager(suite: String) throws -> (MenuBarManager, UserDefaults) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (MenuBarManager(defaults: defaults, keyPrefix: "mb"), defaults)
    }

    // MARK: - Defaults

    func testDefaultsAreCollapsedWithTenSecondRehide() throws {
        let (manager, defaults) = try makeManager(suite: "MenuBarTests-defaults")
        defer { defaults.removePersistentDomain(forName: "MenuBarTests-defaults") }

        XCTAssertTrue(manager.isCollapsed)
        XCTAssertEqual(manager.autoRehideSeconds, 10)
    }

    // MARK: - Pure mechanism functions

    func testSeparatorLength() {
        XCTAssertEqual(MenuBarManager.separatorLength(collapsed: true), MenuBarManager.collapsedLength)
        XCTAssertEqual(MenuBarManager.separatorLength(collapsed: false), MenuBarManager.expandedLength)
        // Collapsed must be huge enough to shove neighbors off-screen.
        XCTAssertGreaterThan(MenuBarManager.collapsedLength, 1000)
    }

    func testChevronSymbolFlipsWithState() {
        XCTAssertEqual(MenuBarManager.chevronSymbol(collapsed: true), "chevron.compact.left")
        XCTAssertEqual(MenuBarManager.chevronSymbol(collapsed: false), "chevron.compact.right")
    }

    func testShouldScheduleRehideOnlyWhenExpandedWithPositiveDelay() {
        XCTAssertTrue(MenuBarManager.shouldScheduleRehide(collapsed: false, autoRehideSeconds: 10))
        XCTAssertFalse(MenuBarManager.shouldScheduleRehide(collapsed: true, autoRehideSeconds: 10))
        XCTAssertFalse(MenuBarManager.shouldScheduleRehide(collapsed: false, autoRehideSeconds: 0))
        XCTAssertFalse(MenuBarManager.shouldScheduleRehide(collapsed: true, autoRehideSeconds: 0))
    }

    // MARK: - State applied to the separator

    func testAttachAppliesCollapsedLengthAndChevron() throws {
        let (manager, defaults) = try makeManager(suite: "MenuBarTests-attach")
        defer { defaults.removePersistentDomain(forName: "MenuBarTests-attach") }

        let fake = FakeSeparator()
        manager.attach(fake)

        XCTAssertEqual(fake.length, MenuBarManager.collapsedLength)
        XCTAssertEqual(fake.lastChevronCollapsed, true)
    }

    func testToggleExpandsThenCollapses() throws {
        let (manager, defaults) = try makeManager(suite: "MenuBarTests-toggle")
        defer { defaults.removePersistentDomain(forName: "MenuBarTests-toggle") }

        let fake = FakeSeparator()
        manager.attach(fake)

        manager.toggle()
        XCTAssertFalse(manager.isCollapsed)
        XCTAssertEqual(fake.length, MenuBarManager.expandedLength)
        XCTAssertEqual(fake.lastChevronCollapsed, false)

        manager.toggle()
        XCTAssertTrue(manager.isCollapsed)
        XCTAssertEqual(fake.length, MenuBarManager.collapsedLength)
        XCTAssertEqual(fake.lastChevronCollapsed, true)
    }

    func testSeparatorClickCallbackTogglesState() throws {
        let (manager, defaults) = try makeManager(suite: "MenuBarTests-click")
        defer { defaults.removePersistentDomain(forName: "MenuBarTests-click") }

        let fake = FakeSeparator()
        manager.attach(fake)
        XCTAssertTrue(manager.isCollapsed)

        // The in-bar separator click routes through the same toggle.
        fake.onClick?()
        XCTAssertFalse(manager.isCollapsed)
    }

    // MARK: - Launch behavior

    func testLaunchForcesCollapsedEvenWhenPersistedExpanded() throws {
        let suite = "MenuBarTests-launch"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // Simulate a quit-while-expanded session.
        defaults.set(false, forKey: "mb.isCollapsed")

        let manager = MenuBarManager(defaults: defaults, keyPrefix: "mb")
        XCTAssertFalse(manager.isCollapsed, "reads the persisted expanded state")

        let fake = FakeSeparator()
        manager.launch(with: fake)

        XCTAssertTrue(manager.isCollapsed, "launch collapses regardless of persisted state")
        XCTAssertEqual(fake.length, MenuBarManager.collapsedLength)
    }

    // MARK: - Persistence round-trips

    func testAutoRehidePersistsAcrossReload() throws {
        let suite = "MenuBarTests-rehide-persist"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = MenuBarManager(defaults: defaults, keyPrefix: "mb")
        manager.setAutoRehide(30)

        let reloaded = MenuBarManager(defaults: defaults, keyPrefix: "mb")
        XCTAssertEqual(reloaded.autoRehideSeconds, 30)
    }

    func testCollapsedStatePersistsAcrossReload() throws {
        let suite = "MenuBarTests-collapsed-persist"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = MenuBarManager(defaults: defaults, keyPrefix: "mb")
        manager.attach(FakeSeparator())
        manager.expand()

        // A fresh manager (no launch enforcement) reads back the written state.
        let reloaded = MenuBarManager(defaults: defaults, keyPrefix: "mb")
        XCTAssertFalse(reloaded.isCollapsed)
    }

    func testSettingNeverPersistsZero() throws {
        let suite = "MenuBarTests-never"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = MenuBarManager(defaults: defaults, keyPrefix: "mb")
        manager.setAutoRehide(0)

        let reloaded = MenuBarManager(defaults: defaults, keyPrefix: "mb")
        XCTAssertEqual(reloaded.autoRehideSeconds, 0)
    }
}
