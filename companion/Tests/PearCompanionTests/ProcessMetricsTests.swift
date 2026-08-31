import XCTest

@testable import PearCompanion

final class ProcessMetricsTests: XCTestCase {
    // MARK: - Fixtures

    private func process(
        _ pid: Int32,
        parent: Int32 = 1,
        name: String? = nil,
        cpuSeconds: Double = 0,
        footprint: UInt64 = 1_000_000,
        diskBytes: UInt64 = 0,
        wakeups: UInt64 = 0,
        threads: Int = 1,
        startedAt: UInt64 = 100,
        isApp: Bool = false
    ) -> RawProcess {
        RawProcess(
            pid: pid, parentPid: parent, name: name ?? "proc\(pid)", cpuSeconds: cpuSeconds,
            footprint: footprint, diskBytes: diskBytes, wakeups: wakeups, threads: threads,
            startedAt: startedAt, isApp: isApp)
    }

    private func keyed(_ processes: [RawProcess]) -> [Int32: RawProcess] {
        Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Rollup

    func testHelpersAreSummedIntoTheAppThatSpawnedThem() {
        // A browser: the app, a helper it spawned, and a helper the helper
        // spawned. One row, three processes, costs added up.
        let before = [
            process(100, name: "Browser", cpuSeconds: 10, isApp: true),
            process(200, parent: 100, name: "Browser Helper", cpuSeconds: 20),
            process(300, parent: 200, name: "Browser Helper (Renderer)", cpuSeconds: 30),
        ]
        let after = [
            process(100, name: "Browser", cpuSeconds: 10.5, isApp: true),
            process(200, parent: 100, name: "Browser Helper", cpuSeconds: 21),
            process(300, parent: 200, name: "Browser Helper (Renderer)", cpuSeconds: 32),
        ]
        let groups = ProcessRollup.groups(
            previous: keyed(before), current: after, interval: 2, metric: .cpu)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "Browser", "the row is named for the ancestor")
        XCTAssertEqual(groups.first?.processCount, 3)
        // 0.5 + 1 + 2 seconds of CPU over a 2 s interval = 1.75 cores.
        XCTAssertEqual(groups.first?.cpuCores ?? 0, 1.75, accuracy: 0.0001)
        XCTAssertEqual(groups.first?.cpuPercent ?? 0, 175, accuracy: 0.01)
    }

    func testDaemonsUnderLaunchdStandAlone() {
        // ppid 1 is launchd, which is not a process anybody wants every daemon
        // on the machine rolled into.
        let listing = [process(100, name: "daemonA"), process(200, name: "daemonB")]
        let groups = ProcessRollup.groups(
            previous: keyed(listing), current: listing, interval: 2, metric: .memory)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.processCount), [1, 1])
    }

    func testAnAbsentParentLeavesTheChildAsItsOwnGroup() {
        // The parent exited between ticks; the child must not vanish from the
        // table just because its ancestor is gone.
        let listing = [process(300, parent: 999, name: "orphan")]
        let groups = ProcessRollup.groups(
            previous: keyed(listing), current: listing, interval: 2, metric: .cpu)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "orphan")
    }

    func testAChainWithNoAppAncestorStaysAsSeparateRows() {
        // A shell that spawned a build that spawned a compiler is not one "app".
        // Rolling to the topmost ancestor merged 73 such processes into a single
        // row named after a session daemon on a real dev machine.
        let listing = [
            process(100, name: "zsh"),
            process(200, parent: 100, name: "swift-build"),
            process(300, parent: 200, name: "swift-frontend"),
            process(400, parent: 300, name: "clang"),
        ]
        let groups = ProcessRollup.groups(
            previous: keyed(listing), current: listing, interval: 2, metric: .memory)
        XCTAssertEqual(groups.count, 4)
        XCTAssertTrue(groups.allSatisfy { $0.processCount == 1 })
    }

    func testAnAppLaunchedByAnotherAppStaysItsOwnRow() {
        // Nearest-app, not topmost-app: a terminal launching an editor must not
        // absorb the editor's cost.
        let listing = [
            process(100, name: "Terminal", isApp: true),
            process(200, parent: 100, name: "Editor", isApp: true),
            process(300, parent: 200, name: "Editor Helper"),
        ]
        let groups = ProcessRollup.groups(
            previous: keyed(listing), current: listing, interval: 2, metric: .memory)
        XCTAssertEqual(groups.count, 2)
        let editor = groups.first { $0.name == "Editor" }
        XCTAssertEqual(editor?.processCount, 2, "the helper belongs to the editor")
        XCTAssertEqual(groups.first { $0.name == "Terminal" }?.processCount, 1)
    }

    func testAHelperWhoseAppExitedStandsAlone() {
        let listing = [process(300, parent: 999, name: "orphan helper")]
        let groups = ProcessRollup.groups(
            previous: keyed(listing), current: listing, interval: 2, metric: .cpu)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "orphan helper")
    }

    func testAParentCycleTerminates() {
        // The kernel cannot really produce this, but the walk runs over every
        // process on the machine every tick and must not be the thing that hangs.
        let listing = [
            process(100, parent: 200, name: "a"),
            process(200, parent: 100, name: "b"),
        ]  // neither is an app, so the walk must bottom out on the depth cap
        let groups = ProcessRollup.groups(
            previous: keyed(listing), current: listing, interval: 2, metric: .cpu)
        XCTAssertFalse(groups.isEmpty)
        XCTAssertLessThanOrEqual(groups.count, 2)
    }

    // MARK: - Rates

    func testCPUIsCoresWorthOfTimeNotAPercentageOfTheMachine() {
        // One second of CPU over two seconds is half a core: 50% in Activity
        // Monitor's column, whatever the core count is.
        let before = [process(100, cpuSeconds: 4)]
        let after = [process(100, cpuSeconds: 5)]
        let groups = ProcessRollup.groups(
            previous: keyed(before), current: after, interval: 2, metric: .cpu)
        XCTAssertEqual(groups.first?.cpuCores ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(groups.first?.cpuPercent ?? 0, 50, accuracy: 0.01)
    }

    func testDiskAndWakeupsBecomeRates() {
        let before = [process(100, diskBytes: 1_000, wakeups: 40)]
        let after = [process(100, diskBytes: 5_000, wakeups: 140)]
        let groups = ProcessRollup.groups(
            previous: keyed(before), current: after, interval: 2, metric: .disk)
        XCTAssertEqual(groups.first?.diskBytesPerSec ?? 0, 2_000, accuracy: 0.01)
        XCTAssertEqual(groups.first?.wakeupsPerSec ?? 0, 50, accuracy: 0.01)
    }

    func testAProcessSeenForTheFirstTimeReportsMemoryButNoRate() {
        // Its counters are lifetime totals. Dividing an hour of accumulated CPU
        // by one interval would report a mostly-idle process as pinning cores.
        let after = [process(100, cpuSeconds: 3_600, footprint: 42_000_000, diskBytes: 10 << 30)]
        let groups = ProcessRollup.groups(
            previous: [:], current: after, interval: 2, metric: .cpu)
        XCTAssertEqual(groups.first?.cpuCores, 0)
        XCTAssertEqual(groups.first?.diskBytesPerSec, 0)
        XCTAssertEqual(groups.first?.footprint, 42_000_000)
    }

    func testARecycledPidIsTreatedAsANewProcess() {
        // Same pid, different launch time: differencing the two would credit the
        // newcomer with the dead process's lifetime.
        let before = [process(100, cpuSeconds: 500, startedAt: 100)]
        let after = [process(100, cpuSeconds: 1, startedAt: 900)]
        let groups = ProcessRollup.groups(
            previous: keyed(before), current: after, interval: 2, metric: .cpu)
        XCTAssertEqual(groups.first?.cpuCores, 0)
    }

    func testACounterThatWentBackwardsIsNotAPhantomSpike() {
        let before = [process(100, cpuSeconds: 50)]
        let after = [process(100, cpuSeconds: 40)]
        let groups = ProcessRollup.groups(
            previous: keyed(before), current: after, interval: 2, metric: .cpu)
        XCTAssertEqual(groups.first?.cpuCores, 0)
    }

    func testAZeroIntervalYieldsNothingRatherThanInfinity() {
        let listing = [process(100, cpuSeconds: 5)]
        XCTAssertTrue(
            ProcessRollup.groups(previous: keyed(listing), current: listing, interval: 0, metric: .cpu)
                .isEmpty)
    }

    // MARK: - Ranking

    func testEachMetricRanksByItsOwnColumn() {
        let before = [
            process(100, name: "cpuHog", cpuSeconds: 0),
            process(200, name: "memHog", footprint: 8 << 30),
            process(300, name: "diskHog", diskBytes: 0),
        ]
        let after = [
            process(100, name: "cpuHog", cpuSeconds: 4),
            process(200, name: "memHog", footprint: 8 << 30),
            process(300, name: "diskHog", diskBytes: 100 << 20),
        ]
        func topName(_ metric: ProcessMetric) -> String? {
            ProcessRollup.groups(
                previous: keyed(before), current: after, interval: 2, metric: metric
            ).first?.name
        }
        XCTAssertEqual(topName(.cpu), "cpuHog")
        XCTAssertEqual(topName(.memory), "memHog")
        XCTAssertEqual(topName(.disk), "diskHog")
    }

    func testEqualValuesFallBackToNameSoTheTableDoesNotReshuffle() {
        let listing = [
            process(100, name: "zeta"),
            process(200, name: "alpha"),
            process(300, name: "mike"),
        ]
        let groups = ProcessRollup.groups(
            previous: keyed(listing), current: listing, interval: 2, metric: .cpu)
        XCTAssertEqual(groups.map(\.name), ["alpha", "mike", "zeta"])
    }

    // MARK: - Sample totals

    func testTotalsCoverEveryGroupNotJustTheVisibleRows() {
        let all = (1...20).map { index in
            ProcessGroup(
                id: Int32(index), name: "app\(index)", processCount: 2,
                cpuCores: 0.1, footprint: 1_000, diskBytesPerSec: 0, wakeupsPerSec: 0, threads: 3)
        }
        let sample = ProcessSample(allGroups: all, showing: 8, coreCount: 10)

        XCTAssertEqual(sample.groups.count, 8, "only the head is displayed")
        XCTAssertEqual(sample.groupCount, 20)
        XCTAssertEqual(sample.hiddenGroupCount, 12)
        XCTAssertEqual(sample.processCount, 40, "totals must describe the machine")
        XCTAssertEqual(sample.threadCount, 60)
        XCTAssertEqual(sample.busyCores, 2.0, accuracy: 0.0001)
        XCTAssertEqual(sample.busyFraction, 0.2, accuracy: 0.0001)
    }

    func testBusyFractionIsClampedAndSurvivesAZeroCoreCount() {
        let hot = ProcessGroup(
            id: 1, name: "hot", processCount: 1, cpuCores: 99,
            footprint: 0, diskBytesPerSec: 0, wakeupsPerSec: 0, threads: 1)
        XCTAssertEqual(ProcessSample(allGroups: [hot], showing: 8, coreCount: 4).busyFraction, 1)
        XCTAssertEqual(ProcessSample(allGroups: [hot], showing: 8, coreCount: 0).busyFraction, 0)
    }

    // MARK: - Labels

    func testMetricLabelsReadTheWayTheColumnPromises() {
        let group = ProcessGroup(
            id: 1, name: "app", processCount: 1, cpuCores: 1.234,
            footprint: 2_500_000_000, diskBytesPerSec: 1_500_000, wakeupsPerSec: 42.6, threads: 9)
        XCTAssertEqual(ProcessMetric.cpu.label(for: group), "123.4%")
        XCTAssertEqual(ProcessMetric.memory.label(for: group), "2.5 GB")
        XCTAssertEqual(ProcessMetric.disk.label(for: group), "1.5 MB/s")
        XCTAssertEqual(ProcessMetric.wakeups.label(for: group), "43/s")
    }

    // MARK: - Readable names

    func testTheLastPathComponentIsTheNameInTheUsualCase() {
        XCTAssertEqual(
            ExecutableName.readable(fromPath: "/Applications/Zen.app/Contents/MacOS/Zen"), "Zen")
        XCTAssertEqual(ExecutableName.readable(fromPath: "/usr/libexec/rapportd"), "rapportd")
        XCTAssertEqual(ExecutableName.readable(fromPath: "/bin/zsh"), "zsh")
    }

    func testAnExecutableNamedAfterItsVersionFallsBackToTheProgramName() {
        // Measured: Claude Code installs its binary as the version number, so the
        // last component names nothing a person could act on.
        XCTAssertEqual(
            ExecutableName.readable(fromPath: "/Users/x/.local/share/claude/versions/2.1.251"),
            "claude")
        XCTAssertEqual(
            ExecutableName.readable(fromPath: "/opt/tool/dist/bin/3.12.0"), "tool")
    }

    func testAVersionPathWithNothingButContainersKeepsTheVersion() {
        // Nothing better to say than the version itself; do not return an empty
        // row label.
        XCTAssertEqual(ExecutableName.readable(fromPath: "/bin/versions/2.1"), "2.1")
    }

    func testEmptyAndRootPathsYieldNoName() {
        XCTAssertNil(ExecutableName.readable(fromPath: ""))
        XCTAssertNil(ExecutableName.readable(fromPath: "/"))
    }

    func testVersionDetection() {
        XCTAssertTrue(ExecutableName.isVersionLike("2.1.251"))
        XCTAssertTrue(ExecutableName.isVersionLike("17"))
        XCTAssertFalse(ExecutableName.isVersionLike("claude"))
        XCTAssertFalse(ExecutableName.isVersionLike("v2.1"))
        XCTAssertFalse(ExecutableName.isVersionLike(""))
    }

    // MARK: - The real process table

    func testTheLibprocListerSeesThisTestProcess() {
        // Read-only: enumerating the process table changes nothing. This is the
        // one test that proves the syscall layer works, since every test above
        // runs on synthetic listings.
        let listing = LibprocProcessLister().list()
        XCTAssertGreaterThan(listing.count, 10, "a live Mac runs more than ten processes")

        let me = listing.first { $0.pid == ProcessInfo.processInfo.processIdentifier }
        guard let me else { return XCTFail("the lister did not find the test process itself") }
        XCTAssertGreaterThan(me.footprint, 0)
        XCTAssertGreaterThan(me.threads, 0)
        XCTAssertGreaterThan(me.cpuSeconds, 0)
        XCTAssertLessThan(
            me.cpuSeconds, 60 * 60 * 24,
            "a plausible CPU total, not raw mach ticks read as seconds")
        XCTAssertGreaterThan(me.startedAt, 0)
        XCTAssertGreaterThan(me.parentPid, 0)
    }

    func testTwoRealListingsProduceRatesInsideThePhysicalLimits() {
        let lister = LibprocProcessLister()
        let first = lister.list()
        let interval = 0.25
        Thread.sleep(forTimeInterval: interval)
        let second = lister.list()

        let cores = ProcessInfo.processInfo.activeProcessorCount
        let sample = ProcessSample(
            allGroups: ProcessRollup.groups(
                previous: Dictionary(first.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a }),
                current: second, interval: interval, metric: .cpu),
            showing: 8, coreCount: cores)

        XCTAssertFalse(sample.groups.isEmpty)
        // A machine cannot spend more CPU than it has cores, plus slack for
        // sampling skew between the two passes over the table.
        XCTAssertLessThan(
            sample.busyCores, Double(cores) * 2,
            "attributed CPU (\(sample.busyCores)) exceeds what \(cores) cores can produce")
        XCTAssertTrue(sample.groups.allSatisfy { $0.cpuCores >= 0 })
        XCTAssertTrue(sample.groups.allSatisfy { !$0.name.isEmpty })
    }
}
