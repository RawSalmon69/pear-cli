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
    /// The per-channel mute elements to fall back to when a device exposes no
    /// master mute (common on USB / HDMI / aggregate outputs). Element 0 is the
    /// master; 1 and 2 are the left/right channels.
    private static let channelElements: [AudioObjectPropertyElement] = [1, 2]

    func isMuted() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        // Prefer the master element; fall back to per-channel when the device
        // has no master mute.
        if let master = readMute(device, element: kAudioObjectPropertyElementMain) {
            return master
        }
        let channels = Self.channelElements.compactMap { readMute(device, element: $0) }
        guard !channels.isEmpty else { return false }
        // Muted only when every present channel is muted.
        return channels.allSatisfy { $0 }
    }

    func setMuted(_ muted: Bool) {
        guard !SwitchTestGuard.isRunningTests else { return }
        guard let device = defaultOutputDevice() else { return }
        // Master when present; otherwise write every present channel.
        if writeMute(device, element: kAudioObjectPropertyElementMain, muted: muted) { return }
        for element in Self.channelElements {
            _ = writeMute(device, element: element, muted: muted)
        }
    }

    /// Reads the mute flag for one element, or nil when the element is absent
    /// or unreadable.
    private func readMute(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool? {
        var address = muteAddress(element: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else {
            return nil
        }
        return muted != 0
    }

    /// Writes the mute flag for one element. Returns true only when the element
    /// exists, is settable, and the write succeeded — so the caller can tell
    /// whether the master path worked before falling back to channels.
    @discardableResult
    private func writeMute(_ device: AudioDeviceID, element: AudioObjectPropertyElement, muted: Bool) -> Bool {
        var address = muteAddress(element: element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else {
            return false
        }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
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

    private func muteAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
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
