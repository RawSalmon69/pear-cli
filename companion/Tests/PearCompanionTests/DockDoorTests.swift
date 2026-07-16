import XCTest

@testable import PearCompanion

/// Logic-level cover for DockDoor's testable seams: dock-edge detection from
/// screen insets, AX↔AppKit rect flipping, preview-panel anchoring, the
/// `dockdoor.*` settings round-trip, the hover-intent decision, and the
/// Sendable app-snapshot mapping. No AX, no SCK, no live Dock — the hover
/// behavior itself needs a GUI (orchestrator smoke-tests).
@MainActor
final class DockDoorTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: - Dock edge from insets

    func testDockSideBottom() {
        let visible = CGRect(x: 0, y: 70, width: 1440, height: 830)
        XCTAssertEqual(DockGeometry.side(frame: screen, visibleFrame: visible), .bottom)
    }

    func testDockSideLeft() {
        let visible = CGRect(x: 80, y: 0, width: 1360, height: 900)
        XCTAssertEqual(DockGeometry.side(frame: screen, visibleFrame: visible), .left)
    }

    func testDockSideRight() {
        let visible = CGRect(x: 0, y: 0, width: 1360, height: 900)
        XCTAssertEqual(DockGeometry.side(frame: screen, visibleFrame: visible), .right)
    }

    func testDockSideAutoHiddenFallsBackToBottom() {
        // Only the menu bar is inset (24 pt < threshold) → no dock edge visible.
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 876)
        XCTAssertEqual(DockGeometry.side(frame: screen, visibleFrame: visible), .bottom)
    }

    // MARK: - AX (top-left) → AppKit (bottom-left) flip

    func testFlipToAppKitIsAReflection() {
        // A dock icon 50 pt tall sitting 840 pt from the top of a 900 pt screen
        // lands 10 pt up from the bottom in AppKit space.
        let ax = CGRect(x: 100, y: 840, width: 50, height: 50)
        let appKit = DockGeometry.flipToAppKit(ax, primaryMaxY: 900)
        XCTAssertEqual(appKit, CGRect(x: 100, y: 10, width: 50, height: 50))
        // Its own inverse.
        XCTAssertEqual(DockGeometry.flipToAppKit(appKit, primaryMaxY: 900), ax)
    }

    // MARK: - Panel anchoring

    private let panelSize = CGSize(width: 200, height: 120)

    func testPanelAboveBottomDockIcon() {
        let icon = CGRect(x: 100, y: 10, width: 50, height: 50) // AppKit y-up
        let origin = DockGeometry.panelOrigin(
            iconRect: icon, panelSize: panelSize, side: .bottom, visibleFrame: screen
        )
        // Centered on icon.midX (125) − width/2 (100); above icon.maxY (60) + gap (8).
        XCTAssertEqual(origin, CGPoint(x: 25, y: 68))
    }

    func testPanelRightOfLeftDockIcon() {
        let icon = CGRect(x: 5, y: 400, width: 50, height: 50)
        let origin = DockGeometry.panelOrigin(
            iconRect: icon, panelSize: panelSize, side: .left, visibleFrame: screen
        )
        // Right of icon.maxX (55) + gap (8); vertically centered on midY (425).
        XCTAssertEqual(origin, CGPoint(x: 63, y: 365))
    }

    func testPanelLeftOfRightDockIcon() {
        let icon = CGRect(x: 1385, y: 400, width: 50, height: 50)
        let origin = DockGeometry.panelOrigin(
            iconRect: icon, panelSize: panelSize, side: .right, visibleFrame: screen
        )
        // Left of icon.minX (1385) − width (200) − gap (8); centered on midY.
        XCTAssertEqual(origin, CGPoint(x: 1177, y: 365))
    }

    func testPanelClampsToVisibleFrameRightEdge() {
        let icon = CGRect(x: 1430, y: 10, width: 50, height: 50) // pushed off the right
        let origin = DockGeometry.panelOrigin(
            iconRect: icon, panelSize: panelSize, side: .bottom, visibleFrame: screen
        )
        // maxX (1440) − width (200) − margin (8) = 1232.
        XCTAssertEqual(origin.x, 1232)
    }

    func testPanelClampsToVisibleFrameLeftEdge() {
        let icon = CGRect(x: -40, y: 10, width: 50, height: 50)
        let origin = DockGeometry.panelOrigin(
            iconRect: icon, panelSize: panelSize, side: .bottom, visibleFrame: screen
        )
        // minX (0) + margin (8) = 8.
        XCTAssertEqual(origin.x, 8)
    }

    // MARK: - Settings round-trip (dockdoor.*)

    func testSettingsDefaultsWhenUnset() {
        let defaults = suite("dockdoor-defaults")
        defer { defaults.removePersistentDomain(forName: "dockdoor-defaults") }

        XCTAssertEqual(DockDoorSettings.hoverDelay(defaults), 200)
        XCTAssertEqual(DockDoorSettings.previewSize(defaults), .medium)
        XCTAssertTrue(DockDoorSettings.showTitles(defaults))
    }

    func testSettingsRoundTrip() {
        let defaults = suite("dockdoor-roundtrip")
        defer { defaults.removePersistentDomain(forName: "dockdoor-roundtrip") }

        defaults.set(120.0, forKey: DockDoorSettings.Key.hoverDelay)
        defaults.set(DockPreviewSize.large.rawValue, forKey: DockDoorSettings.Key.previewSize)
        defaults.set(false, forKey: DockDoorSettings.Key.showTitles)

        XCTAssertEqual(DockDoorSettings.hoverDelay(defaults), 120)
        XCTAssertEqual(DockDoorSettings.previewSize(defaults), .large)
        XCTAssertFalse(DockDoorSettings.showTitles(defaults))
    }

    func testHoverDelayClampsOutOfRange() {
        let defaults = suite("dockdoor-clamp")
        defer { defaults.removePersistentDomain(forName: "dockdoor-clamp") }

        defaults.set(9999.0, forKey: DockDoorSettings.Key.hoverDelay)
        XCTAssertEqual(DockDoorSettings.hoverDelay(defaults), 500) // upper bound

        defaults.set(-50.0, forKey: DockDoorSettings.Key.hoverDelay)
        XCTAssertEqual(DockDoorSettings.hoverDelay(defaults), 0) // lower bound
    }

    func testGarbagePreviewSizeFallsBackToDefault() {
        let defaults = suite("dockdoor-garbage")
        defer { defaults.removePersistentDomain(forName: "dockdoor-garbage") }

        defaults.set("nonsense", forKey: DockDoorSettings.Key.previewSize)
        XCTAssertEqual(DockDoorSettings.previewSize(defaults), .medium)
    }

    func testPreviewSizeDimensionsIncrease() {
        XCTAssertLessThan(DockPreviewSize.small.maxDimension, DockPreviewSize.medium.maxDimension)
        XCTAssertLessThan(DockPreviewSize.medium.maxDimension, DockPreviewSize.large.maxDimension)
    }

    // MARK: - Hover-intent decision

    func testHoverActionHideWhenNothingHovered() {
        XCTAssertEqual(DockHoverController.action(hoveredPID: nil, shownPID: nil), .hide)
        XCTAssertEqual(DockHoverController.action(hoveredPID: nil, shownPID: 42), .hide)
    }

    func testHoverActionShowForNewApp() {
        XCTAssertEqual(DockHoverController.action(hoveredPID: 42, shownPID: nil), .show)
        XCTAssertEqual(DockHoverController.action(hoveredPID: 42, shownPID: 7), .show)
    }

    func testHoverActionKeepForSameApp() {
        XCTAssertEqual(DockHoverController.action(hoveredPID: 42, shownPID: 42), .keep)
    }

    // MARK: - Sendable app snapshot

    func testAppSnapshotMapsFromRunningApplication() {
        // Faithfully copies the value fields off the live app. (The test runner
        // reports processIdentifier == -1 for NSRunningApplication.current, so we
        // assert against the source object, not getpid().)
        let current = NSRunningApplication.current
        let snapshot = DockApp(current)
        XCTAssertEqual(snapshot.pid, current.processIdentifier)
        XCTAssertEqual(snapshot.bundleIdentifier, current.bundleIdentifier)
        XCTAssertEqual(snapshot.name, current.localizedName ?? "")
    }

    func testAppSnapshotValueEquality() {
        let a = DockApp(pid: 321, bundleIdentifier: "com.example.app", name: "Example")
        let b = DockApp(pid: 321, bundleIdentifier: "com.example.app", name: "Example")
        let c = DockApp(pid: 322, bundleIdentifier: "com.example.app", name: "Example")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - CGWindowList fallback parsing (zero-AX apps)

    private func cgEntry(pid: Int32, layer: Int, x: Double, y: Double, w: Double, h: Double, name: String?) -> [String: Any] {
        var entry: [String: Any] = [
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h],
        ]
        if let name { entry[kCGWindowName as String] = name }
        return entry
    }

    func testFallbackKeepsOwnedNormalLayerWindow() {
        let list = [cgEntry(pid: 501, layer: 0, x: 10, y: 20, w: 800, h: 600, name: "Doc")]
        let parsed = DockWindows.parseFallback(list, pids: [501])
        XCTAssertEqual(parsed, [DockWindows.CGFallbackWindow(title: "Doc", frame: CGRect(x: 10, y: 20, width: 800, height: 600))])
    }

    func testFallbackFiltersByPID() {
        let list = [cgEntry(pid: 999, layer: 0, x: 0, y: 0, w: 400, h: 300, name: "Other")]
        XCTAssertTrue(DockWindows.parseFallback(list, pids: [501]).isEmpty)
    }

    func testFallbackSkipsNonZeroLayer() {
        // Menus, the Dock, and shadows sit on non-zero layers and must not show.
        let list = [cgEntry(pid: 501, layer: 25, x: 0, y: 0, w: 400, h: 300, name: "Menu")]
        XCTAssertTrue(DockWindows.parseFallback(list, pids: [501]).isEmpty)
    }

    func testFallbackSkipsDegenerateFrame() {
        let list = [cgEntry(pid: 501, layer: 0, x: 0, y: 0, w: 1, h: 1, name: "Sliver")]
        XCTAssertTrue(DockWindows.parseFallback(list, pids: [501]).isEmpty)
    }

    func testFallbackMatchesAnyPIDInSet() {
        // Multi-instance apps contribute several pids; a window owned by any of
        // them is kept.
        let list = [
            cgEntry(pid: 700, layer: 0, x: 0, y: 0, w: 500, h: 400, name: "A"),
            cgEntry(pid: 701, layer: 0, x: 5, y: 5, w: 500, h: 400, name: "B"),
        ]
        let parsed = DockWindows.parseFallback(list, pids: [700, 701])
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(Set(parsed.map(\.title)), ["A", "B"])
    }

    func testFallbackEmptyNameTolerated() {
        let list = [cgEntry(pid: 501, layer: 0, x: 0, y: 0, w: 500, h: 400, name: nil)]
        let parsed = DockWindows.parseFallback(list, pids: [501])
        XCTAssertEqual(parsed.first?.title, "")
    }

    // MARK: - Switcher cycle order

    func testSwitcherOpenIndexForwardPicksNext() {
        XCTAssertEqual(DockSwitcherCycle.openIndex(count: 5, backward: false), 1)
        XCTAssertEqual(DockSwitcherCycle.openIndex(count: 1, backward: false), 0)
        XCTAssertEqual(DockSwitcherCycle.openIndex(count: 0, backward: false), -1)
    }

    func testSwitcherOpenIndexBackwardPicksLast() {
        XCTAssertEqual(DockSwitcherCycle.openIndex(count: 5, backward: true), 4)
        XCTAssertEqual(DockSwitcherCycle.openIndex(count: 1, backward: true), 0)
        XCTAssertEqual(DockSwitcherCycle.openIndex(count: 0, backward: true), -1)
    }

    func testSwitcherAdvanceForwardWraps() {
        XCTAssertEqual(DockSwitcherCycle.advance(from: 0, count: 5, backward: false), 1)
        XCTAssertEqual(DockSwitcherCycle.advance(from: 4, count: 5, backward: false), 0) // wrap
    }

    func testSwitcherAdvanceBackwardWraps() {
        XCTAssertEqual(DockSwitcherCycle.advance(from: 4, count: 5, backward: true), 3)
        XCTAssertEqual(DockSwitcherCycle.advance(from: 0, count: 5, backward: true), 4) // wrap
    }

    func testSwitcherAdvanceDegenerateCounts() {
        XCTAssertEqual(DockSwitcherCycle.advance(from: 0, count: 1, backward: false), 0)
        XCTAssertEqual(DockSwitcherCycle.advance(from: 0, count: 1, backward: true), 0)
        XCTAssertEqual(DockSwitcherCycle.advance(from: 3, count: 0, backward: false), -1)
    }

    func testSwitcherScopeSettingsRoundTrip() {
        let defaults = suite("dockdoor-switcher")
        defer { defaults.removePersistentDomain(forName: "dockdoor-switcher") }

        XCTAssertFalse(DockDoorSettings.switcherEnabled(defaults)) // default off (opt-in)
        XCTAssertEqual(DockDoorSettings.switcherScope(defaults), .allWindows)

        defaults.set(true, forKey: DockDoorSettings.Key.switcherEnabled)
        defaults.set(DockSwitcherScope.activeApp.rawValue, forKey: DockDoorSettings.Key.switcherScope)
        XCTAssertTrue(DockDoorSettings.switcherEnabled(defaults))
        XCTAssertEqual(DockDoorSettings.switcherScope(defaults), .activeApp)

        defaults.set("nonsense", forKey: DockDoorSettings.Key.switcherScope)
        XCTAssertEqual(DockDoorSettings.switcherScope(defaults), .allWindows) // fallback
    }

    // MARK: - Helpers

    private func suite(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
