import XCTest
@testable import PearCompanion

@MainActor
final class MenuBarManagerTests: XCTestCase {
    /// In-memory stand-in for the status-bar surface, so state logic is
    /// exercised without a live menu bar.
    private final class FakeSurface: MenuBarSurface {
        var onToggle: (() -> Void)?
        var onOptionToggle: (() -> Void)?
        var separatorLength: CGFloat = 0
        var alwaysHiddenLength: CGFloat = 0
        private(set) var lastChevronCollapsed: Bool?
        private(set) var alwaysHiddenActive = false
        private(set) var removed = false
        /// Drives the position guard; valid (chevron right of separator) by default.
        var chevronRightOfSeparator = true

        func setChevron(collapsed: Bool) { lastChevronCollapsed = collapsed }
        var isChevronRightOfSeparator: Bool { chevronRightOfSeparator }
        func setAlwaysHiddenEnabled(_ enabled: Bool) { alwaysHiddenActive = enabled }
        func removeAll() { removed = true }
    }

    private func makeManager(suite: String) throws -> (MenuBarManager, UserDefaults) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (MenuBarManager(defaults: defaults, keyPrefix: "mb"), defaults)
    }

    // MARK: - Defaults

    func testDefaults() throws {
        let (manager, defaults) = try makeManager(suite: "MenuBarTests-defaults")
        defer { defaults.removePersistentDomain(forName: "MenuBarTests-defaults") }

        XCTAssertTrue(manager.isCollapsed)
        XCTAssertEqual(manager.autoRehideSeconds, 10)
        XCTAssertFalse(manager.alwaysHiddenEnabled)
        XCTAssertTrue(manager.optionRevealEnabled)
    }

    // MARK: - Pure mechanism functions

    func testSeparatorLength() {
        XCTAssertEqual(MenuBarManager.separatorLength(collapsed: true), MenuBarManager.collapsedLength)
        XCTAssertEqual(MenuBarManager.separatorLength(collapsed: false), MenuBarManager.expandedLength)
        // Collapsed must be huge enough to shove neighbors off-screen.
        XCTAssertGreaterThan(MenuBarManager.collapsedLength, 1000)
    }

    func testAlwaysHiddenSeparatorLength() {
        // Revealed shrinks the zone open; hidden inflates it off-screen.
        XCTAssertEqual(MenuBarManager.alwaysHiddenSeparatorLength(revealed: true), MenuBarManager.expandedLength)
        XCTAssertEqual(MenuBarManager.alwaysHiddenSeparatorLength(revealed: false), MenuBarManager.collapsedLength)
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

    // MARK: - State applied to the surface

    func testAttachAppliesCollapsedLengthAndChevron() throws {
        let (manager, defaults) = try makeManager(suite: "MenuBarTests-attach")
        defer { defaults.removePersistentDomain(forName: "MenuBarTests-attach") }

        let fake = FakeSurface()
        manager.attach(fake)

        XCTAssertEqual(fake.separatorLength, MenuBarManager.collapsedLength)
        XCTAssertEqual(fake.lastChevronCollapsed, true)
    }

    func testToggleExpandsThenCollapses() throws {
        let (manager, defaults) = try makeManager(suite: "MenuBarTests-toggle")
        defer { defaults.removePersistentDomain(forName: "MenuBarTests-toggle") }

        let fake = FakeSurface()
        manager.attach(fake)

        manager.toggle()
        XCTAssertFalse(manager.isCollapsed)
        XCTAssertEqual(fake.separatorLength, MenuBarManager.expandedLength)
        XCTAssertEqual(fake.lastChevronCollapsed, false)

        manager.toggle()
        XCTAssertTrue(manager.isCollapsed)
        XCTAssertEqual(fake.separatorLength, MenuBarManager.collapsedLength)
        XCTAssertEqual(fake.lastChevronCollapsed, true)
    }

    func testChevronClickCallbackTogglesState() throws {
        let (manager, defaults) = try makeManager(suite: "MenuBarTests-click")
        defer { defaults.removePersistentDomain(forName: "MenuBarTests-click") }

        let fake = FakeSurface()
        manager.attach(fake)
        XCTAssertTrue(manager.isCollapsed)

        // The chevron left-click routes through the same toggle.
        fake.onToggle?()
        XCTAssertFalse(manager.isCollapsed)
    }

    // MARK: - Self-hide guard

    func testCollapseRefusedWhenChevronLeftOfSeparator() throws {
        let (manager, defaults) = try makeManager(suite: "MenuBarTests-guard")
        defer { defaults.removePersistentDomain(forName: "MenuBarTests-guard") }

        let fake = FakeSurface()
        manager.attach(fake)
        manager.expand()
        XCTAssertFalse(manager.isCollapsed)

        // Arrangement would push the chevron off-screen: collapse must be refused.
        fake.chevronRightOfSeparator = false
        manager.collapse()
        XCTAssertFalse(manager.isCollapsed, "must stay expanded when the chevron isn't right of the separator")
        XCTAssertEqual(fake.separatorLength, MenuBarManager.expandedLength)

        // Once the arrangement is valid again, collapse proceeds.
        fake.chevronRightOfSeparator = true
        manager.collapse()
        XCTAssertTrue(manager.isCollapsed)
    }

    // MARK: - Always-hidden zone

    func testEnablingAlwaysHiddenCreatesZoneHidden() throws {
        let (manager, defaults) = try makeManager(suite: "MenuBarTests-ah-enable")
        defer { defaults.removePersistentDomain(forName: "MenuBarTests-ah-enable") }

        let fake = FakeSurface()
        manager.attach(fake)
        manager.setAlwaysHiddenEnabled(true)

        XCTAssertTrue(manager.alwaysHiddenEnabled)
        XCTAssertTrue(fake.alwaysHiddenActive)
        // Zone starts hidden even though the item now exists.
        XCTAssertEqual(fake.alwaysHiddenLength, MenuBarManager.collapsedLength)
    }

    func testDisablingAlwaysHiddenDropsZone() throws {
        let (manager, defaults) = try makeManager(suite: "MenuBarTests-ah-disable")
        defer { defaults.removePersistentDomain(forName: "MenuBarTests-ah-disable") }

        let fake = FakeSurface()
        manager.attach(fake)
        manager.setAlwaysHiddenEnabled(true)
        manager.setAlwaysHiddenEnabled(false)

        XCTAssertFalse(manager.alwaysHiddenEnabled)
        XCTAssertFalse(fake.alwaysHiddenActive)
    }

    func testRevealAllRevealsBothZones() throws {
        let (manager, defaults) = try makeManager(suite: "MenuBarTests-revealall")
        defer { defaults.removePersistentDomain(forName: "MenuBarTests-revealall") }

        let fake = FakeSurface()
        manager.attach(fake)
        manager.setAlwaysHiddenEnabled(true)
        XCTAssertTrue(manager.isCollapsed)

        fake.onOptionToggle?()
        XCTAssertFalse(manager.isCollapsed)
        XCTAssertEqual(fake.separatorLength, MenuBarManager.expandedLength)
        XCTAssertEqual(fake.alwaysHiddenLength, MenuBarManager.expandedLength, "always-hidden zone revealed too")
    }

    func testCollapseReHidesAlwaysHiddenZone() throws {
        let (manager, defaults) = try makeManager(suite: "MenuBarTests-ah-rehide")
        defer { defaults.removePersistentDomain(forName: "MenuBarTests-ah-rehide") }

        let fake = FakeSurface()
        manager.attach(fake)
        manager.setAlwaysHiddenEnabled(true)
        manager.revealAll()
        XCTAssertEqual(fake.alwaysHiddenLength, MenuBarManager.expandedLength)

        manager.collapse()
        XCTAssertTrue(manager.isCollapsed)
        XCTAssertEqual(fake.alwaysHiddenLength, MenuBarManager.collapsedLength, "collapse hides the always-hidden zone again")
    }

    func testRevealAllFallsBackToToggleWhenOptionDisabled() throws {
        let (manager, defaults) = try makeManager(suite: "MenuBarTests-noopt")
        defer { defaults.removePersistentDomain(forName: "MenuBarTests-noopt") }

        let fake = FakeSurface()
        manager.attach(fake)
        manager.setAlwaysHiddenEnabled(true)
        manager.setOptionReveal(false)
        XCTAssertTrue(manager.isCollapsed)

        // With ⌥-reveal off, ⌥-click behaves like a plain toggle: expands the
        // hideable zone but leaves the always-hidden zone hidden.
        manager.revealAll()
        XCTAssertFalse(manager.isCollapsed)
        XCTAssertEqual(fake.alwaysHiddenLength, MenuBarManager.collapsedLength)
    }

    // MARK: - Launch / teardown

    func testLaunchForcesCollapsedEvenWhenPersistedExpanded() throws {
        let suite = "MenuBarTests-launch"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // Simulate a quit-while-expanded session.
        defaults.set(false, forKey: "mb.isCollapsed")

        let manager = MenuBarManager(defaults: defaults, keyPrefix: "mb")
        XCTAssertFalse(manager.isCollapsed, "reads the persisted expanded state")

        let fake = FakeSurface()
        manager.launch(with: fake)

        XCTAssertTrue(manager.isCollapsed, "launch collapses regardless of persisted state")
        XCTAssertEqual(fake.separatorLength, MenuBarManager.collapsedLength)
    }

    func testUninstallRevealsThenRemovesSurface() throws {
        let (manager, defaults) = try makeManager(suite: "MenuBarTests-uninstall")
        defer { defaults.removePersistentDomain(forName: "MenuBarTests-uninstall") }

        let fake = FakeSurface()
        manager.launch(with: fake)
        manager.setAlwaysHiddenEnabled(true)
        XCTAssertTrue(manager.isCollapsed)

        manager.uninstallSurface()

        // Reveal-then-remove: both zones open before the items drop, so nothing
        // stays hidden after the tool is disabled.
        XCTAssertFalse(manager.isCollapsed)
        XCTAssertEqual(fake.separatorLength, MenuBarManager.expandedLength)
        XCTAssertEqual(fake.alwaysHiddenLength, MenuBarManager.expandedLength)
        XCTAssertTrue(fake.removed)
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
        manager.attach(FakeSurface())
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

    func testAlwaysHiddenEnabledPersistsAcrossReload() throws {
        let suite = "MenuBarTests-ah-persist"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = MenuBarManager(defaults: defaults, keyPrefix: "mb")
        manager.setAlwaysHiddenEnabled(true)

        let reloaded = MenuBarManager(defaults: defaults, keyPrefix: "mb")
        XCTAssertTrue(reloaded.alwaysHiddenEnabled)
    }

    func testOptionRevealPersistsAcrossReload() throws {
        let suite = "MenuBarTests-opt-persist"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = MenuBarManager(defaults: defaults, keyPrefix: "mb")
        manager.setOptionReveal(false)

        let reloaded = MenuBarManager(defaults: defaults, keyPrefix: "mb")
        XCTAssertFalse(reloaded.optionRevealEnabled)
    }
}
