import XCTest
@testable import PearCompanion

/// The paywall lives entirely in `ToolRegistry`'s registration gate, so these
/// cases are the paywall's tests. Two properties matter more than the rest: a
/// locked app must register nothing paid, and it must still register the two
/// tools holding the user's own content, because the terms promise that in
/// writing.
@MainActor
final class EntitlementGateTests: XCTestCase {
    private final class FakeTool: Tool {
        let id: String
        let title: String
        let icon = "star"
        let hotkey: HotKeyChord? = nil
        let survivesExpiry: Bool
        private(set) var startCount = 0
        private(set) var stopCount = 0

        init(id: String, survivesExpiry: Bool = false) {
            self.id = id
            self.title = id
            self.survivesExpiry = survivesExpiry
        }

        var entry: ToolEntry { .action {} }
        func start() { startCount += 1 }
        func stop() { stopCount += 1 }
    }

    private func scrub() {
        for id in ["gate.paid", "gate.content"] {
            UserDefaults.standard.removeObject(forKey: Prefs.toolEnabledKey(id))
            UserDefaults.standard.removeObject(forKey: Prefs.toolHotkeyKey(id))
        }
    }

    // MARK: - The gate

    func testAnUnlockedAppRegistersEverything() {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry()
        let paid = FakeTool(id: "gate.paid")
        registry.offer(paid)

        XCTAssertEqual(paid.startCount, 1)
        XCTAssertEqual(registry.all.count, 1)
    }

    func testALockedAppNeverStartsAPaidTool() {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry()
        registry.isLocked = { true }
        let paid = FakeTool(id: "gate.paid")
        registry.offer(paid)

        XCTAssertEqual(paid.startCount, 0, "a locked tool's engine must never start")
        XCTAssertTrue(registry.all.isEmpty, "and it shows no tile")
        XCTAssertEqual(
            registry.known.count, 1,
            "but it is still catalogued, so settings can list it")
    }

    /// `site/terms.html` §2: notes and shelf items "remain accessible and
    /// exportable" after the trial ends. If this test fails, the app is breaking
    /// a written promise, not just a preference.
    func testALockedAppStillRegistersTheToolsHoldingUserContent() {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry()
        registry.isLocked = { true }
        let content = FakeTool(id: "gate.content", survivesExpiry: true)
        registry.offer(content)

        XCTAssertEqual(content.startCount, 1)
        XCTAssertEqual(registry.all.count, 1, "the user can still reach their own content")
    }

    /// The real tools that carry that promise, asserted by identity rather than
    /// by a fake, so renaming or replacing one cannot quietly drop the exemption.
    func testScratchpadAndShelfAreTheToolsThatSurviveExpiry() {
        XCTAssertTrue(ScratchpadTool().survivesExpiry)
        XCTAssertTrue(ShelfTool().survivesExpiry)
        // A sample of paid tools that must not survive.
        XCTAssertFalse(OCRTool().survivesExpiry)
        XCTAssertFalse(ColorPickerTool().survivesExpiry)
        XCTAssertFalse(WindowsTool().survivesExpiry)
    }

    /// A user disabling a tool still wins over the gate: locked-and-disabled is
    /// disabled, and unlocking must not resurrect something they turned off.
    func testAUserDisabledToolStaysOffWhenTheAppIsUnlocked() {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry()
        let paid = FakeTool(id: "gate.paid")
        registry.offer(paid)
        registry.setEnabled("gate.paid", false)

        XCTAssertEqual(paid.stopCount, 1)
        XCTAssertTrue(registry.all.isEmpty)
    }

    /// Enabling a paid tool while locked must not start it — otherwise the
    /// settings toggle is a paywall bypass.
    func testEnablingAPaidToolWhileLockedDoesNotStartIt() {
        scrub()
        defer { scrub() }
        let registry = ToolRegistry()
        registry.isLocked = { true }
        let paid = FakeTool(id: "gate.paid")
        registry.offer(paid)

        registry.setEnabled("gate.paid", true)

        XCTAssertEqual(paid.startCount, 0, "the toggle is not a way around the gate")
        XCTAssertTrue(registry.all.isEmpty)
    }

    /// A locked tool's chord is free for someone else to bind, because it is not
    /// registered and cannot win the chord at runtime.
    func testALockedToolsChordIsNotAConflict() {
        scrub()
        defer { scrub() }
        let chord = HotKeyChord(keyCode: 12, modifiers: 4096, label: "test")
        let registry = ToolRegistry()
        registry.isLocked = { true }
        registry.offer(FakeTool(id: "gate.paid"))
        registry.setHotkeyOverride("gate.paid", chord)
        defer { registry.setHotkeyOverride("gate.paid", nil) }

        XCTAssertNil(registry.conflictingTool(for: chord, excluding: "gate.content"))
    }

    // MARK: - Entitlement precedence

    func testEntitlementUnlocksToolsOnlyWhenNotExpired() {
        XCTAssertTrue(Entitlement.licensed(email: "a@b.c").unlocksTools)
        XCTAssertTrue(Entitlement.trial(daysRemaining: 1).unlocksTools)
        XCTAssertFalse(Entitlement.expired(.trialEnded).unlocksTools)
        XCTAssertFalse(Entitlement.expired(.licenceRefunded).unlocksTools)
        XCTAssertFalse(Entitlement.expired(.licenceForOlderMajor(maxMajor: 2)).unlocksTools)
    }
}
