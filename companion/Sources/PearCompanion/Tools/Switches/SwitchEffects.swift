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

/// The two knobs a device offers, behind a seam so the save-and-restore rules
/// below can be tested without touching anybody's speakers.
@MainActor
protocol AudioOutputDevice: AnyObject {
    /// Nil when the device publishes no readable mute element at all.
    func readMuteFlag() -> Bool?
    /// False when the flag is absent or not settable.
    @discardableResult func writeMuteFlag(_ muted: Bool) -> Bool
    /// 0...1, or nil when the device publishes no readable volume.
    func readVolume() -> Float?
    @discardableResult func writeVolume(_ volume: Float) -> Bool
}

/// Mutes by asking *and* by zeroing the level.
///
/// The mute flag alone is not enough: plenty of outputs accept a write to
/// `kAudioDevicePropertyMute`, return `noErr`, report the new value back — and
/// keep playing. That is what "the mute button does nothing" looked like. Volume
/// zero is the part no device argues with, so muting saves the current level,
/// sets the flag, and takes the level to zero; unmuting clears the flag and puts
/// the saved level back.
///
/// Restoring is deliberately timid. The level goes back only if the output is
/// still silent, so if the user has already raised the volume by hand (or with
/// the media key) while the switch was on, unmuting leaves their level alone
/// instead of overriding it with a stale one.
@MainActor
final class CoreAudioMuteController: AudioMuting {
    /// Below this the output is silent for any practical purpose, and CoreAudio
    /// volumes are floats that do not always land exactly on zero.
    private static let silenceThreshold: Float = 0.001

    private let device: AudioOutputDevice
    private let store: UserDefaults

    init(device: AudioOutputDevice = CoreAudioOutputDevice(), store: UserDefaults = .standard) {
        self.device = device
        self.store = store
    }

    func isMuted() -> Bool {
        if let flag = device.readMuteFlag() { return flag }
        // No mute element (AirPods, many HDMI and USB outputs): silence is the
        // only signal there is.
        if let volume = device.readVolume() { return volume <= Self.silenceThreshold }
        return false
    }

    func setMuted(_ muted: Bool) {
        // No test guard here on purpose: the hardware boundary moved down to
        // `CoreAudioOutputDevice`, which carries it. A guard at this level would
        // make every test of the rules below pass without running them.
        if muted {
            // Read the level before anything else: once the flag is set, some
            // devices report zero and the real level would be lost.
            if let level = device.readVolume(), level > Self.silenceThreshold {
                store.set(level, forKey: Prefs.preMuteVolumeKey)
            }
            device.writeMuteFlag(true)
            device.writeVolume(0)
        } else {
            device.writeMuteFlag(false)
            let saved = store.object(forKey: Prefs.preMuteVolumeKey) as? Float
            let current = device.readVolume() ?? 0
            if let saved, saved > Self.silenceThreshold, current <= Self.silenceThreshold {
                device.writeVolume(saved)
            }
            store.removeObject(forKey: Prefs.preMuteVolumeKey)
        }
    }
}

/// The real device: `kAudioDevicePropertyMute` and `kAudioDevicePropertyVolumeScalar`
/// on whatever the default output is at the moment of the call.
@MainActor
final class CoreAudioOutputDevice: AudioOutputDevice {
    /// The per-channel elements to fall back to when a device exposes no main
    /// element (common on USB / HDMI / aggregate outputs). Element 0 is the
    /// main one; 1 and 2 are the left/right channels.
    private static let channelElements: [AudioObjectPropertyElement] = [1, 2]

    func readMuteFlag() -> Bool? {
        guard let device = defaultOutputDevice() else { return nil }
        if let main = readUInt32(device, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain) {
            return main != 0
        }
        let channels = Self.channelElements.compactMap {
            readUInt32(device, kAudioDevicePropertyMute, $0)
        }
        guard !channels.isEmpty else { return nil }
        // Muted only when every present channel is muted.
        return channels.allSatisfy { $0 != 0 }
    }

    @discardableResult
    func writeMuteFlag(_ muted: Bool) -> Bool {
        guard !SwitchTestGuard.isRunningTests else { return false }
        guard let device = defaultOutputDevice() else { return false }
        let value: UInt32 = muted ? 1 : 0
        if write(device, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain, value) {
            return true
        }
        return Self.channelElements.reduce(false) { done, element in
            write(device, kAudioDevicePropertyMute, element, value) || done
        }
    }

    func readVolume() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        if let main = readFloat(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain) {
            return main
        }
        let channels = Self.channelElements.compactMap {
            readFloat(device, kAudioDevicePropertyVolumeScalar, $0)
        }
        guard !channels.isEmpty else { return nil }
        return channels.max()
    }

    @discardableResult
    func writeVolume(_ volume: Float) -> Bool {
        guard !SwitchTestGuard.isRunningTests else { return false }
        guard let device = defaultOutputDevice() else { return false }
        if write(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain, volume) {
            return true
        }
        return Self.channelElements.reduce(false) { done, element in
            write(device, kAudioDevicePropertyVolumeScalar, element, volume) || done
        }
    }

    // Concrete per-type accessors rather than one generic pair: a generic
    // `inout T` handed to CoreAudio warns that T might contain an object
    // reference, and the repo does not ship warnings.

    private func readUInt32(
        _ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        _ element: AudioObjectPropertyElement
    ) -> UInt32? {
        var address = address(selector, element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private func readFloat(
        _ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        _ element: AudioObjectPropertyElement
    ) -> Float? {
        var address = address(selector, element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float(0)
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private func write(
        _ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        _ element: AudioObjectPropertyElement, _ value: UInt32
    ) -> Bool {
        var address = address(selector, element)
        guard isSettable(device, &address) else { return false }
        var value = value
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private func write(
        _ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        _ element: AudioObjectPropertyElement, _ value: Float
    ) -> Bool {
        var address = address(selector, element)
        guard isSettable(device, &address) else { return false }
        var value = value
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value) == noErr
    }

    /// The element has to exist *and* be settable; a write to a read-only
    /// element is how the caller learns to try the next one.
    private func isSettable(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private func address(
        _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
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
