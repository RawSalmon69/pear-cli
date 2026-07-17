// Keep Awake adapts KeepAwakeSwitch and Mute adapts MuteSwitch from OnlySwitch
// (MIT), https://github.com/jacklandrin/OnlySwitch — see Resources/Licenses/
// OnlySwitch-LICENSE.txt. The IOKit assertion type + release pattern mirror
// KeepAwakeSwitch. OnlySwitch's mute path uses NSSound.systemVolume, a private
// NSSound category; substituted here with the public CoreAudio mute property.

import CoreAudio
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import Carbon.HIToolbox

/// Central test guard for the effect implementations that touch real hardware
/// or the session. Mirrors `LoginItem.isRunningTests`: under `swift test` these
/// no-op so the suite never creates a power assertion, mutes audio, locks the
/// screen, or opens a fullscreen overlay. Production always injects the real
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

// MARK: - Mute (CoreAudio default output device)

/// Reads/sets the mute flag on the default output device. Public CoreAudio, so
/// state is readable (unlike shelling to osascript) and no process is spawned.
@MainActor
protocol AudioMuting: AnyObject {
    func isMuted() -> Bool
    func setMuted(_ muted: Bool)
}

@MainActor
final class CoreAudioMuteController: AudioMuting {
    func isMuted() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return false }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        return status == noErr && muted != 0
    }

    func setMuted(_ muted: Bool) {
        guard !SwitchTestGuard.isRunningTests else { return }
        guard let device = defaultOutputDevice() else { return }
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return }
        var value: UInt32 = muted ? 1 : 0
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr && device != 0 ? device : nil
    }

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
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
