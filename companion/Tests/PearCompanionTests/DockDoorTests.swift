import ApplicationServices
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

    // Auto placement reproduces the per-Dock-side default (the default that
    // bottom-Dock users must keep). `resolvedPlacement(.auto, side:)` maps the
    // detected edge to an anchor, then `panelOrigin` places it.

    func testPanelAboveBottomDockIcon() {
        let icon = CGRect(x: 100, y: 10, width: 50, height: 50) // AppKit y-up
        let placement = DockGeometry.resolvedPlacement(.auto, side: .bottom)
        let origin = DockGeometry.panelOrigin(
            iconRect: icon, panelSize: panelSize, placement: placement, visibleFrame: screen
        )
        // Centered on icon.midX (125) − width/2 (100); above icon.maxY (60) + gap (8).
        XCTAssertEqual(origin, CGPoint(x: 25, y: 68))
    }

    func testPanelRightOfLeftDockIcon() {
        let icon = CGRect(x: 5, y: 400, width: 50, height: 50)
        let placement = DockGeometry.resolvedPlacement(.auto, side: .left)
        let origin = DockGeometry.panelOrigin(
            iconRect: icon, panelSize: panelSize, placement: placement, visibleFrame: screen
        )
        // Right of icon.maxX (55) + gap (8); vertically centered on midY (425).
        XCTAssertEqual(origin, CGPoint(x: 63, y: 365))
    }

    func testPanelLeftOfRightDockIcon() {
        let icon = CGRect(x: 1385, y: 400, width: 50, height: 50)
        let placement = DockGeometry.resolvedPlacement(.auto, side: .right)
        let origin = DockGeometry.panelOrigin(
            iconRect: icon, panelSize: panelSize, placement: placement, visibleFrame: screen
        )
        // Left of icon.minX (1385) − width (200) − gap (8); centered on midY.
        XCTAssertEqual(origin, CGPoint(x: 1177, y: 365))
    }

    func testPanelClampsToVisibleFrameRightEdge() {
        let icon = CGRect(x: 1430, y: 10, width: 50, height: 50) // pushed off the right
        let origin = DockGeometry.panelOrigin(
            iconRect: icon, panelSize: panelSize, placement: .above, visibleFrame: screen
        )
        // maxX (1440) − width (200) − margin (8) = 1232.
        XCTAssertEqual(origin.x, 1232)
    }

    func testPanelClampsToVisibleFrameLeftEdge() {
        let icon = CGRect(x: -40, y: 10, width: 50, height: 50)
        let origin = DockGeometry.panelOrigin(
            iconRect: icon, panelSize: panelSize, placement: .above, visibleFrame: screen
        )
        // minX (0) + margin (8) = 8.
        XCTAssertEqual(origin.x, 8)
    }

    // MARK: - Screen selection (never the focused-window screen)

    func testScreenIndexPicksMostOverlappingScreen() {
        let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        // Icon sits mostly on the right screen.
        let icon = CGRect(x: 1460, y: 500, width: 60, height: 48)
        XCTAssertEqual(DockGeometry.screenIndex(forIconRect: icon, screenFrames: [left, right]), 1)
    }

    func testScreenIndexFallsBackToNearestWhenIconClearsEveryScreen() {
        // An auto-hidden Dock parks its icon a few points past the screen edge,
        // so the rect overlaps nothing — pick the nearest screen, not screen 0.
        let a = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let b = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let icon = CGRect(x: 3380, y: 540, width: 60, height: 48) // just past b's right edge
        XCTAssertEqual(DockGeometry.screenIndex(forIconRect: icon, screenFrames: [a, b]), 1)
    }

    func testScreenIndexEmptyScreensIsNil() {
        XCTAssertNil(DockGeometry.screenIndex(forIconRect: .zero, screenFrames: []))
    }

    func testScreenIndexRegressionOwnerAutoHiddenRightDock() {
        // The reported bug's real geometry: a right-side auto-hidden Dock on the
        // primary (0,0,1512,982) with a second display ABOVE it (−211,982,…). The
        // hovered icon's flipped rect sticks ~58 pt PAST the primary's right edge,
        // so a center-point test misses every screen and the old code fell back to
        // NSScreen.main. screenIndex must still land on the Dock's screen (index 0)
        // via the sliver of overlap — never the other display.
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let above = CGRect(x: -211, y: 982, width: 1920, height: 1080)
        let icon = CGRect(x: 1510, y: 821, width: 60, height: 48) // 2 pt overlap on primary
        XCTAssertEqual(DockGeometry.screenIndex(forIconRect: icon, screenFrames: [primary, above]), 0)
    }

    // MARK: - Manual placement overrides

    func testResolvedPlacementAutoFollowsDockSide() {
        XCTAssertEqual(DockGeometry.resolvedPlacement(.auto, side: .bottom), .above)
        XCTAssertEqual(DockGeometry.resolvedPlacement(.auto, side: .left), .right)
        XCTAssertEqual(DockGeometry.resolvedPlacement(.auto, side: .right), .left)
    }

    func testResolvedPlacementOverrideIgnoresDockSide() {
        // A manual choice forces that anchor whatever edge the Dock is on.
        for side in [DockSide.bottom, .left, .right] {
            XCTAssertEqual(DockGeometry.resolvedPlacement(.above, side: side), .above)
            XCTAssertEqual(DockGeometry.resolvedPlacement(.below, side: side), .below)
            XCTAssertEqual(DockGeometry.resolvedPlacement(.left, side: side), .left)
            XCTAssertEqual(DockGeometry.resolvedPlacement(.right, side: side), .right)
        }
    }

    func testRightDockAboveOverrideLandsAboveIcon() {
        // The owner's case: a right-side Dock whose auto panel sits over content
        // (auto would be `.left` → left of the icon, vertically centered at y 365).
        // The "Above" override lifts it above the icon instead: maxY (450) + gap
        // (8) = 458. Centering a 200-wide panel on a right-edge icon overflows the
        // screen, so x clamps inside the frame (1440 − 200 − 8 = 1232) — still
        // above the icon, never left of it.
        let icon = CGRect(x: 1385, y: 400, width: 50, height: 50)
        let placement = DockGeometry.resolvedPlacement(.above, side: .right)
        let origin = DockGeometry.panelOrigin(
            iconRect: icon, panelSize: panelSize, placement: placement, visibleFrame: screen
        )
        XCTAssertEqual(origin, CGPoint(x: 1232, y: 458))
    }

    func testPanelBelowOverride() {
        let icon = CGRect(x: 100, y: 400, width: 50, height: 50)
        let origin = DockGeometry.panelOrigin(
            iconRect: icon, panelSize: panelSize, placement: .below, visibleFrame: screen
        )
        // Centered on midX (125) − 100 = 25; below minY (400) − height (120) − gap (8) = 272.
        XCTAssertEqual(origin, CGPoint(x: 25, y: 272))
    }

    func testPanelGapPushesFurtherOffIcon() {
        // A larger gap moves the panel further from the icon (the owner's ask:
        // push it off window content). Left placement subtracts width + gap.
        let icon = CGRect(x: 1385, y: 400, width: 50, height: 50)
        let origin = DockGeometry.panelOrigin(
            iconRect: icon, panelSize: panelSize, placement: .left, visibleFrame: screen, gap: 40
        )
        // minX (1385) − width (200) − gap (40) = 1145.
        XCTAssertEqual(origin.x, 1145)
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

    func testPlacementAndGapDefaultsWhenUnset() {
        let defaults = suite("dockdoor-placement-defaults")
        defer { defaults.removePersistentDomain(forName: "dockdoor-placement-defaults") }

        // Default is .auto with the former hard-coded gap, so bottom-Dock users
        // are unaffected.
        XCTAssertEqual(DockDoorSettings.previewPlacement(defaults), .auto)
        XCTAssertEqual(DockDoorSettings.previewGap(defaults), 8)
    }

    func testPlacementAndGapRoundTrip() {
        let defaults = suite("dockdoor-placement-roundtrip")
        defer { defaults.removePersistentDomain(forName: "dockdoor-placement-roundtrip") }

        defaults.set(DockPreviewPlacement.above.rawValue, forKey: DockDoorSettings.Key.previewPlacement)
        defaults.set(32.0, forKey: DockDoorSettings.Key.previewGap)
        XCTAssertEqual(DockDoorSettings.previewPlacement(defaults), .above)
        XCTAssertEqual(DockDoorSettings.previewGap(defaults), 32)
    }

    func testGarbagePlacementFallsBackToAuto() {
        let defaults = suite("dockdoor-placement-garbage")
        defer { defaults.removePersistentDomain(forName: "dockdoor-placement-garbage") }

        defaults.set("sideways", forKey: DockDoorSettings.Key.previewPlacement)
        XCTAssertEqual(DockDoorSettings.previewPlacement(defaults), .auto)
    }

    func testPreviewGapClampsOutOfRange() {
        let defaults = suite("dockdoor-gap-clamp")
        defer { defaults.removePersistentDomain(forName: "dockdoor-gap-clamp") }

        defaults.set(9999.0, forKey: DockDoorSettings.Key.previewGap)
        XCTAssertEqual(DockDoorSettings.previewGap(defaults), 80) // upper bound

        defaults.set(-50.0, forKey: DockDoorSettings.Key.previewGap)
        XCTAssertEqual(DockDoorSettings.previewGap(defaults), 0) // lower bound
    }

    func testKeepOpenDefaultsOffAndRoundTrips() {
        let defaults = suite("dockdoor-keepopen")
        defer { defaults.removePersistentDomain(forName: "dockdoor-keepopen") }

        XCTAssertFalse(DockDoorSettings.keepPanelOpen(defaults))
        defaults.set(true, forKey: DockDoorSettings.Key.keepOpen)
        XCTAssertTrue(DockDoorSettings.keepPanelOpen(defaults))
    }

    // MARK: - Keep-open click-outside dismissal

    func testClickInsidePanelDoesNotDismiss() {
        let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
        XCTAssertFalse(DockHoverController.clickDismisses(
            location: CGPoint(x: 250, y: 200), panelFrame: frame))
    }

    func testClickOutsidePanelDismisses() {
        let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
        XCTAssertTrue(DockHoverController.clickDismisses(
            location: CGPoint(x: 50, y: 50), panelFrame: frame))
        XCTAssertTrue(DockHoverController.clickDismisses(
            location: CGPoint(x: 500, y: 200), panelFrame: frame))
    }

    func testClickWithHiddenPanelNeverDismisses() {
        // nil frame = panel not visible; the monitors shouldn't be installed
        // then, but the decision is safe regardless.
        XCTAssertFalse(DockHoverController.clickDismisses(
            location: CGPoint(x: 50, y: 50), panelFrame: nil))
    }

    // MARK: - Hover-intent decision

    func testHoverActionHideWhenNothingHovered() {
        XCTAssertEqual(DockHoverController.action(hoveredPID: nil, shownPID: nil, pendingPID: nil), .hide)
        XCTAssertEqual(DockHoverController.action(hoveredPID: nil, shownPID: 42, pendingPID: nil), .hide)
        XCTAssertEqual(DockHoverController.action(hoveredPID: nil, shownPID: nil, pendingPID: 42), .hide)
    }

    func testHoverActionShowForNewApp() {
        XCTAssertEqual(DockHoverController.action(hoveredPID: 42, shownPID: nil, pendingPID: nil), .show)
        XCTAssertEqual(DockHoverController.action(hoveredPID: 42, shownPID: 7, pendingPID: nil), .show)
        XCTAssertEqual(DockHoverController.action(hoveredPID: 42, shownPID: nil, pendingPID: 7), .show)
    }

    func testHoverActionKeepForSameApp() {
        XCTAssertEqual(DockHoverController.action(hoveredPID: 42, shownPID: 42, pendingPID: nil), .keep)
    }

    func testHoverActionKeepForPendingApp() {
        // A cold app's retry loop is in flight (nothing shown yet): re-hovering
        // the same icon must NOT restart the retry budget from zero.
        XCTAssertEqual(DockHoverController.action(hoveredPID: 42, shownPID: nil, pendingPID: 42), .keep)
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

    // MARK: - Auto-hidden Dock edge inference (icon-rect fallback)

    func testSideInsetDetectionStillWinsWhenInsetPresent() {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let leftInset = CGRect(x: 70, y: 0, width: 1370, height: 875)
        // Inset says left; a bottom-hugging icon rect must not override it.
        let icon = CGRect(x: 700, y: 2, width: 50, height: 50)
        XCTAssertEqual(DockGeometry.side(frame: frame, visibleFrame: leftInset, iconRect: icon), .left)
    }

    func testSideFallsBackToIconEdgeWhenAutoHidden() {
        // Auto-hidden Dock: visibleFrame ≈ frame, no inset to detect.
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875) // menu bar only

        let leftIcon = CGRect(x: 4, y: 400, width: 50, height: 50)
        XCTAssertEqual(DockGeometry.side(frame: frame, visibleFrame: visible, iconRect: leftIcon), .left)

        let rightIcon = CGRect(x: 1386, y: 400, width: 50, height: 50)
        XCTAssertEqual(DockGeometry.side(frame: frame, visibleFrame: visible, iconRect: rightIcon), .right)

        let bottomIcon = CGRect(x: 700, y: 4, width: 50, height: 50)
        XCTAssertEqual(DockGeometry.side(frame: frame, visibleFrame: visible, iconRect: bottomIcon), .bottom)

        // No icon rect available → the old .bottom default.
        XCTAssertEqual(DockGeometry.side(frame: frame, visibleFrame: visible), .bottom)
    }

    // MARK: - Thumbnail match ceiling

    func testMatchDistanceIsL1CornerPlusSize() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 10, y: 20, width: 130, height: 140)
        XCTAssertEqual(DockThumbnailer.matchDistance(a, b), 10 + 20 + 30 + 40)
        XCTAssertEqual(DockThumbnailer.matchDistance(a, a), 0)
    }

    func testMatchCeilingRejectsZeroFrameTargetAgainstRealWindow() {
        // A minimized/off-Space window's zero frame must never "closest-match"
        // a real on-screen window and steal its thumbnail.
        let zero = CGRect.zero
        let real = CGRect(x: 200, y: 150, width: 900, height: 600)
        XCTAssertGreaterThan(DockThumbnailer.matchDistance(zero, real), DockThumbnailer.maxMatchDistance)
        // While a live window mid-move stays within it.
        let drifted = real.offsetBy(dx: 24, dy: -18)
        XCTAssertLessThanOrEqual(DockThumbnailer.matchDistance(real, drifted), DockThumbnailer.maxMatchDistance)
    }

    // MARK: - Window filter policy (shouldShow)

    private let standardSubrole = kAXStandardWindowSubrole as String

    func testShouldShowKeepsStandardWindowWithSize() {
        XCTAssertTrue(DockWindows.shouldShow(
            subrole: standardSubrole, minimized: false, fullScreen: false,
            size: CGSize(width: 800, height: 600)
        ))
    }

    func testShouldShowDropsForeignSubrole() {
        // A sheet subrole ("AXSheet") is never a previewable top-level window.
        XCTAssertFalse(DockWindows.shouldShow(
            subrole: "AXSheet", minimized: false, fullScreen: false,
            size: CGSize(width: 800, height: 600)
        ))
    }

    func testShouldShowKeepsWindowWhoseSizeReadFailed() {
        // Activation-state gap: a background app's cross-Space geometry read
        // can FAIL (nil) until the app is activated — the window is real, so
        // it is kept as an icon tile instead of the app showing "no windows".
        XCTAssertTrue(DockWindows.shouldShow(
            subrole: standardSubrole, minimized: false, fullScreen: false, size: nil
        ))
    }

    func testShouldShowStillDropsDegenerateMeasuredSize() {
        // A SUCCESSFUL read of a junk size keeps falling to the > 1 pt gate.
        XCTAssertFalse(DockWindows.shouldShow(
            subrole: standardSubrole, minimized: false, fullScreen: false,
            size: CGSize(width: 1, height: 1)
        ))
        XCTAssertFalse(DockWindows.shouldShow(
            subrole: standardSubrole, minimized: false, fullScreen: false, size: .zero
        ))
    }

    func testShouldShowKeepsMinimizedWithoutSize() {
        XCTAssertTrue(DockWindows.shouldShow(
            subrole: standardSubrole, minimized: true, fullScreen: false, size: nil
        ))
    }

    func testShouldShowKeepsFullScreenWithoutSize() {
        // The fix: a fullscreen window whose cross-Space size read came back
        // empty is still kept instead of being dropped by the size gate.
        XCTAssertTrue(DockWindows.shouldShow(
            subrole: standardSubrole, minimized: false, fullScreen: true, size: nil
        ))
    }

    func testShouldShowKeepsWindowWithUnreadableSubrole() {
        // A nil subrole (read failed) is tolerated, not filtered.
        XCTAssertTrue(DockWindows.shouldShow(
            subrole: nil, minimized: false, fullScreen: false, size: CGSize(width: 400, height: 300)
        ))
    }

    func testShouldShowFullScreenStillHonorsSubroleGate() {
        // Fullscreen bypasses the SIZE gate, never the subrole allow-list.
        XCTAssertFalse(DockWindows.shouldShow(
            subrole: "AXSheet", minimized: false, fullScreen: true, size: nil
        ))
    }

    func testShouldShowKeepsFloatingWindow() {
        // 2.6.3 widening: utility / tool / inspector windows report a floating
        // subrole and are now shown (with a real size), not dropped.
        XCTAssertTrue(DockWindows.shouldShow(
            subrole: kAXFloatingWindowSubrole as String, minimized: false, fullScreen: false,
            size: CGSize(width: 300, height: 500)
        ))
        XCTAssertTrue(DockWindows.shouldShow(
            subrole: kAXSystemFloatingWindowSubrole as String, minimized: false, fullScreen: false,
            size: CGSize(width: 300, height: 500)
        ))
    }

    func testShouldShowStillDropsSheetSubrole() {
        // The widening did not open the gate to sheets / other transient surfaces.
        XCTAssertFalse(DockWindows.shouldShow(
            subrole: "AXSheet", minimized: false, fullScreen: false,
            size: CGSize(width: 300, height: 500)
        ))
    }

    // MARK: - Helpers

    private func suite(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
