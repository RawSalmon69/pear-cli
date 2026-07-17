import AppKit
import CoreGraphics
import Foundation

/// Belt-and-suspenders test guard. Tests already inject fakes for every seam,
/// but the real services also refuse to touch the system under `swift test` —
/// no event tap, no windows — so even a stray real-controller construction in
/// a test can never lock the machine.
@MainActor
enum CleanModeRuntime {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

/// Production keyboard lock: a session `CGEventTap` (via the shared
/// `KeySwallowTap`) that swallows every keystroke. Mouse events are deliberately
/// absent from the mask, so the pointer stays fully live — the guaranteed
/// escape hatch. The tap is session-scoped, so the OS tears it down the instant
/// this process ends: a lock can never outlive Pear.
@MainActor
final class CleanModeKeyboardLock: CleanModeKeyboardLocking {
    private var tap: KeySwallowTap?

    func engage() -> Bool {
        guard !CleanModeRuntime.isRunningTests else { return false }
        guard tap == nil else { return true }
        // keyDown + keyUp + flagsChanged: every key transition, including bare
        // modifier presses (so Caps Lock / a stuck modifier can't leak while the
        // user wipes the keys). Never any mouse type.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        tap = KeySwallowTap(eventMask: mask) { _ in true }
        return tap != nil
    }

    func release() {
        tap?.invalidate()
        tap = nil
    }
}

