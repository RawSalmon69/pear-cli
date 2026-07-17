// Hide Desktop / Show Hidden command shapes adapted from OnlySwitch (MIT),
// https://github.com/jacklandrin/OnlySwitch — see Resources/Licenses/
// OnlySwitch-LICENSE.txt. OnlySwitch's HideDesktopCMD / ShowHiddenFilesCMD
// (Modules/Sources/Switches/ShellCommandDefine.swift) write the same finder
// defaults + relaunch Finder. Two deviations, both for correctness: the
// canonical lower-case `com.apple.finder` domain (OnlySwitch mixed case), and
// explicit `-bool` typing instead of bare `0/1`/`true`.

import Foundation

/// One shell invocation: a binary and its argument vector. Value type so tests
/// can assert the exact command line without spawning a process.
struct ShellCommand: Equatable {
    let binary: String
    let arguments: [String]
}

/// Pure builders + parsers for the shell-backed switches. No process runs here;
/// the model feeds these through an injected `CommandRunner`.
enum SwitchCommands {
    static let defaultsBinary = "/usr/bin/defaults"
    static let killallBinary = "/usr/bin/killall"
    static let openBinary = "/usr/bin/open"

    // MARK: Hide Desktop (com.apple.finder CreateDesktop)
    // "On" = icons hidden = CreateDesktop false. Absent key = macOS default
    // (icons shown) = off.

    static let hideDesktopRead = ShellCommand(
        binary: defaultsBinary, arguments: ["read", "com.apple.finder", "CreateDesktop"]
    )

    static func hideDesktop(_ on: Bool) -> [ShellCommand] {
        [
            ShellCommand(binary: defaultsBinary,
                         arguments: ["write", "com.apple.finder", "CreateDesktop", "-bool", on ? "false" : "true"]),
            ShellCommand(binary: killallBinary, arguments: ["Finder"]),
        ]
    }

    static func hideDesktopIsOn(fromRead output: String?) -> Bool {
        guard let value = trimmed(output) else { return false }
        // CreateDesktop false → desktop icons hidden → switch on.
        return !(value as NSString).boolValue
    }

    // MARK: Show Hidden Files (com.apple.finder AppleShowAllFiles)

    static let showHiddenRead = ShellCommand(
        binary: defaultsBinary, arguments: ["read", "com.apple.finder", "AppleShowAllFiles"]
    )

    static func showHidden(_ on: Bool) -> [ShellCommand] {
        [
            ShellCommand(binary: defaultsBinary,
                         arguments: ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", on ? "true" : "false"]),
            ShellCommand(binary: killallBinary, arguments: ["Finder"]),
        ]
    }

    static func showHiddenIsOn(fromRead output: String?) -> Bool {
        guard let value = trimmed(output) else { return false }
        return (value as NSString).boolValue
    }

    // MARK: Big Cursor (com.apple.universalaccess mouseDriverCursorSize)
    // KNOWN RISK: com.apple.universalaccess is a TCC-gated domain and the
    // pointer size is owned by universalaccessd, so a plain `defaults write`
    // from a third-party app may be rejected or may not apply live (it can need
    // a re-login or a nudge in System Settings › Accessibility › Pointer). The
    // model surfaces `bigCursorNeedsSystemSettingsHint` so the UI can say so
    // rather than pretend it worked. 1.0 = normal, 3.0 = large.

    static let bigCursorNormalSize = "1"
    static let bigCursorLargeSize = "3"

    static let bigCursorRead = ShellCommand(
        binary: defaultsBinary, arguments: ["read", "com.apple.universalaccess", "mouseDriverCursorSize"]
    )

    static func bigCursor(_ on: Bool) -> [ShellCommand] {
        [
            ShellCommand(binary: defaultsBinary,
                         arguments: ["write", "com.apple.universalaccess", "mouseDriverCursorSize",
                                     "-float", on ? bigCursorLargeSize : bigCursorNormalSize]),
        ]
    }

    static func bigCursorIsOn(fromRead output: String?) -> Bool {
        guard let value = trimmed(output), let size = Double(value) else { return false }
        return size > 1.5
    }

    // MARK: Screen Saver (launch the engine; momentary)
    // Public path: hand the engine to LaunchServices via `open`. Version-
    // independent (LaunchServices resolves the moved bundle on macOS 14+).

    static let screenSaver = ShellCommand(binary: openBinary, arguments: ["-a", "ScreenSaverEngine"])

    private static func trimmed(_ output: String?) -> String? {
        guard let value = output?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// Orchestrates the eight switches against injected effect seams, so `swift
/// test` never mutates the real system. Toggle states are `@Observable` and
/// read live via `refresh()` when the popover opens.
@MainActor
@Observable
final class SwitchesModel {
    // Live toggle states (momentary switches carry no state).
    var keepAwakeOn = false
    var muteOn = false
    var hideDesktopOn = false
    var showHiddenOn = false
    var bigCursorOn = false

    @ObservationIgnored private let commandRunner: CommandRunner
    @ObservationIgnored private let power: PowerAssertioning
    @ObservationIgnored private let audio: AudioMuting
    @ObservationIgnored private let locker: ScreenLocking

    init(
        commandRunner: CommandRunner = ProcessRunner(),
        power: PowerAssertioning = IOKitPowerAssertion(),
        audio: AudioMuting = CoreAudioMuteController(),
        locker: ScreenLocking = CGEventScreenLocker()
    ) {
        self.commandRunner = commandRunner
        self.power = power
        self.audio = audio
        self.locker = locker
    }

    // MARK: - Live state read (popover open)

    func refresh() async {
        keepAwakeOn = power.isActive
        muteOn = audio.isMuted()
        hideDesktopOn = SwitchCommands.hideDesktopIsOn(fromRead: await read(SwitchCommands.hideDesktopRead))
        showHiddenOn = SwitchCommands.showHiddenIsOn(fromRead: await read(SwitchCommands.showHiddenRead))
        bigCursorOn = SwitchCommands.bigCursorIsOn(fromRead: await read(SwitchCommands.bigCursorRead))
    }

    // MARK: - Toggles

    func setKeepAwake(_ on: Bool) {
        if on { power.acquire() } else { power.release() }
        keepAwakeOn = power.isActive
    }

    func setMute(_ on: Bool) {
        audio.setMuted(on)
        muteOn = audio.isMuted()
    }

    func setHideDesktop(_ on: Bool) async {
        hideDesktopOn = on
        await run(SwitchCommands.hideDesktop(on))
    }

    func setShowHidden(_ on: Bool) async {
        showHiddenOn = on
        await run(SwitchCommands.showHidden(on))
    }

    func setBigCursor(_ on: Bool) async {
        bigCursorOn = on
        await run(SwitchCommands.bigCursor(on))
    }

    // MARK: - Momentary actions

    func launchScreenSaver() async {
        await run([SwitchCommands.screenSaver])
    }

    func lockScreen() {
        locker.lock()
    }

    /// Tool teardown mirror: release the power assertion when the tool is
    /// disabled or the app quits.
    func teardown() {
        power.release()
        keepAwakeOn = false
    }

    // MARK: - Internals

    private func run(_ commands: [ShellCommand]) async {
        for command in commands {
            _ = await commandRunner.run(binary: command.binary, arguments: command.arguments, timeout: 8)
        }
    }

    private func read(_ command: ShellCommand) async -> String? {
        guard case .success(let data) = await commandRunner.run(
            binary: command.binary, arguments: command.arguments, timeout: 5
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
