import Carbon.HIToolbox
import XCTest
@testable import PearCompanion

final class WindowSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "WindowSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Ring defaults

    func testEveryRingSlotHasADefault() {
        for slot in RingSlot.allCases {
            XCTAssertNotNil(WindowSettings.action(for: slot, defaults), slot.rawValue)
        }
        XCTAssertEqual(WindowSettings.ringDefaults.count, RingSlot.allCases.count)
    }

    func testCompassSlotsPointAtTheMatchingZones() {
        XCTAssertEqual(WindowSettings.action(for: .leading, defaults), .snap(WindowZoneMath.leftHalf))
        XCTAssertEqual(WindowSettings.action(for: .trailing, defaults), .snap(WindowZoneMath.rightHalf))
        XCTAssertEqual(WindowSettings.action(for: .top, defaults), .snap(WindowZoneMath.topHalf))
        XCTAssertEqual(WindowSettings.action(for: .bottom, defaults), .snap(WindowZoneMath.bottomHalf))
        XCTAssertEqual(
            WindowSettings.action(for: .topLeading, defaults), .snap(WindowZoneMath.topLeftQuarter))
        XCTAssertEqual(
            WindowSettings.action(for: .bottomTrailing, defaults),
            .snap(WindowZoneMath.bottomRightQuarter))
        XCTAssertEqual(WindowSettings.action(for: .hub, defaults), .snap(WindowZoneMath.maximize))
    }

    // MARK: - Ring persistence

    func testAssigningASlotLeavesTheOthersOnTheirDefaults() {
        WindowSettings.setAction(.snap(WindowZoneMath.centerThird), for: .top, defaults)
        XCTAssertEqual(WindowSettings.action(for: .top, defaults), .snap(WindowZoneMath.centerThird))
        XCTAssertEqual(WindowSettings.action(for: .trailing, defaults), .snap(WindowZoneMath.rightHalf))
        XCTAssertEqual(WindowSettings.action(for: .hub, defaults), .snap(WindowZoneMath.maximize))
    }

    func testCenterAndRestoreRoundTripOnASlot() {
        WindowSettings.setAction(.center, for: .hub, defaults)
        XCTAssertEqual(WindowSettings.action(for: .hub, defaults), .center)
        WindowSettings.setAction(.restore, for: .hub, defaults)
        XCTAssertEqual(WindowSettings.action(for: .hub, defaults), .restore)
    }

    func testASlotCanBeClearedWithoutRevertingToItsDefault() {
        WindowSettings.setAction(nil, for: .hub, defaults)
        XCTAssertNil(WindowSettings.action(for: .hub, defaults))
        XCTAssertEqual(WindowSettings.action(for: .top, defaults), .snap(WindowZoneMath.topHalf))
    }

    func testResetRingRestoresEveryDefault() {
        WindowSettings.setAction(.center, for: .top, defaults)
        WindowSettings.setAction(nil, for: .hub, defaults)
        WindowSettings.resetRing(defaults)
        XCTAssertEqual(WindowSettings.action(for: .top, defaults), .snap(WindowZoneMath.topHalf))
        XCTAssertEqual(WindowSettings.action(for: .hub, defaults), .snap(WindowZoneMath.maximize))
    }

    // MARK: - Ring corruption

    func testAZoneIdWeNoLongerShipFallsBackToTheSlotDefault() {
        defaults.set(
            ["hub": "left-half", "top": "zone-we-dropped"],
            forKey: WindowSettings.Key.ringSlots)
        XCTAssertEqual(WindowSettings.action(for: .hub, defaults), .snap(WindowZoneMath.leftHalf))
        XCTAssertEqual(WindowSettings.action(for: .top, defaults), .snap(WindowZoneMath.topHalf))
        // A slot absent from a stored map was cleared by the user, not corrupted.
        XCTAssertNil(WindowSettings.action(for: .bottom, defaults))
    }

    func testARingBlobThatIsNotADictionaryFallsBackToEveryDefault() {
        defaults.set("garbage", forKey: WindowSettings.Key.ringSlots)
        for slot in RingSlot.allCases {
            XCTAssertEqual(
                WindowSettings.action(for: slot, defaults), WindowSettings.ringDefaults[slot],
                slot.rawValue)
        }
    }

    func testARingBlobHoldingNonStringsFallsBackToEveryDefault() {
        defaults.set(["hub": 42, "top": 7], forKey: WindowSettings.Key.ringSlots)
        for slot in RingSlot.allCases {
            XCTAssertEqual(
                WindowSettings.action(for: slot, defaults), WindowSettings.ringDefaults[slot],
                slot.rawValue)
        }
    }

    func testWritingOverACorruptRingBlobRecoversTheDefaults() {
        defaults.set("garbage", forKey: WindowSettings.Key.ringSlots)
        WindowSettings.setAction(.center, for: .top, defaults)
        XCTAssertEqual(WindowSettings.action(for: .top, defaults), .center)
        XCTAssertEqual(WindowSettings.action(for: .hub, defaults), .snap(WindowZoneMath.maximize))
    }

    // MARK: - Chord defaults

    func testChordDefaultsStayClearOfTheAppsControlShiftFamily() {
        XCTAssertFalse(WindowSettings.chordDefaults.isEmpty)
        for binding in WindowSettings.chordDefaults {
            XCTAssertEqual(binding.chord.modifiers, controlKey | optionKey, binding.id)
            XCTAssertNotEqual(binding.chord.modifiers, controlKey | shiftKey, binding.id)
            XCTAssertFalse(binding.chord.label.isEmpty, binding.id)
        }
    }

    func testChordDefaultsAreUnique() {
        let ids = WindowSettings.chordDefaults.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        let pairs = WindowSettings.chordDefaults.map { "\($0.chord.keyCode),\($0.chord.modifiers)" }
        XCTAssertEqual(Set(pairs).count, pairs.count)
    }

    func testChordLookupResolvesTheDefaultsAndIgnoresUnboundKeys() {
        XCTAssertEqual(
            WindowSettings.action(keyCode: kVK_LeftArrow, modifiers: controlKey | optionKey, defaults),
            .snap(WindowZoneMath.leftHalf))
        XCTAssertEqual(
            WindowSettings.action(keyCode: kVK_Return, modifiers: controlKey | optionKey, defaults),
            .snap(WindowZoneMath.maximize))
        XCTAssertEqual(
            WindowSettings.action(keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey, defaults),
            .center)
        XCTAssertEqual(
            WindowSettings.action(keyCode: kVK_Delete, modifiers: controlKey | optionKey, defaults),
            .restore)
        // The Screenshot tool's chord must stay the Screenshot tool's.
        XCTAssertNil(
            WindowSettings.action(keyCode: kVK_ANSI_S, modifiers: controlKey | shiftKey, defaults))
    }

    // MARK: - Chord persistence

    func testChordOverrideRoundTripsAndResets() {
        let custom = HotKeyChord(
            keyCode: kVK_ANSI_1, modifiers: controlKey | optionKey | shiftKey, label: "⌃⌥⇧1")
        WindowSettings.setChord(custom, for: "left-half", defaults)
        XCTAssertEqual(WindowSettings.chords(defaults).first?.chord, custom)
        XCTAssertEqual(
            WindowSettings.action(
                keyCode: kVK_ANSI_1, modifiers: controlKey | optionKey | shiftKey, defaults),
            .snap(WindowZoneMath.leftHalf))
        XCTAssertNil(
            WindowSettings.action(keyCode: kVK_LeftArrow, modifiers: controlKey | optionKey, defaults))

        WindowSettings.resetChords(defaults)
        XCTAssertEqual(WindowSettings.chords(defaults), WindowSettings.chordDefaults)
    }

    func testClearingOneChordOverrideRestoresJustThatDefault() {
        let custom = HotKeyChord(keyCode: kVK_ANSI_1, modifiers: controlKey | optionKey, label: "⌃⌥1")
        WindowSettings.setChord(custom, for: "center", defaults)
        WindowSettings.setChord(nil, for: "center", defaults)
        XCTAssertEqual(WindowSettings.chords(defaults), WindowSettings.chordDefaults)
    }

    func testACorruptChordStringFallsBackToTheDefaultChord() {
        defaults.set("not-a-chord", forKey: WindowSettings.Key.chord("center"))
        XCTAssertEqual(WindowSettings.chords(defaults), WindowSettings.chordDefaults)
        XCTAssertEqual(
            WindowSettings.action(keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey, defaults),
            .center)
    }

    func testAChordStringWithNonNumericPartsFallsBackToTheDefaultChord() {
        defaults.set("left,alt,⌃⌥←", forKey: WindowSettings.Key.chord("left-half"))
        XCTAssertEqual(WindowSettings.chords(defaults), WindowSettings.chordDefaults)
    }

    func testAChordLabelContainingNoCommaSurvivesTheRoundTrip() {
        let custom = HotKeyChord(keyCode: kVK_ANSI_2, modifiers: controlKey | optionKey, label: "⌃⌥2")
        WindowSettings.setChord(custom, for: "restore", defaults)
        let binding = WindowSettings.chords(defaults).first { $0.id == "restore" }
        XCTAssertEqual(binding?.chord, custom)
        XCTAssertEqual(binding?.action, .restore)
    }
}

/// The action vocabulary grew for trackpad gestures. Persistence is by token, so
/// a token collision or a dropped case silently loses a user's binding.
@MainActor
final class WindowActionTokenTests: XCTestCase {
    private let allActions: [WindowAction] = [
        .snap(WindowZoneMath.leftHalf), .center, .restore, .minimize, .close, .quitApp,
    ]

    func testEveryActionRoundTripsThroughItsToken() {
        for action in allActions {
            let slot = RingSlot.hub
            let store = UserDefaults(suiteName: "token-\(UUID().uuidString)")!
            WindowSettings.setAction(action, for: slot, store)
            XCTAssertEqual(WindowSettings.action(for: slot, store), action, "\(action)")
        }
    }

    /// A reserved word that also named a zone would resolve to the wrong thing.
    func testNoZoneIdShadowsAReservedToken() {
        let reserved: Set<String> = ["center", "restore", "minimize", "close", "quit-app"]
        for zone in WindowZoneMath.zones {
            XCTAssertFalse(reserved.contains(zone.id), "zone id \(zone.id) shadows a reserved token")
        }
    }

    /// Close and quit can lose unsaved work; nothing else can. Bindings gate the
    /// destructive pair behind a larger gesture, so this flag has to stay right.
    func testOnlyCloseAndQuitAreDestructive() {
        XCTAssertTrue(WindowAction.close.isDestructive)
        XCTAssertTrue(WindowAction.quitApp.isDestructive)
        XCTAssertFalse(WindowAction.minimize.isDestructive)
        XCTAssertFalse(WindowAction.restore.isDestructive)
        XCTAssertFalse(WindowAction.center.isDestructive)
        XCTAssertFalse(WindowAction.snap(WindowZoneMath.maximize).isDestructive)
    }

    /// Minimise, close and quit change a window's existence, not its frame, so
    /// the geometry layer must decline them rather than inventing a rect.
    func testExistenceActionsHaveNoFrame() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let current = CGRect(x: 10, y: 10, width: 400, height: 300)
        for action in [WindowAction.minimize, .close, .quitApp] {
            XCTAssertNil(
                WindowZoneMath.frame(
                    for: action, in: visible, current: current, lastFrame: current),
                "\(action) must produce no frame")
        }
    }
}
