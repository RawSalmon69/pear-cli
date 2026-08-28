// Keep Awake adapts KeepAwakeSwitch from OnlySwitch (MIT),
// https://github.com/jacklandrin/OnlySwitch — see Resources/Licenses/
// OnlySwitch-LICENSE.txt. The IOKit assertion type + release pattern mirror
// KeepAwakeSwitch. (A Mute switch adapted from the same project was removed at
// the owner's order in 2.25.0; the notice stays because Hide Desktop / Show
// Hidden in SwitchesModel still derive from it.)

import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import Carbon.HIToolbox

/// Central test guard for the effect implementations that touch real hardware
/// or the session. Mirrors `LoginItem.isRunningTests`: under `swift test` these
/// no-op so the suite never creates a power assertion, locks the screen, or
/// opens a fullscreen overlay. Production always injects the real
/// implementations; tests always inject mocks — the guard is belt-and-braces.
enum SwitchTestGuard {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

// MARK: - Keep Awake (IOKit power assertion)

/// Holds an IOKit power assertion so the display never sleeps. `acquire` /
/// `release` are idempotent; the assertion is released on `release`, on
/// `deinit`, and — implicitly — when the process exits (IOKit assertions are
/// per-process).
@MainActor
protocol PowerAssertioning: AnyObject {
    var isActive: Bool { get }
    /// Returns true if an assertion is now held.
    @discardableResult func acquire() -> Bool
    func release()
}

@MainActor
final class IOKitPowerAssertion: PowerAssertioning {
    private var assertionID = IOPMAssertionID(0)
    private(set) var isActive = false

    @discardableResult
    func acquire() -> Bool {
        guard !isActive else { return true }
        guard !SwitchTestGuard.isRunningTests else { return false }
        var newID = IOPMAssertionID(0)
        let reason = "Pear: Keep Awake" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &newID
        )
        guard result == kIOReturnSuccess else { return false }
        assertionID = newID
        isActive = true
        return true
    }

    func release() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        isActive = false
    }

    deinit {
        if isActive { IOPMAssertionRelease(assertionID) }
    }
}

// MARK: - Lock Screen (public CGEvent chord)

/// Locks the screen immediately. OnlySwitch has no lock switch; the common
/// private path is `SACLockScreenImmediate` (login.framework, private). Public
/// substitute: post the system lock chord ⌃⌘Q, which the app can do because it
/// already holds Accessibility. No stored state — momentary.
@MainActor
protocol ScreenLocking: AnyObject {
    func lock()
}

@MainActor
final class CGEventScreenLocker: ScreenLocking {
    func lock() {
        guard !SwitchTestGuard.isRunningTests else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_Q)
        let flags: CGEventFlags = [.maskCommand, .maskControl]
        if let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }
}
