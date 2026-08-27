import XCTest

@testable import PearCompanion

// MARK: - Test doubles

/// Records every command line and answers reads from an injected responder, so
/// the model never spawns a process. `@unchecked Sendable`: `_recorded` is only
/// mutated under `lock`, and tests read `recorded` after their `await`s resolve
/// on the main actor, so there is no concurrent reader.
private final class MockCommandRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _recorded: [ShellCommand] = []
    private let responder: @Sendable (ShellCommand) -> CommandResult

    init(responder: @escaping @Sendable (ShellCommand) -> CommandResult = { _ in .failed }) {
        self.responder = responder
    }

    var recorded: [ShellCommand] { lock.withLock { _recorded } }

    func run(binary: String, arguments: [String], timeout: TimeInterval?) async -> CommandResult {
        let command = ShellCommand(binary: binary, arguments: arguments)
        lock.withLock { _recorded.append(command) }
        return responder(command)
    }
}

@MainActor
private final class MockPowerAssertion: PowerAssertioning {
    private(set) var isActive = false
    var acquireResult = true
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0

    @discardableResult
    func acquire() -> Bool {
        acquireCount += 1
        isActive = acquireResult
        return isActive
    }

    func release() {
        releaseCount += 1
        isActive = false
    }
}

/// A device with whatever knobs a test says it has. `flag == nil` models the
/// outputs that publish no mute element at all (AirPods, most HDMI); `honoursFlag
/// == false` models the ones that accept the write, report it back, and keep
/// playing anyway — which is what made the switch look dead.
@MainActor
private final class FakeOutputDevice: AudioOutputDevice {
    var flag: Bool?
    var volume: Float?
    var writtenVolumes: [Float] = []

    init(flag: Bool? = false, volume: Float? = 0.6) {
        self.flag = flag
        self.volume = volume
    }

    func readMuteFlag() -> Bool? { flag }

    @discardableResult
    func writeMuteFlag(_ muted: Bool) -> Bool {
        guard flag != nil else { return false }
        flag = muted
        return true
    }

    func readVolume() -> Float? { volume }

    @discardableResult
    func writeVolume(_ newVolume: Float) -> Bool {
        guard volume != nil else { return false }
        volume = newVolume
        writtenVolumes.append(newVolume)
        return true
    }
}

@MainActor
private final class MockAudioMuting: AudioMuting {
    var muted = false
    private(set) var setCount = 0

    func isMuted() -> Bool { muted }
    func setMuted(_ value: Bool) {
        setCount += 1
        muted = value
    }
}

@MainActor
private final class MockScreenLocking: ScreenLocking {
    private(set) var lockCount = 0
    func lock() { lockCount += 1 }
}

private func success(_ string: String) -> CommandResult { .success(Data(string.utf8)) }

/// Stands in for the sudoers rule's presence on disk, so a test can prove the
/// model re-reads it after the install/remove command rather than assuming.
private final class RuleFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var present: Bool
    init(present: Bool) { self.present = present }
    var isPresent: Bool { lock.withLock { present } }
    func set(_ value: Bool) { lock.withLock { present = value } }
}

@MainActor
final class SwitchesTests: XCTestCase {
    // MARK: - SystemSwitch metadata

    func testEightOwnerLockedSwitches() {
        // Screen Test was removed at the owner's order (hard-locked a machine
        // with undismissable fullscreen overlays); Lid Closed was added later.
        XCTAssertEqual(SystemSwitch.allCases.count, 8)
        XCTAssertEqual(
            SystemSwitch.allCases.map(\.rawValue),
            ["keepAwake", "lidClosed", "mute", "screenSaver", "lockScreen",
             "hideDesktop", "showHidden", "bigCursor"]
        )
    }

    func testSwitchKinds() {
        let toggles: Set<SystemSwitch> = [
            .keepAwake, .lidClosed, .mute, .hideDesktop, .showHidden, .bigCursor,
        ]
        for toggle in SystemSwitch.allCases {
            let expected: SystemSwitch.Kind = toggles.contains(toggle) ? .toggle : .momentary
            XCTAssertEqual(toggle.kind, expected, "\(toggle.rawValue)")
        }
    }

    func testSystemMutatingSwitchesDefaultHidden() {
        XCTAssertFalse(SystemSwitch.lidClosed.defaultVisible)
        XCTAssertFalse(SystemSwitch.hideDesktop.defaultVisible)
        XCTAssertFalse(SystemSwitch.showHidden.defaultVisible)
        XCTAssertFalse(SystemSwitch.bigCursor.defaultVisible)
        for toggle in [SystemSwitch.keepAwake, .mute, .screenSaver, .lockScreen] {
            XCTAssertTrue(toggle.defaultVisible, "\(toggle.rawValue) should default shown")
        }
    }

    // MARK: - SwitchesSettings (visibility accessors)

    func testVisibilityDefaultsWhenUnset() {
        let suite = "switches-visibility-defaults"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        for toggle in SystemSwitch.allCases {
            XCTAssertEqual(SwitchesSettings.isVisible(toggle, defaults), toggle.defaultVisible, "\(toggle.rawValue)")
        }
    }

    func testVisibilityRoundTrip() {
        let suite = "switches-visibility-roundtrip"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        SwitchesSettings.setVisible(.bigCursor, true, defaults)
        SwitchesSettings.setVisible(.mute, false, defaults)
        XCTAssertTrue(SwitchesSettings.isVisible(.bigCursor, defaults))
        XCTAssertFalse(SwitchesSettings.isVisible(.mute, defaults))
    }

    func testVisibleSwitchesFiltersAndKeepsOrder() {
        let suite = "switches-visible-list"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // Defaults: the four transient switches, in owner-locked order.
        XCTAssertEqual(
            SwitchesSettings.visibleSwitches(defaults),
            [.keepAwake, .mute, .screenSaver, .lockScreen]
        )

        SwitchesSettings.setVisible(.hideDesktop, true, defaults)
        SwitchesSettings.setVisible(.keepAwake, false, defaults)
        XCTAssertEqual(
            SwitchesSettings.visibleSwitches(defaults),
            [.mute, .screenSaver, .lockScreen, .hideDesktop]
        )
    }

    func testShowKeyFormat() {
        XCTAssertEqual(SwitchesSettings.showKey(.keepAwake), "switches.show.keepAwake")
        XCTAssertEqual(SwitchesSettings.showKey(.bigCursor), "switches.show.bigCursor")
    }

    // MARK: - SwitchCommands (pure builders + parsers)

    func testHideDesktopCommands() {
        XCTAssertEqual(SwitchCommands.hideDesktop(true), [
            ShellCommand(binary: "/usr/bin/defaults",
                         arguments: ["write", "com.apple.finder", "CreateDesktop", "-bool", "false"]),
            ShellCommand(binary: "/usr/bin/killall", arguments: ["Finder"]),
        ])
        XCTAssertEqual(SwitchCommands.hideDesktop(false), [
            ShellCommand(binary: "/usr/bin/defaults",
                         arguments: ["write", "com.apple.finder", "CreateDesktop", "-bool", "true"]),
            ShellCommand(binary: "/usr/bin/killall", arguments: ["Finder"]),
        ])
    }

    func testHideDesktopReadCommand() {
        XCTAssertEqual(SwitchCommands.hideDesktopRead,
                       ShellCommand(binary: "/usr/bin/defaults", arguments: ["read", "com.apple.finder", "CreateDesktop"]))
    }

    func testHideDesktopParse() {
        XCTAssertFalse(SwitchCommands.hideDesktopIsOn(fromRead: nil))
        XCTAssertFalse(SwitchCommands.hideDesktopIsOn(fromRead: ""))
        XCTAssertTrue(SwitchCommands.hideDesktopIsOn(fromRead: "0\n"))
        XCTAssertTrue(SwitchCommands.hideDesktopIsOn(fromRead: "false"))
        XCTAssertFalse(SwitchCommands.hideDesktopIsOn(fromRead: "1"))
        XCTAssertFalse(SwitchCommands.hideDesktopIsOn(fromRead: "true"))
    }

    func testShowHiddenCommands() {
        XCTAssertEqual(SwitchCommands.showHidden(true), [
            ShellCommand(binary: "/usr/bin/defaults",
                         arguments: ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", "true"]),
            ShellCommand(binary: "/usr/bin/killall", arguments: ["Finder"]),
        ])
        XCTAssertEqual(SwitchCommands.showHidden(false).first?.arguments.last, "false")
    }

    func testShowHiddenParse() {
        XCTAssertFalse(SwitchCommands.showHiddenIsOn(fromRead: nil))
        XCTAssertTrue(SwitchCommands.showHiddenIsOn(fromRead: "1\n"))
        XCTAssertTrue(SwitchCommands.showHiddenIsOn(fromRead: "true"))
        XCTAssertFalse(SwitchCommands.showHiddenIsOn(fromRead: "0"))
    }

    func testBigCursorCommands() {
        XCTAssertEqual(SwitchCommands.bigCursor(true), [
            ShellCommand(binary: "/usr/bin/defaults",
                         arguments: ["write", "com.apple.universalaccess", "mouseDriverCursorSize", "-float", "3"]),
        ])
        XCTAssertEqual(SwitchCommands.bigCursor(false).first?.arguments.last, "1")
    }

    func testBigCursorParse() {
        XCTAssertFalse(SwitchCommands.bigCursorIsOn(fromRead: nil))
        XCTAssertFalse(SwitchCommands.bigCursorIsOn(fromRead: "1"))
        XCTAssertTrue(SwitchCommands.bigCursorIsOn(fromRead: "3"))
        XCTAssertTrue(SwitchCommands.bigCursorIsOn(fromRead: "2.5\n"))
        XCTAssertFalse(SwitchCommands.bigCursorIsOn(fromRead: "garbage"))
    }

    func testLidClosedPromptedGoesThroughAdminAuthorization() {
        let on = SwitchCommands.lidClosedPrompted(true)
        XCTAssertEqual(on.binary, "/usr/bin/osascript")
        XCTAssertEqual(on.arguments.first, "-e")
        XCTAssertEqual(
            on.arguments.last,
            "do shell script \"/usr/bin/pmset -a disablesleep 1\" with administrator privileges")
        XCTAssertTrue(
            SwitchCommands.lidClosedPrompted(false).arguments.last?.contains("disablesleep 0") == true)
    }

    func testLidClosedSilentNeverPrompts() {
        XCTAssertEqual(
            SwitchCommands.lidClosedSilent(true),
            ShellCommand(binary: "/usr/bin/sudo",
                         arguments: ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"]))
        XCTAssertEqual(
            SwitchCommands.lidClosedSilent(false).arguments.first, "-n",
            "-n is what keeps the fallback path from racing a hidden password prompt")
    }

    func testLidClosedRuleGrantsExactlyTwoCommandLines() {
        let rule = SwitchCommands.lidClosedRule(user: "casey")
        XCTAssertEqual(
            rule,
            "casey ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1,"
                + " /usr/bin/pmset -a disablesleep 0\n")
        XCTAssertFalse(rule.contains("ALL=(ALL)"), "the grant must not widen past those two lines")
        XCTAssertFalse(rule.contains("*"), "no wildcard: sudoers matches arguments exactly")
    }

    func testInstallLidRuleValidatesBeforeItInstalls() {
        let script = SwitchCommands.installLidRule(stagedAt: "/tmp/pear.rule").arguments.last ?? ""
        guard let validate = script.range(of: "visudo -cf"),
              let install = script.range(of: "mv '/etc/sudoers.d/.pear-lidclosed.staged'")
        else { return XCTFail("expected a validate step and a rename step, got: \(script)") }
        XCTAssertTrue(
            validate.lowerBound < install.lowerBound,
            "visudo must gate the rename: a malformed file in /etc/sudoers.d breaks sudo entirely")
        XCTAssertTrue(
            script.contains("&& mv"), "the rename must be conditional on every step before it")
        XCTAssertTrue(
            script.contains("rm -f '/etc/sudoers.d/.pear-lidclosed.staged'; exit 1"),
            "a failed install must clean up and report failure")
    }

    func testStagedRuleNameIsInvisibleToSudo() {
        // sudo's includedir skips any filename containing a dot, which is what
        // keeps the half-installed file from being read while it is staged.
        let staged = (SwitchCommands.sudoersStagePath as NSString).lastPathComponent
        XCTAssertTrue(staged.contains("."))
        XCTAssertFalse((SwitchCommands.sudoersRulePath as NSString).lastPathComponent.contains("."))
    }

    func testRemoveLidRuleTargetsOnlyOurFile() {
        XCTAssertEqual(
            SwitchCommands.removeLidRule.arguments.last,
            "do shell script \"rm -f '/etc/sudoers.d/pear-lidclosed'\" with administrator privileges")
    }

    func testShellSafetyRejectsQuotedPaths() {
        XCTAssertTrue(SwitchCommands.isShellSafe("/var/folders/ab/T/pear-lidclosed.rule"))
        XCTAssertFalse(SwitchCommands.isShellSafe("/tmp/pear'; rm -rf /; echo '.rule"))
        XCTAssertFalse(SwitchCommands.isShellSafe("/tmp/pear\".rule"))
        XCTAssertFalse(SwitchCommands.isShellSafe("/tmp/pear\\.rule"))
    }

    func testLidClosedParse() {
        let live = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1\n"
        XCTAssertTrue(SwitchCommands.lidClosedIsOn(fromRead: live))
        XCTAssertFalse(SwitchCommands.lidClosedIsOn(
            fromRead: "System-wide power settings:\n SleepDisabled\t\t0\n"))
        // No SleepDisabled row at all (desktop Macs omit it) reads as off.
        XCTAssertFalse(SwitchCommands.lidClosedIsOn(fromRead: "Currently in use:\n sleep 1\n"))
        XCTAssertFalse(SwitchCommands.lidClosedIsOn(fromRead: nil))
    }

    // MARK: - Mute (flag plus level, because the flag alone is ignored)

    func testMutingZeroesTheLevelAsWellAsSettingTheFlag() {
        // The bug this covers: a device accepts the flag, reports it back, and
        // keeps playing. Silence has to come from the level.
        let device = FakeOutputDevice(flag: false, volume: 0.6)
        let store = ephemeralDefaults()
        let controller = CoreAudioMuteController(device: device, store: store)

        controller.setMuted(true)
        XCTAssertEqual(device.flag, true)
        XCTAssertEqual(device.volume, 0)
        XCTAssertEqual(store.object(forKey: Prefs.preMuteVolumeKey) as? Float, 0.6)
    }

    func testUnmutingPutsTheSavedLevelBack() {
        let device = FakeOutputDevice(flag: false, volume: 0.6)
        let store = ephemeralDefaults()
        let controller = CoreAudioMuteController(device: device, store: store)

        controller.setMuted(true)
        controller.setMuted(false)
        XCTAssertEqual(device.flag, false)
        XCTAssertEqual(device.volume, 0.6)
        XCTAssertNil(
            store.object(forKey: Prefs.preMuteVolumeKey),
            "a stale level must not survive to raise the volume on some later unmute")
    }

    func testUnmutingLeavesAVolumeTheUserAlreadyRaisedAlone() {
        let device = FakeOutputDevice(flag: false, volume: 0.6)
        let store = ephemeralDefaults()
        let controller = CoreAudioMuteController(device: device, store: store)

        controller.setMuted(true)
        device.volume = 0.2      // the user reached for the media key meanwhile
        controller.setMuted(false)
        XCTAssertEqual(device.volume, 0.2, "restoring over the user's own level is not our call")
    }

    func testDeviceWithNoMuteElementIsStillMutedByLevel() {
        // AirPods, most HDMI: no mute element at all, so the old code silently
        // did nothing and reported not-muted.
        let device = FakeOutputDevice(flag: nil, volume: 0.8)
        let controller = CoreAudioMuteController(device: device, store: ephemeralDefaults())

        XCTAssertFalse(controller.isMuted())
        controller.setMuted(true)
        XCTAssertEqual(device.volume, 0)
        XCTAssertTrue(controller.isMuted(), "with no flag to read, silence is the state")

        controller.setMuted(false)
        XCTAssertEqual(device.volume, 0.8)
        XCTAssertFalse(controller.isMuted())
    }

    func testMutingTwiceDoesNotSaveZeroAsTheLevelToRestore() {
        let device = FakeOutputDevice(flag: false, volume: 0.6)
        let store = ephemeralDefaults()
        let controller = CoreAudioMuteController(device: device, store: store)

        controller.setMuted(true)
        controller.setMuted(true)   // second flip must not overwrite 0.6 with 0
        controller.setMuted(false)
        XCTAssertEqual(device.volume, 0.6)
    }

    func testFlagIsPreferredOverLevelWhenReadingState() {
        // A device sitting at zero volume but unmuted reads as unmuted, so the
        // tile does not claim a mute the user did not ask for.
        let device = FakeOutputDevice(flag: false, volume: 0)
        let controller = CoreAudioMuteController(device: device, store: ephemeralDefaults())
        XCTAssertFalse(controller.isMuted())

        device.flag = true
        XCTAssertTrue(controller.isMuted())
    }

    func testScreenSaverCommand() {
        XCTAssertEqual(SwitchCommands.screenSaver,
                       ShellCommand(binary: "/usr/bin/open", arguments: ["-a", "ScreenSaverEngine"]))
    }

    // MARK: - Model command-line assertions (mock runner)

    func testSetHideDesktopOnRunsWriteThenKillall() async {
        // Writes succeed, so no reconciling re-read runs and the optimistic
        // state stands — recorded commands are exactly the write + killall.
        let runner = MockCommandRunner { _ in .success(Data()) }
        let model = makeModel(runner: runner)
        await model.setHideDesktop(true)
        XCTAssertEqual(runner.recorded, SwitchCommands.hideDesktop(true))
        XCTAssertTrue(model.hideDesktopOn)
    }

    func testSetHideDesktopOffRunsWriteThenKillall() async {
        let runner = MockCommandRunner { _ in .success(Data()) }
        let model = makeModel(runner: runner)
        await model.setHideDesktop(false)
        XCTAssertEqual(runner.recorded, SwitchCommands.hideDesktop(false))
        XCTAssertFalse(model.hideDesktopOn)
    }

    func testSetShowHiddenRunsExactCommands() async {
        let runner = MockCommandRunner { _ in .success(Data()) }
        let model = makeModel(runner: runner)
        await model.setShowHidden(true)
        XCTAssertEqual(runner.recorded, SwitchCommands.showHidden(true))
        XCTAssertTrue(model.showHiddenOn)
    }

    func testSetBigCursorRunsExactCommand() async {
        let runner = MockCommandRunner { _ in .success(Data()) }
        let model = makeModel(runner: runner)
        await model.setBigCursor(true)
        XCTAssertEqual(runner.recorded, SwitchCommands.bigCursor(true))
        XCTAssertTrue(model.bigCursorOn)
    }

    func testGrantedLidFlipNeverReachesTheAuthDialog() async {
        // With the rule installed the silent path succeeds, and the prompted
        // command must not run at all.
        let runner = MockCommandRunner { _ in .success(Data()) }
        let model = makeModel(runner: runner, ruleExists: { true })
        await model.setLidClosed(true)
        XCTAssertEqual(runner.recorded, [SwitchCommands.lidClosedSilent(true)])
        XCTAssertTrue(model.lidClosedOn)
    }

    func testUngrantedLidFlipFallsBackToTheAuthDialog() async {
        // No rule: `sudo -n` fails instantly, and the prompted command carries
        // the flip. Order matters — silent first, prompt second.
        let runner = MockCommandRunner { command in
            command == SwitchCommands.lidClosedSilent(true) ? .failed : .success(Data())
        }
        let model = makeModel(runner: runner)
        await model.setLidClosed(true)
        XCTAssertEqual(
            runner.recorded,
            [SwitchCommands.lidClosedSilent(true), SwitchCommands.lidClosedPrompted(true)])
        XCTAssertTrue(model.lidClosedOn)
    }

    func testCancelledLidClosedAuthReconcilesBackToOff() async {
        // Cancelling the macOS auth dialog exits nonzero, so the optimistic
        // toggle must snap back to what the system really reports.
        let runner = MockCommandRunner { command in
            command == SwitchCommands.lidClosedRead
                ? success("System-wide power settings:\n SleepDisabled\t\t0\n")
                : .failed
        }
        let model = makeModel(runner: runner)
        await model.setLidClosed(true)
        XCTAssertFalse(model.lidClosedOn)
        XCTAssertEqual(runner.recorded.last, SwitchCommands.lidClosedRead)
    }

    func testTimedSessionSetsADeadlineAndTurningOffClearsIt() async {
        let runner = MockCommandRunner { _ in .success(Data()) }
        let model = makeModel(runner: runner)
        await model.startLidSession(hours: 5)
        XCTAssertTrue(model.lidClosedOn)
        guard let end = model.lidSessionEnd else { return XCTFail("expected a deadline") }
        XCTAssertEqual(end.timeIntervalSinceNow, 5 * 3600, accuracy: 5)

        await model.setLidClosed(false)
        XCTAssertNil(model.lidSessionEnd, "turning the switch off must drop the pending timer")
    }

    func testCancellingTheTimerLeavesTheSwitchOn() async {
        let runner = MockCommandRunner { _ in .success(Data()) }
        let model = makeModel(runner: runner)
        await model.startLidSession(hours: 12)
        model.cancelLidSession()
        XCTAssertNil(model.lidSessionEnd)
        XCTAssertTrue(model.lidClosedOn, "cancelling a deadline is not the same as switching off")
    }

    func testSessionExpiryRestoresSleepThenSleeps() async {
        let runner = MockCommandRunner { _ in .success(Data()) }
        let model = makeModel(runner: runner)
        await model.startLidSession(hours: 5)
        await model.endLidSession()
        XCTAssertFalse(model.lidClosedOn)
        XCTAssertNil(model.lidSessionEnd)
        XCTAssertEqual(runner.recorded.last, SwitchCommands.sleepNow)
        guard let restore = runner.recorded.firstIndex(of: SwitchCommands.lidClosedSilent(false)),
              let sleep = runner.recorded.firstIndex(of: SwitchCommands.sleepNow)
        else { return XCTFail("expected a restore and a sleep, got \(runner.recorded)") }
        XCTAssertTrue(restore < sleep, "sleeping before restoring would just be undone on wake")
    }

    func testExpiryDoesNotSleepWhenSleepCouldNotBeRestored() async {
        // Both flip paths fail and the re-read says the lock is still on. Putting
        // the machine to sleep now would strand it: it cannot wake on a lid open
        // it already had, and the lock is still in place.
        let runner = MockCommandRunner { command in
            command == SwitchCommands.lidClosedRead
                ? success("System-wide power settings:\n SleepDisabled\t\t1\n")
                : .failed
        }
        let model = makeModel(runner: runner)
        await model.endLidSession()
        XCTAssertTrue(model.lidClosedOn)
        XCTAssertFalse(runner.recorded.contains(SwitchCommands.sleepNow))
    }

    func testGrantInstallRunsTheValidatedInstall() async {
        // The flag flips only because the install command ran, so the model has
        // to re-read it afterwards to notice.
        let rule = RuleFlag(present: false)
        let runner = MockCommandRunner { _ in
            rule.set(true)
            return .success(Data())
        }
        let model = makeModel(runner: runner, ruleExists: { rule.isPresent })
        XCTAssertFalse(model.lidRuleInstalled)
        await model.installLidPermission()
        XCTAssertTrue(model.lidRuleInstalled)
        guard let script = runner.recorded.last?.arguments.last else {
            return XCTFail("expected an install command")
        }
        XCTAssertTrue(script.contains("visudo -cf"))
        XCTAssertTrue(script.contains("with administrator privileges"))
    }

    func testRemovingTheGrantTurnsTheSwitchOffFirst() async {
        let rule = RuleFlag(present: true)
        let runner = MockCommandRunner { command in
            if command == SwitchCommands.removeLidRule { rule.set(false) }
            return .success(Data())
        }
        let model = makeModel(runner: runner, ruleExists: { rule.isPresent })
        await model.setLidClosed(true)
        await model.removeLidPermission()
        XCTAssertFalse(model.lidRuleInstalled)
        guard let off = runner.recorded.firstIndex(of: SwitchCommands.lidClosedSilent(false)),
              let remove = runner.recorded.firstIndex(of: SwitchCommands.removeLidRule)
        else { return XCTFail("expected an off-flip and a rule removal, got \(runner.recorded)") }
        XCTAssertTrue(
            off < remove,
            "revoking the grant before the flip would leave a machine that never sleeps")
    }

    func testFailedWriteReReadsAndSelfCorrects() async {
        // The write "fails"; the reconciling read reports the switch is really
        // off, so the optimistic on-toggle must snap back to reality.
        let runner = MockCommandRunner { command in
            command == SwitchCommands.hideDesktopRead ? success("1") /* icons shown = off */ : .failed
        }
        let model = makeModel(runner: runner)
        await model.setHideDesktop(true)
        XCTAssertFalse(model.hideDesktopOn, "a failed write must reconcile with the re-read state")
        XCTAssertEqual(
            runner.recorded.last, SwitchCommands.hideDesktopRead,
            "the last thing run is the reconciling read")
    }

    func testLaunchScreenSaverRunsOpen() async {
        let runner = MockCommandRunner()
        let model = makeModel(runner: runner)
        await model.launchScreenSaver()
        XCTAssertEqual(runner.recorded, [SwitchCommands.screenSaver])
    }

    // MARK: - Model state read (refresh → grid state)

    func testRefreshReadsToggleStatesFromMockedReads() async {
        let runner = MockCommandRunner { command in
            switch command {
            case SwitchCommands.hideDesktopRead: success("0")   // hidden
            case SwitchCommands.showHiddenRead: success("1")    // showing
            case SwitchCommands.bigCursorRead: success("3")     // large
            case SwitchCommands.lidClosedRead:
                success("System-wide power settings:\n SleepDisabled\t\t1\n")
            default: .failed
            }
        }
        let power = MockPowerAssertion()
        power.acquire() // becomes active
        let audio = MockAudioMuting()
        audio.muted = true
        let model = makeModel(runner: runner, power: power, audio: audio)

        await model.refresh()
        XCTAssertTrue(model.keepAwakeOn)
        XCTAssertTrue(model.muteOn)
        XCTAssertTrue(model.hideDesktopOn)
        XCTAssertTrue(model.showHiddenOn)
        XCTAssertTrue(model.bigCursorOn)
        XCTAssertTrue(model.lidClosedOn)
    }

    func testRefreshDefaultsOffWhenReadsFail() async {
        let runner = MockCommandRunner { _ in .failed }
        let model = makeModel(runner: runner)
        await model.refresh()
        XCTAssertFalse(model.keepAwakeOn)
        XCTAssertFalse(model.muteOn)
        XCTAssertFalse(model.hideDesktopOn)
        XCTAssertFalse(model.showHiddenOn)
        XCTAssertFalse(model.bigCursorOn)
        XCTAssertFalse(model.lidClosedOn)
    }

    // MARK: - Model effect seams

    func testSetKeepAwakeAcquiresAndReleases() {
        let power = MockPowerAssertion()
        let model = makeModel(power: power)

        model.setKeepAwake(true)
        XCTAssertEqual(power.acquireCount, 1)
        XCTAssertTrue(model.keepAwakeOn)

        model.setKeepAwake(false)
        XCTAssertEqual(power.releaseCount, 1)
        XCTAssertFalse(model.keepAwakeOn)
    }

    func testKeepAwakeStaysOffWhenAssertionFails() {
        let power = MockPowerAssertion()
        power.acquireResult = false
        let model = makeModel(power: power)
        model.setKeepAwake(true)
        XCTAssertFalse(model.keepAwakeOn, "a failed assertion must not report on")
    }

    func testSetMuteWritesAndReadsBack() {
        let audio = MockAudioMuting()
        let model = makeModel(audio: audio)
        model.setMute(true)
        XCTAssertEqual(audio.setCount, 1)
        XCTAssertTrue(audio.muted)
        XCTAssertTrue(model.muteOn)
    }

    func testLockScreenCallsLocker() {
        let locker = MockScreenLocking()
        let model = makeModel(locker: locker)
        model.lockScreen()
        XCTAssertEqual(locker.lockCount, 1)
    }

    func testTeardownReleasesAssertion() {
        let power = MockPowerAssertion()
        let model = makeModel(power: power)
        model.setKeepAwake(true)
        model.teardown()
        XCTAssertGreaterThanOrEqual(power.releaseCount, 1)
        XCTAssertFalse(model.keepAwakeOn)
    }

    // MARK: - Helpers

    /// A throwaway defaults domain, named per test and wiped on creation, so a
    /// saved pre-mute level cannot leak from one test into another.
    private func ephemeralDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "switches-mute-\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeModel(
        runner: CommandRunner = MockCommandRunner(),
        power: PowerAssertioning = MockPowerAssertion(),
        audio: AudioMuting = MockAudioMuting(),
        locker: ScreenLocking = MockScreenLocking(),
        ruleExists: @escaping @Sendable () -> Bool = { false }
    ) -> SwitchesModel {
        SwitchesModel(
            commandRunner: runner, power: power, audio: audio, locker: locker,
            ruleExists: ruleExists)
    }
}
