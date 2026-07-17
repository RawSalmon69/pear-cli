import CoreGraphics
import XCTest

@testable import PearCompanion

/// Logic-level cover for Clean Mode's testable seams: the enter/exit state
/// machine, the single-teardown invariant across every exit path, the
/// tap-creation-failure fallback (keyboard stays live), the `cleanmode.*`
/// settings round-trip, and the pure screen-cover helper. No event tap, no
/// windows — every side-effecting seam is a fake. There is no auto-timeout:
/// Clean Mode exits only on Done (or stop()/quit).
@MainActor
final class CleanModeTests: XCTestCase {
    // MARK: - Fakes

    private final class FakeKeyboardLock: CleanModeKeyboardLocking {
        var engageResult = true
        private(set) var engageCount = 0
        private(set) var releaseCount = 0
        var isEngaged = false

        func engage() -> Bool {
            engageCount += 1
            isEngaged = engageResult
            return engageResult
        }

        func release() {
            releaseCount += 1
            isEngaged = false
        }
    }

    private final class FakeScreenBlanker: CleanModeScreenBlanking {
        private(set) var coverCount = 0
        private(set) var recoverCount = 0
        private(set) var uncoverCount = 0
        var onDone: (() -> Void)?

        func cover(onDone: @escaping () -> Void) {
            coverCount += 1
            self.onDone = onDone
        }

        func recover() { recoverCount += 1 }

        func uncover() {
            uncoverCount += 1
            onDone = nil
        }
    }

    private struct Rig {
        let controller: CleanModeController
        let keyboard: FakeKeyboardLock
        let blanker: FakeScreenBlanker
    }

    private func makeRig(defaults: UserDefaults) -> Rig {
        let keyboard = FakeKeyboardLock()
        let blanker = FakeScreenBlanker()
        let controller = CleanModeController(
            keyboard: keyboard, blanker: blanker, defaults: defaults
        )
        return Rig(controller: controller, keyboard: keyboard, blanker: blanker)
    }

    private func suite(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - State machine

    func testEnterActivates() {
        let defaults = suite("cleanmode-enter")
        defer { defaults.removePersistentDomain(forName: "cleanmode-enter") }
        let rig = makeRig(defaults: defaults)

        rig.controller.enter()

        XCTAssertTrue(rig.controller.isActive)
        XCTAssertEqual(rig.controller.state, .active(keyboardLocked: true))
        XCTAssertEqual(rig.blanker.coverCount, 1)
        XCTAssertEqual(rig.keyboard.engageCount, 1)
    }

    func testEnterWhileActiveIsNoOp() {
        let defaults = suite("cleanmode-reenter")
        defer { defaults.removePersistentDomain(forName: "cleanmode-reenter") }
        let rig = makeRig(defaults: defaults)

        rig.controller.enter()
        rig.controller.enter()

        // Nothing stacks: one cover, one tap.
        XCTAssertEqual(rig.blanker.coverCount, 1)
        XCTAssertEqual(rig.keyboard.engageCount, 1)
    }

    func testExitIsIdempotentAndTearsDownOnce() {
        let defaults = suite("cleanmode-exit")
        defer { defaults.removePersistentDomain(forName: "cleanmode-exit") }
        let rig = makeRig(defaults: defaults)

        rig.controller.enter()
        rig.controller.exit()
        rig.controller.exit() // second exit is a no-op

        XCTAssertFalse(rig.controller.isActive)
        XCTAssertEqual(rig.controller.state, .idle)
        XCTAssertEqual(rig.blanker.uncoverCount, 1)
        XCTAssertEqual(rig.keyboard.releaseCount, 1)
    }

    func testExitWhileIdleDoesNothing() {
        let defaults = suite("cleanmode-idle-exit")
        defer { defaults.removePersistentDomain(forName: "cleanmode-idle-exit") }
        let rig = makeRig(defaults: defaults)

        rig.controller.exit()

        XCTAssertFalse(rig.controller.isActive)
        XCTAssertEqual(rig.blanker.uncoverCount, 0)
        XCTAssertEqual(rig.keyboard.releaseCount, 0)
    }

    // MARK: - The Done path funnels to the one teardown

    func testDonePathTearsDown() {
        let defaults = suite("cleanmode-done")
        defer { defaults.removePersistentDomain(forName: "cleanmode-done") }
        let rig = makeRig(defaults: defaults)

        rig.controller.enter()
        rig.blanker.onDone?() // click Done

        XCTAssertFalse(rig.controller.isActive)
        XCTAssertEqual(rig.blanker.uncoverCount, 1)
        XCTAssertEqual(rig.keyboard.releaseCount, 1)
    }

    func testReenterAfterDoneWorks() {
        let defaults = suite("cleanmode-reenter-after-done")
        defer { defaults.removePersistentDomain(forName: "cleanmode-reenter-after-done") }
        let rig = makeRig(defaults: defaults)

        rig.controller.enter()
        rig.blanker.onDone?()
        rig.controller.enter()

        XCTAssertTrue(rig.controller.isActive)
        XCTAssertEqual(rig.blanker.coverCount, 2)
        XCTAssertEqual(rig.keyboard.engageCount, 2)
    }

    // MARK: - Tap-creation-failure fallback

    func testTapFailureKeepsKeyboardLiveButStaysActive() {
        let defaults = suite("cleanmode-tapfail")
        defer { defaults.removePersistentDomain(forName: "cleanmode-tapfail") }
        let rig = makeRig(defaults: defaults)
        rig.keyboard.engageResult = false // tap could not be created

        rig.controller.enter()

        // Still active (screens up), but the state truthfully reports the
        // keyboard is NOT locked — a lock failure fails toward more control.
        XCTAssertTrue(rig.controller.isActive)
        XCTAssertEqual(rig.controller.state, .active(keyboardLocked: false))
        XCTAssertEqual(rig.blanker.coverCount, 1)
        XCTAssertFalse(rig.keyboard.isEngaged)
    }

    func testLockKeyboardSettingOffNeverTapsKeyboard() {
        let defaults = suite("cleanmode-lockoff")
        defer { defaults.removePersistentDomain(forName: "cleanmode-lockoff") }
        defaults.set(false, forKey: CleanModeSettings.Key.lockKeyboard)
        let rig = makeRig(defaults: defaults)

        rig.controller.enter()

        XCTAssertTrue(rig.controller.isActive)
        XCTAssertEqual(rig.controller.state, .active(keyboardLocked: false))
        XCTAssertEqual(rig.keyboard.engageCount, 0) // never even attempted
        XCTAssertEqual(rig.blanker.coverCount, 1)
    }

    // MARK: - Settings accessors (defaults + fallback)

    func testSettingsDefaultsWhenUnset() {
        let defaults = suite("cleanmode-settings-default")
        defer { defaults.removePersistentDomain(forName: "cleanmode-settings-default") }

        XCTAssertTrue(CleanModeSettings.lockKeyboard(defaults))
    }

    func testSettingsRoundTrip() {
        let defaults = suite("cleanmode-settings-roundtrip")
        defer { defaults.removePersistentDomain(forName: "cleanmode-settings-roundtrip") }

        defaults.set(false, forKey: CleanModeSettings.Key.lockKeyboard)
        XCTAssertFalse(CleanModeSettings.lockKeyboard(defaults))

        defaults.set(true, forKey: CleanModeSettings.Key.lockKeyboard)
        XCTAssertTrue(CleanModeSettings.lockKeyboard(defaults))
    }

    // MARK: - Pure helpers

    func testCoverFramesOnePerScreenDroppingDegenerate() {
        let a = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let b = CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        let degenerate = CGRect(x: 0, y: 0, width: 0, height: 900)

        XCTAssertEqual(CleanModeController.coverFrames(screens: [a, b]), [a, b])
        XCTAssertEqual(CleanModeController.coverFrames(screens: [a, degenerate, b]), [a, b])
        XCTAssertEqual(CleanModeController.coverFrames(screens: []), [])
    }
}
