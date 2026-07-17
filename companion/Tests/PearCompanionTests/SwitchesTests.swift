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

@MainActor
final class SwitchesTests: XCTestCase {
    // MARK: - SystemSwitch metadata

    func testSevenOwnerLockedSwitches() {
        // Was eight: Screen Test was removed at the owner's order (hard-locked
        // a machine with undismissable fullscreen overlays).
        XCTAssertEqual(SystemSwitch.allCases.count, 7)
        XCTAssertEqual(
            SystemSwitch.allCases.map(\.rawValue),
            ["keepAwake", "mute", "screenSaver", "lockScreen", "hideDesktop", "showHidden", "bigCursor"]
        )
    }

    func testSwitchKinds() {
        let toggles: Set<SystemSwitch> = [.keepAwake, .mute, .hideDesktop, .showHidden, .bigCursor]
        for toggle in SystemSwitch.allCases {
            let expected: SystemSwitch.Kind = toggles.contains(toggle) ? .toggle : .momentary
            XCTAssertEqual(toggle.kind, expected, "\(toggle.rawValue)")
        }
    }

    func testSystemMutatingSwitchesDefaultHidden() {
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

    func testScreenSaverCommand() {
        XCTAssertEqual(SwitchCommands.screenSaver,
                       ShellCommand(binary: "/usr/bin/open", arguments: ["-a", "ScreenSaverEngine"]))
    }

    // MARK: - Model command-line assertions (mock runner)

    func testSetHideDesktopOnRunsWriteThenKillall() async {
        let runner = MockCommandRunner()
        let model = makeModel(runner: runner)
        await model.setHideDesktop(true)
        XCTAssertEqual(runner.recorded, SwitchCommands.hideDesktop(true))
        XCTAssertTrue(model.hideDesktopOn)
    }

    func testSetHideDesktopOffRunsWriteThenKillall() async {
        let runner = MockCommandRunner()
        let model = makeModel(runner: runner)
        await model.setHideDesktop(false)
        XCTAssertEqual(runner.recorded, SwitchCommands.hideDesktop(false))
        XCTAssertFalse(model.hideDesktopOn)
    }

    func testSetShowHiddenRunsExactCommands() async {
        let runner = MockCommandRunner()
        let model = makeModel(runner: runner)
        await model.setShowHidden(true)
        XCTAssertEqual(runner.recorded, SwitchCommands.showHidden(true))
        XCTAssertTrue(model.showHiddenOn)
    }

    func testSetBigCursorRunsExactCommand() async {
        let runner = MockCommandRunner()
        let model = makeModel(runner: runner)
        await model.setBigCursor(true)
        XCTAssertEqual(runner.recorded, SwitchCommands.bigCursor(true))
        XCTAssertTrue(model.bigCursorOn)
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

    private func makeModel(
        runner: CommandRunner = MockCommandRunner(),
        power: PowerAssertioning = MockPowerAssertion(),
        audio: AudioMuting = MockAudioMuting(),
        locker: ScreenLocking = MockScreenLocking()
    ) -> SwitchesModel {
        SwitchesModel(commandRunner: runner, power: power, audio: audio, locker: locker)
    }
}
