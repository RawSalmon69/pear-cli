// Hide Desktop / Show Hidden command shapes adapted from OnlySwitch (MIT),
// https://github.com/jacklandrin/OnlySwitch — see Resources/Licenses/
// OnlySwitch-LICENSE.txt. OnlySwitch's HideDesktopCMD / ShowHiddenFilesCMD
// (Modules/Sources/Switches/ShellCommandDefine.swift) write the same finder
// defaults + relaunch Finder. Two deviations, both for correctness: the
// canonical lower-case `com.apple.finder` domain (OnlySwitch mixed case), and
// explicit `-bool` typing instead of bare `0/1`/`true`.

import AppKit
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
    static let pmsetBinary = "/usr/bin/pmset"
    static let osascriptBinary = "/usr/bin/osascript"

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
    // a re-login or a nudge in System Settings › Accessibility › Pointer).
    // `SwitchesView` shows a static hint line saying exactly that, so the UI is
    // honest about it rather than pretending the write always applies live.
    // 1.0 = normal, 3.0 = large.

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

    // MARK: Lid Closed (pmset disablesleep / SleepDisabled)
    // Prior art: https://github.com/pistachionet/awake (MIT) established that
    // `pmset -a disablesleep` is the only lever that survives a lid close (IOKit
    // assertions and `caffeinate` do not), and that a NOPASSWD sudoers rule
    // scoped to those two exact command lines is what buys silent flips. Written
    // from the mechanism rather than from its source; the one deliberate
    // deviation is marked on `installLidRule`.
    //
    // The switch works with or without the grant: every flip tries `sudo -n`
    // first (never prompts, fails instantly when there is no rule) and falls
    // back to one `osascript ... with administrator privileges` call. The grant
    // only removes the repeat prompts, so it is opt-in inside an opt-in switch.
    //
    // KNOWN CEILING: `disablesleep` is machine state, not a per-process
    // assertion. Quitting restores it (`restoreLidOnQuit`) and a timed session
    // restores it on expiry, but a crash or `kill -9` cannot. `refresh()` reads
    // the live value on every popover open and the grid says so in words.

    static let sudoBinary = "/usr/bin/sudo"
    static let visudoBinary = "/usr/sbin/visudo"

    /// Dot-free filename on purpose: sudo's `includedir` skips any file in
    /// `/etc/sudoers.d` whose name contains a `.`, which is also what keeps the
    /// staged name below invisible to sudo until it has been validated.
    static let sudoersRulePath = "/etc/sudoers.d/pear-lidclosed"
    static let sudoersStagePath = "/etc/sudoers.d/.pear-lidclosed.staged"

    static let lidClosedRead = ShellCommand(binary: pmsetBinary, arguments: ["-g", "live"])

    static let sleepNow = ShellCommand(binary: pmsetBinary, arguments: ["sleepnow"])

    /// Silent flip. `-n` means sudo never prompts, so without the rule this
    /// exits nonzero immediately and the caller falls back to the prompt.
    static func lidClosedSilent(_ on: Bool) -> ShellCommand {
        ShellCommand(
            binary: sudoBinary,
            arguments: ["-n", pmsetBinary, "-a", "disablesleep", on ? "1" : "0"])
    }

    /// Authorized flip: the standard macOS auth dialog, for this one command.
    static func lidClosedPrompted(_ on: Bool) -> ShellCommand {
        adminShell("\(pmsetBinary) -a disablesleep \(on ? 1 : 0)")
    }

    /// The NOPASSWD line: two literal command lines with their arguments spelled
    /// out. Sudoers matches arguments exactly, so the grant cannot widen into
    /// anything else.
    static func lidClosedRule(user: String) -> String {
        "\(user) ALL=(root) NOPASSWD: \(pmsetBinary) -a disablesleep 1,"
            + " \(pmsetBinary) -a disablesleep 0\n"
    }

    /// Installs a staged rule file, but only after `visudo` has accepted it.
    ///
    /// DEVIATION from the prior art, which writes the real path first and only
    /// then runs `visudo -cf` on it, discarding the verdict. A malformed file in
    /// `/etc/sudoers.d` makes sudo refuse to parse its configuration at all, so
    /// that ordering can lock the user out of sudo. Here the staged name is
    /// dot-prefixed (invisible to sudo), validation gates the rename, and any
    /// failure removes the staged file and exits nonzero so the caller sees it.
    static func installLidRule(stagedAt path: String) -> ShellCommand {
        adminShell(
            "cp '\(path)' '\(sudoersStagePath)'"
                + " && chown root:wheel '\(sudoersStagePath)'"
                + " && chmod 0440 '\(sudoersStagePath)'"
                + " && \(visudoBinary) -cf '\(sudoersStagePath)'"
                + " && mv '\(sudoersStagePath)' '\(sudoersRulePath)'"
                + " || { rm -f '\(sudoersStagePath)'; exit 1; }")
    }

    static let removeLidRule = adminShell("rm -f '\(sudoersRulePath)'")

    /// Reads the `SleepDisabled` row out of `pmset -g live`. Line shape is
    /// ` SleepDisabled\t\t0`, under a `System-wide power settings:` header.
    static func lidClosedIsOn(fromRead output: String?) -> Bool {
        guard let line = output?.split(separator: "\n").first(where: { $0.contains("SleepDisabled") })
        else { return false }
        return line.split(whereSeparator: \.isWhitespace).last == "1"
    }

    /// Paths reach the shell only inside single quotes and reach AppleScript
    /// inside a double-quoted literal, so a quote or a backslash would break out
    /// of one or the other. The only caller builds its path under
    /// `NSTemporaryDirectory()`, but this one runs as root: check anyway.
    static func isShellSafe(_ path: String) -> Bool {
        !path.contains("'") && !path.contains("\"") && !path.contains("\\")
    }

    /// Wraps one `/bin/sh` line in a single authorization dialog. Callers keep
    /// the script free of double quotes and backslashes.
    private static func adminShell(_ script: String) -> ShellCommand {
        ShellCommand(
            binary: osascriptBinary,
            arguments: ["-e", "do shell script \"\(script)\" with administrator privileges"])
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
    var lidClosedOn = false
    var muteOn = false
    var hideDesktopOn = false
    var showHiddenOn = false
    var bigCursorOn = false

    /// When a timed Lid Closed session ends, so the grid can say it. Nil means
    /// the switch is either off or on indefinitely.
    var lidSessionEnd: Date?
    /// Whether the one-time sudoers grant is in place. `/etc/sudoers.d` is
    /// world-readable (0755) even though the rule inside it is not, so this is a
    /// plain existence check rather than a privileged probe. Deliberately not
    /// `sudo -n -l`: that answers yes whenever the user has a warm sudo
    /// timestamp from their own terminal, which would make the UI lie.
    var lidRuleInstalled = false

    @ObservationIgnored private let commandRunner: CommandRunner
    @ObservationIgnored private let power: PowerAssertioning
    @ObservationIgnored private let audio: AudioMuting
    @ObservationIgnored private let locker: ScreenLocking
    @ObservationIgnored private let ruleExists: @Sendable () -> Bool
    @ObservationIgnored private var lidSessionTask: Task<Void, Never>?
    /// `nonisolated(unsafe)` only so `deinit` may hand the token back. It is
    /// written once, in `init`, and read once, from `deinit`.
    @ObservationIgnored nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?

    init(
        commandRunner: CommandRunner = ProcessRunner(),
        power: PowerAssertioning = IOKitPowerAssertion(),
        audio: AudioMuting = CoreAudioMuteController(),
        locker: ScreenLocking = CGEventScreenLocker(),
        ruleExists: @escaping @Sendable () -> Bool = {
            FileManager.default.fileExists(atPath: SwitchCommands.sudoersRulePath)
        }
    ) {
        self.commandRunner = commandRunner
        self.power = power
        self.audio = audio
        self.locker = locker
        self.ruleExists = ruleExists
        lidRuleInstalled = ruleExists()
        // Restoring sleep at quit is the only reason the app knows when it is
        // terminating. Tools are not stopped on termination (Clean Mode carries
        // the same observer for the same reason).
        guard !SwitchTestGuard.isRunningTests else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreLidOnQuit() }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    // MARK: - Live state read (popover open)

    func refresh() async {
        keepAwakeOn = power.isActive
        muteOn = audio.isMuted()
        // The three `defaults read`s are independent, so spawn them together
        // rather than paying three sequential process round-trips on open.
        async let hideDesktop = read(SwitchCommands.hideDesktopRead)
        async let showHidden = read(SwitchCommands.showHiddenRead)
        async let bigCursor = read(SwitchCommands.bigCursorRead)
        async let lidClosed = read(SwitchCommands.lidClosedRead)
        hideDesktopOn = SwitchCommands.hideDesktopIsOn(fromRead: await hideDesktop)
        showHiddenOn = SwitchCommands.showHiddenIsOn(fromRead: await showHidden)
        bigCursorOn = SwitchCommands.bigCursorIsOn(fromRead: await bigCursor)
        lidClosedOn = SwitchCommands.lidClosedIsOn(fromRead: await lidClosed)
        lidRuleInstalled = ruleExists()
        // A session the user cannot see the effect of is just a stale label.
        if !lidClosedOn { clearLidSession() }
    }

    // MARK: - Toggles

    func setKeepAwake(_ on: Bool) {
        if on { power.acquire() } else { power.release() }
        keepAwakeOn = power.isActive
    }

    /// Flips the system-wide sleep lock: silent when the grant is installed, one
    /// auth dialog when it is not. The prompted path gets a long timeout because
    /// the command sits on that dialog until the user answers it; cancelling it
    /// exits nonzero, so the optimistic toggle reconciles against the live value.
    func setLidClosed(_ on: Bool) async {
        if !on { clearLidSession() }
        lidClosedOn = on
        if await run([SwitchCommands.lidClosedSilent(on)]) { return }
        if await run([SwitchCommands.lidClosedPrompted(on)], timeout: 180) == false {
            lidClosedOn = SwitchCommands.lidClosedIsOn(fromRead: await read(SwitchCommands.lidClosedRead))
        }
    }

    // MARK: - Lid Closed timed sessions

    /// Keeps the machine up for `hours`, then puts it back to sleep. The whole
    /// point is a closed lid with nobody watching, so the end of the session has
    /// to be self-serving: it restores normal sleep and then sleeps the Mac,
    /// rather than leaving the setting off until someone opens the popover.
    func startLidSession(hours: Double) async {
        await setLidClosed(true)
        guard lidClosedOn else { return }
        lidSessionEnd = Date().addingTimeInterval(hours * 3600)
        lidSessionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hours * 3600))
            guard !Task.isCancelled else { return }
            await self?.endLidSession()
        }
    }

    /// Drops the timer and leaves the switch as it is, so "no deadline" and "off"
    /// stay separate actions.
    func cancelLidSession() {
        clearLidSession()
    }

    /// Timer expiry: normal sleep back on, then sleep now. `pmset sleepnow`
    /// needs no privilege for the console user.
    func endLidSession() async {
        clearLidSession()
        await setLidClosed(false)
        guard !lidClosedOn else { return }
        await run([SwitchCommands.sleepNow])
    }

    private func clearLidSession() {
        lidSessionTask?.cancel()
        lidSessionTask = nil
        lidSessionEnd = nil
    }

    // MARK: - Lid Closed one-time grant

    /// Installs the NOPASSWD rule so later flips need no password. Optional: the
    /// switch already works without it, one dialog per flip.
    func installLidPermission() async {
        let staged = (NSTemporaryDirectory() as NSString).appendingPathComponent("pear-lidclosed.rule")
        guard SwitchCommands.isShellSafe(staged) else { return }
        let rule = SwitchCommands.lidClosedRule(user: NSUserName())
        guard (try? rule.write(toFile: staged, atomically: true, encoding: .utf8)) != nil else { return }
        await run([SwitchCommands.installLidRule(stagedAt: staged)], timeout: 180)
        try? FileManager.default.removeItem(atPath: staged)
        lidRuleInstalled = ruleExists()
    }

    /// Removes the rule. Turns the switch off first, while doing so is still
    /// silent, so revoking the grant cannot strand a machine that never sleeps.
    func removeLidPermission() async {
        if lidClosedOn { await setLidClosed(false) }
        await run([SwitchCommands.removeLidRule], timeout: 180)
        lidRuleInstalled = ruleExists()
    }

    /// Last chance to put the machine back the way it was. Runs on
    /// `willTerminate`, where there is no time to await anything and no dialog
    /// would be answered, so it is synchronous and silent: only the granted path
    /// can work here, and without the grant the grid's warning is what stands.
    private func restoreLidOnQuit() {
        guard lidClosedOn, lidRuleInstalled, !SwitchTestGuard.isRunningTests else { return }
        let command = SwitchCommands.lidClosedSilent(false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.binary)
        process.arguments = command.arguments
        try? process.run()
        process.waitUntilExit()
    }

    func setMute(_ on: Bool) {
        audio.setMuted(on)
        muteOn = audio.isMuted()
    }

    func setHideDesktop(_ on: Bool) async {
        hideDesktopOn = on
        if await run(SwitchCommands.hideDesktop(on)) == false {
            // The write didn't take — reconcile the optimistic toggle with the
            // switch's real state instead of leaving a lie on screen.
            hideDesktopOn = SwitchCommands.hideDesktopIsOn(fromRead: await read(SwitchCommands.hideDesktopRead))
        }
    }

    func setShowHidden(_ on: Bool) async {
        showHiddenOn = on
        if await run(SwitchCommands.showHidden(on)) == false {
            showHiddenOn = SwitchCommands.showHiddenIsOn(fromRead: await read(SwitchCommands.showHiddenRead))
        }
    }

    func setBigCursor(_ on: Bool) async {
        bigCursorOn = on
        if await run(SwitchCommands.bigCursor(on)) == false {
            bigCursorOn = SwitchCommands.bigCursorIsOn(fromRead: await read(SwitchCommands.bigCursorRead))
        }
    }

    // MARK: - Momentary actions

    func launchScreenSaver() async {
        await run([SwitchCommands.screenSaver])
    }

    func lockScreen() {
        locker.lock()
    }

    /// Tool teardown mirror: release the power assertion when the tool is
    /// disabled or the app quits. Lid Closed is machine state rather than a held
    /// assertion, so it is restored from `restoreLidOnQuit` instead; all that is
    /// dropped here is the pending timer, which cannot outlive the tool.
    func teardown() {
        power.release()
        keepAwakeOn = false
        clearLidSession()
    }

    // MARK: - Internals

    /// Runs each command in order. Returns false if any command reported
    /// anything other than success, so a toggle can reconcile itself.
    @discardableResult
    private func run(_ commands: [ShellCommand], timeout: TimeInterval = 8) async -> Bool {
        var ok = true
        for command in commands {
            if case .success = await commandRunner.run(
                binary: command.binary, arguments: command.arguments, timeout: timeout) {
                continue
            }
            ok = false
        }
        return ok
    }

    private func read(_ command: ShellCommand) async -> String? {
        guard case .success(let data) = await commandRunner.run(
            binary: command.binary, arguments: command.arguments, timeout: 5
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
