import CoreGraphics
import XCTest

@testable import PearCompanion

/// Logic-level cover for Clean Mode's testable seams: the enter/exit state
/// machine, the single-teardown invariant across every exit path, the
/// tap-creation-failure fallback (keyboard stays live), timeout scheduling with
/// an injected countdown, the `cleanmode.*` settings round-trip, and the pure
/// countdown-text / screen-cover helpers. No event tap, no windows, no
/// wall-clock timer — every side-effecting seam is a fake.
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
        private(set) var lastCountdown: String?
        var onDone: (() -> Void)?

        func cover(onDone: @escaping () -> Void) {
            coverCount += 1
            self.onDone = onDone
        }

        func recover() { recoverCount += 1 }
        func updateCountdown(_ text: String) { lastCountdown = text }

        func uncover() {
            uncoverCount += 1
            onDone = nil
        }
    }

    private final class FakeCountdown: CleanModeCountdownScheduling {
        private(set) var startCount = 0
        private(set) var cancelCount = 0
        private(set) var lastSeconds: Int?
        var onTick: ((Int) -> Void)?
        var onExpire: (() -> Void)?

        func start(seconds: Int, onTick: @escaping (Int) -> Void, onExpire: @escaping () -> Void) {
            startCount += 1
            lastSeconds = seconds
            self.onTick = onTick
            self.onExpire = onExpire
        }

        func cancel() {
            cancelCount += 1
            onTick = nil
            onExpire = nil
        }

        func fireExpire() { onExpire?() }
        func tick(_ remaining: Int) { onTick?(remaining) }
    }

    private struct Rig {
        let controller: CleanModeController
        let keyboard: FakeKeyboardLock
        let blanker: FakeScreenBlanker
        let countdown: FakeCountdown
    }

    private func makeRig(defaults: UserDefaults) -> Rig {
        let keyboard = FakeKeyboardLock()
        let blanker = FakeScreenBlanker()
        let countdown = FakeCountdown()
        let controller = CleanModeController(
            keyboard: keyboard, blanker: blanker, countdown: countdown, defaults: defaults
        )
        return Rig(controller: controller, keyboard: keyboard, blanker: blanker, countdown: countdown)
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
        XCTAssertEqual(rig.countdown.startCount, 1)
    }

    func testEnterWhileActiveIsNoOp() {
        let defaults = suite("cleanmode-reenter")
        defer { defaults.removePersistentDomain(forName: "cleanmode-reenter") }
        let rig = makeRig(defaults: defaults)

        rig.controller.enter()
        rig.controller.enter()

        // Nothing stacks: one cover, one tap, one countdown.
        XCTAssertEqual(rig.blanker.coverCount, 1)
        XCTAssertEqual(rig.keyboard.engageCount, 1)
        XCTAssertEqual(rig.countdown.startCount, 1)
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
        XCTAssertEqual(rig.countdown.cancelCount, 1)
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

    // MARK: - Every exit path funnels to one teardown

    func testDonePathTearsDown() {
        let defaults = suite("cleanmode-done")
        defer { defaults.removePersistentDomain(forName: "cleanmode-done") }
        let rig = makeRig(defaults: defaults)

        rig.controller.enter()
        rig.blanker.onDone?() // click Done

        XCTAssertFalse(rig.controller.isActive)
        XCTAssertEqual(rig.blanker.uncoverCount, 1)
        XCTAssertEqual(rig.keyboard.releaseCount, 1)
        XCTAssertEqual(rig.countdown.cancelCount, 1)
    }

    func testTimeoutPathTearsDown() {
        let defaults = suite("cleanmode-timeout-path")
        defer { defaults.removePersistentDomain(forName: "cleanmode-timeout-path") }
        let rig = makeRig(defaults: defaults)

        rig.controller.enter()
        rig.countdown.fireExpire() // timer reached zero

        XCTAssertFalse(rig.controller.isActive)
        XCTAssertEqual(rig.blanker.uncoverCount, 1)
        XCTAssertEqual(rig.keyboard.releaseCount, 1)
        XCTAssertEqual(rig.countdown.cancelCount, 1)
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

    // MARK: - Timeout scheduling honors the setting

    func testCountdownUsesDefaultDuration() {
        let defaults = suite("cleanmode-dur-default")
        defer { defaults.removePersistentDomain(forName: "cleanmode-dur-default") }
        let rig = makeRig(defaults: defaults)

        rig.controller.enter()

        XCTAssertEqual(rig.countdown.lastSeconds, 60)
        // Overlay is seeded with the full time immediately.
        XCTAssertEqual(rig.blanker.lastCountdown, "1:00")
    }

    func testCountdownHonorsConfiguredDuration() {
        let defaults = suite("cleanmode-dur-set")
        defer { defaults.removePersistentDomain(forName: "cleanmode-dur-set") }
        defaults.set(CleanModeTimeout.fiveMinutes.rawValue, forKey: CleanModeSettings.Key.timeout)
        let rig = makeRig(defaults: defaults)

        rig.controller.enter()

        XCTAssertEqual(rig.countdown.lastSeconds, 300)
        XCTAssertEqual(rig.blanker.lastCountdown, "5:00")
    }

    func testTickUpdatesOverlayCountdown() {
        let defaults = suite("cleanmode-tick")
        defer { defaults.removePersistentDomain(forName: "cleanmode-tick") }
        let rig = makeRig(defaults: defaults)

        rig.controller.enter()
        rig.countdown.tick(65)

        XCTAssertEqual(rig.blanker.lastCountdown, "1:05")
    }

    // MARK: - Settings accessors (defaults + fallback)

    func testSettingsDefaultsWhenUnset() {
        let defaults = suite("cleanmode-settings-default")
        defer { defaults.removePersistentDomain(forName: "cleanmode-settings-default") }

        XCTAssertEqual(CleanModeSettings.timeout(defaults), .oneMinute)
        XCTAssertEqual(CleanModeSettings.timeoutSeconds(defaults), 60)
        XCTAssertTrue(CleanModeSettings.lockKeyboard(defaults))
    }

    func testSettingsRoundTrip() {
        let defaults = suite("cleanmode-settings-roundtrip")
        defer { defaults.removePersistentDomain(forName: "cleanmode-settings-roundtrip") }

        defaults.set(CleanModeTimeout.twoMinutes.rawValue, forKey: CleanModeSettings.Key.timeout)
        defaults.set(false, forKey: CleanModeSettings.Key.lockKeyboard)

        XCTAssertEqual(CleanModeSettings.timeout(defaults), .twoMinutes)
        XCTAssertEqual(CleanModeSettings.timeoutSeconds(defaults), 120)
        XCTAssertFalse(CleanModeSettings.lockKeyboard(defaults))
    }

    func testGarbageTimeoutFallsBackToDefault() {
        let defaults = suite("cleanmode-settings-garbage")
        defer { defaults.removePersistentDomain(forName: "cleanmode-settings-garbage") }

        // A value not in the picker's set (e.g. a stray `defaults write`).
        defaults.set(999, forKey: CleanModeSettings.Key.timeout)
        XCTAssertEqual(CleanModeSettings.timeout(defaults), .oneMinute)
        XCTAssertEqual(CleanModeSettings.timeoutSeconds(defaults), 60)

        defaults.set(0, forKey: CleanModeSettings.Key.timeout)
        XCTAssertEqual(CleanModeSettings.timeoutSeconds(defaults), 60)
    }

    // MARK: - Pure helpers

    func testCountdownTextFormatting() {
        XCTAssertEqual(CleanModeController.countdownText(remaining: 0), "0:00")
        XCTAssertEqual(CleanModeController.countdownText(remaining: 5), "0:05")
        XCTAssertEqual(CleanModeController.countdownText(remaining: 59), "0:59")
        XCTAssertEqual(CleanModeController.countdownText(remaining: 60), "1:00")
        XCTAssertEqual(CleanModeController.countdownText(remaining: 125), "2:05")
        XCTAssertEqual(CleanModeController.countdownText(remaining: 300), "5:00")
        XCTAssertEqual(CleanModeController.countdownText(remaining: -10), "0:00") // clamps
    }

    func testCoverFramesOnePerScreenDroppingDegenerate() {
        let a = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let b = CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        let degenerate = CGRect(x: 0, y: 0, width: 0, height: 900)

        XCTAssertEqual(CleanModeController.coverFrames(screens: [a, b]), [a, b])
        XCTAssertEqual(CleanModeController.coverFrames(screens: [a, degenerate, b]), [a, b])
        XCTAssertEqual(CleanModeController.coverFrames(screens: []), [])
    }
}
