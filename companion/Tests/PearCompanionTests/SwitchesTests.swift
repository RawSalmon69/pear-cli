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

    func testSevenOwnerLockedSwitches() {
        // Two removals at the owner's order: Screen Test (hard-locked a machine
        // with undismissable fullscreen overlays) and Mute. Lid Closed was added.
        XCTAssertEqual(SystemSwitch.allCases.count, 7)
        XCTAssertEqual(
            SystemSwitch.allCases.map(\.rawValue),
            ["keepAwake", "lidClosed", "screenSaver", "lockScreen",
             "hideDesktop", "showHidden", "bigCursor"]
        )
        XCTAssertFalse(
            SystemSwitch.allCases.contains { $0.rawValue == "mute" },
            "Mute was removed entirely; do not reintroduce it")
    }

    func testSwitchKinds() {
        let toggles: Set<SystemSwitch> = [
            .keepAwake, .lidClosed, .hideDesktop, .showHidden, .bigCursor,
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
        for toggle in [SystemSwitch.keepAwake, .screenSaver, .lockScreen] {
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
        XCTAssertTrue(SwitchesSettings.isVisible(.bigCursor, defaults))
    }

    func testVisibleSwitchesFiltersAndKeepsOrder() {
        let suite = "switches-visible-list"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // Defaults: the four transient switches, in owner-locked order.
        XCTAssertEqual(
            SwitchesSettings.visibleSwitches(defaults),
            [.keepAwake, .screenSaver, .lockScreen]
        )

        SwitchesSettings.setVisible(.hideDesktop, true, defaults)
        SwitchesSettings.setVisible(.keepAwake, false, defaults)
        XCTAssertEqual(
            SwitchesSettings.visibleSwitches(defaults),
            [.screenSaver, .lockScreen, .hideDesktop]
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

    // MARK: - Lid Closed never turns itself on

    /// Every command that would enable the lock, in both flip shapes.
    private func turnsLidOn(_ command: ShellCommand) -> Bool {
        command == SwitchCommands.lidClosedSilent(true)
            || command == SwitchCommands.lidClosedPrompted(true)
    }

    func testNothingButAnExplicitFlipEverEnablesTheLock() async {
        // Construct, open the popover, disable the tool. The system reports the
        // lock already on, which is the state most likely to tempt a re-assert.
        let runner = MockCommandRunner { command in
            command == SwitchCommands.lidClosedRead
                ? success("System-wide power settings:\n SleepDisabled\t\t1\n")
                : .failed
        }
        let model = makeModel(runner: runner, ruleExists: { true })
        await model.refresh()
        model.teardown()

        XCTAssertTrue(model.lidClosedOn, "refresh reports what the system says")
        XCTAssertFalse(
            runner.recorded.contains(where: turnsLidOn),
            "no lifecycle step may enable the lock; only a tap may")
    }

    func testALockPearDidNotSetIsNeverRestoredOnQuit() async {
        // Somebody else disabled sleep (a terminal, another app, a crashed run).
        // Pear shows it, and leaves it alone at quit.
        let runner = MockCommandRunner { command in
            command == SwitchCommands.lidClosedRead
                ? success("System-wide power settings:\n SleepDisabled\t\t1\n")
                : .failed
        }
        let model = makeModel(runner: runner, ruleExists: { true })
        await model.refresh()

        XCTAssertTrue(model.lidClosedOn)
        XCTAssertFalse(model.lidClosedIsOurs)
        XCTAssertFalse(
            model.shouldRestoreLidOnQuit,
            "quitting must not clear a lock the user set outside Pear")
    }

    func testALockPearSetIsRestoredOnQuit() async {
        let runner = MockCommandRunner { _ in .success(Data()) }
        let model = makeModel(runner: runner, ruleExists: { true })
        await model.setLidClosed(true)

        XCTAssertTrue(model.lidClosedIsOurs)
        XCTAssertTrue(model.shouldRestoreLidOnQuit)

        await model.setLidClosed(false)
        XCTAssertFalse(model.lidClosedIsOurs)
        XCTAssertFalse(model.shouldRestoreLidOnQuit)
    }

    func testAFailedFlipClaimsNoOwnership() async {
        // Both paths fail and the lock turns out to be on anyway: that is not
        // ours to undo.
        let runner = MockCommandRunner { command in
            command == SwitchCommands.lidClosedRead
                ? success("System-wide power settings:\n SleepDisabled\t\t1\n")
                : .failed
        }
        let model = makeModel(runner: runner, ruleExists: { true })
        await model.setLidClosed(true)

        XCTAssertTrue(model.lidClosedOn)
        XCTAssertFalse(model.lidClosedIsOurs)
        XCTAssertFalse(model.shouldRestoreLidOnQuit)
    }

    func testRefreshDisownsALockThatWentAwayBehindOurBack() async {
        let runner = MockCommandRunner { _ in .success(Data()) }
        let model = makeModel(runner: runner, ruleExists: { true })
        await model.setLidClosed(true)
        XCTAssertTrue(model.lidClosedIsOurs)

        // Somebody cleared it elsewhere; the next popover open must not keep
        // claiming a lock that no longer exists.
        let quiet = MockCommandRunner { _ in .failed }
        let reopened = makeModel(runner: quiet, ruleExists: { true })
        await reopened.refresh()
        XCTAssertFalse(reopened.lidClosedOn)
        XCTAssertFalse(reopened.lidClosedIsOurs)
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
        let model = makeModel(runner: runner, power: power)

        await model.refresh()
        XCTAssertTrue(model.keepAwakeOn)
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

    private func makeModel(
        runner: CommandRunner = MockCommandRunner(),
        power: PowerAssertioning = MockPowerAssertion(),
        locker: ScreenLocking = MockScreenLocking(),
        ruleExists: @escaping @Sendable () -> Bool = { false }
    ) -> SwitchesModel {
        SwitchesModel(
            commandRunner: runner, power: power, locker: locker,
            ruleExists: ruleExists)
    }
}
