import Foundation

// Per-process attribution: the "who is eating this machine" half of the Monitor.
// Everything here is a Sendable value type or a pure function, so the sampler can
// run off the main actor and the rollup math is testable without a single syscall.

/// One process as the kernel reported it this tick. Every counter is absolute
/// and monotonic since the process launched; rates come from differencing two
/// ticks in `ProcessRollup`.
struct RawProcess: Sendable, Equatable {
    let pid: Int32
    let parentPid: Int32
    let name: String
    /// CPU time consumed since launch, user + system.
    let cpuSeconds: Double
    /// `phys_footprint` where readable, resident size otherwise. This is the
    /// number Activity Monitor shows, not `ps` RSS.
    let footprint: UInt64
    /// Disk bytes read + written since launch.
    let diskBytes: UInt64
    /// Idle + interrupt wakeups since launch. High rates keep the CPU from
    /// staying in its low-power states, which is why a process can drain a
    /// battery while showing almost no CPU.
    let wakeups: UInt64
    let threads: Int
    /// Launch timestamp, the only way to tell a recycled pid from the process
    /// that held it a moment ago.
    let startedAt: UInt64
    /// Whether this pid is a registered application rather than a plain child
    /// process. This is what rollup groups on: an app is a thing a person
    /// recognises and can act on, a helper is not.
    let isApp: Bool
}

/// One app's worth of processes, summed. Helpers are rolled into the app that
/// spawned them, which is the entire point: a browser's cost is the sum of its
/// dozen renderers, not whichever single one happens to rank.
struct ProcessGroup: Sendable, Identifiable {
    /// The ancestor process's pid.
    let id: Int32
    let name: String
    let processCount: Int
    /// Cores' worth of CPU consumed over the interval: 1.0 means one core fully
    /// busy, so 2.4 means this app kept two and a half cores occupied. Activity
    /// Monitor's percentage is this times 100.
    let cpuCores: Double
    let footprint: UInt64
    let diskBytesPerSec: Double
    let wakeupsPerSec: Double
    let threads: Int

    /// Activity Monitor's "% CPU" column, where one saturated core reads 100.
    var cpuPercent: Double { cpuCores * 100 }
}

/// What the table is ranked by. Each metric knows how to pull and format its own
/// value, so the card has no per-metric switch of its own.
enum ProcessMetric: String, CaseIterable, Identifiable, Sendable {
    case cpu, memory, disk, wakeups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .wakeups: return "Wakeups"
        }
    }

    /// The scalar this metric ranks by. Comparable across groups, not meant for
    /// display — `label(for:)` does that.
    func value(_ group: ProcessGroup) -> Double {
        switch self {
        case .cpu: return group.cpuCores
        case .memory: return Double(group.footprint)
        case .disk: return group.diskBytesPerSec
        case .wakeups: return group.wakeupsPerSec
        }
    }

    func label(for group: ProcessGroup) -> String {
        switch self {
        case .cpu: return String(format: "%.1f%%", group.cpuPercent)
        case .memory: return ByteFormat.si(Int64(group.footprint))
        case .disk: return "\(ByteFormat.si(Int64(max(0, group.diskBytesPerSec))))/s"
        case .wakeups: return String(format: "%.0f/s", group.wakeupsPerSec)
        }
    }
}

/// Turns two consecutive process listings into per-app rollups.
enum ProcessRollup {
    /// Depth cap on the walk to a top-level ancestor. Parent pids come from the
    /// kernel and cannot really form a cycle, but a cap costs nothing and this
    /// runs over every process on the machine every tick.
    static let maxAncestorDepth = 16

    /// The rolled-up groups for this tick, ranked by `metric`, longest first.
    ///
    /// A process with no entry in `previous` — just launched, or the previous
    /// tick could not read it — contributes its memory but a zero rate: its
    /// counters are lifetime totals, and dividing those by one interval would
    /// report a process that used 4 s of CPU over an hour as having pinned two
    /// cores. A pid whose `startedAt` moved is a different process reusing the
    /// number and is treated as new for the same reason.
    static func groups(
        previous: [Int32: RawProcess],
        current: [RawProcess],
        interval: Double,
        metric: ProcessMetric
    ) -> [ProcessGroup] {
        guard interval > 0 else { return [] }
        let byPid = Dictionary(current.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        var accumulated: [Int32: ProcessGroup] = [:]
        for process in current {
            let rootPid = ancestor(of: process, in: byPid)
            let root = byPid[rootPid] ?? process
            let prior = previous[process.pid]
            let sameProcess = prior?.startedAt == process.startedAt
            let cpu = sameProcess ? max(0, process.cpuSeconds - (prior?.cpuSeconds ?? 0)) / interval : 0
            let disk = sameProcess ? Double(process.diskBytes &- (prior?.diskBytes ?? 0)) / interval : 0
            let wake = sameProcess ? Double(process.wakeups &- (prior?.wakeups ?? 0)) / interval : 0

            if let existing = accumulated[rootPid] {
                accumulated[rootPid] = ProcessGroup(
                    id: rootPid,
                    name: existing.name,
                    processCount: existing.processCount + 1,
                    cpuCores: existing.cpuCores + cpu,
                    footprint: existing.footprint + process.footprint,
                    diskBytesPerSec: existing.diskBytesPerSec + disk,
                    wakeupsPerSec: existing.wakeupsPerSec + wake,
                    threads: existing.threads + process.threads)
            } else {
                accumulated[rootPid] = ProcessGroup(
                    id: rootPid,
                    name: root.name,
                    processCount: 1,
                    cpuCores: cpu,
                    footprint: process.footprint,
                    diskBytesPerSec: disk,
                    wakeupsPerSec: wake,
                    threads: process.threads)
            }
        }

        return accumulated.values.sorted {
            let left = metric.value($0)
            let right = metric.value($1)
            // Name as the tiebreak, so a table of mostly-idle processes does not
            // reshuffle every tick on equal zeroes.
            return left == right ? $0.name < $1.name : left > right
        }
    }

    /// The nearest ancestor that is an *application*, or the process itself.
    ///
    /// Walking to the topmost ancestor instead — the obvious implementation —
    /// merges everything a terminal ever spawned into one row: a measured run on
    /// a dev machine rolled 73 unrelated processes (a test runner, two language
    /// servers, node, a shell) into a single group named after a session daemon.
    /// Stopping at the nearest app keeps browser helpers on their browser, keeps
    /// two GUI apps separate even when one launched the other, and leaves
    /// daemons and command-line tools standing alone, which is where a person
    /// can actually act on them.
    static func ancestor(of process: RawProcess, in byPid: [Int32: RawProcess]) -> Int32 {
        if process.isApp { return process.pid }
        var current = process
        var depth = 0
        while depth < maxAncestorDepth {
            let parentPid = current.parentPid
            guard parentPid > 1, let parent = byPid[parentPid], parent.pid != current.pid else {
                return process.pid
            }
            if parent.isApp { return parent.pid }
            current = parent
            depth += 1
        }
        return process.pid
    }
}

/// One tick of process attribution, plus the totals the card's footer states so
/// the summary and the rows can never disagree.
struct ProcessSample: Sendable {
    /// The ranked head of the table, already truncated for display.
    let groups: [ProcessGroup]
    /// Totals over *every* group, including the ones truncated away, so the
    /// footer describes the machine rather than the visible rows.
    let busyCores: Double
    let processCount: Int
    let threadCount: Int
    let groupCount: Int
    let coreCount: Int

    /// 0…1 of the whole machine.
    var busyFraction: Double {
        coreCount > 0 ? min(1, busyCores / Double(coreCount)) : 0
    }

    /// How many apps rank below the visible rows.
    var hiddenGroupCount: Int { max(0, groupCount - groups.count) }

    /// Ranked head plus totals. Truncation happens here so no caller can pass
    /// truncated rows and full totals that disagree.
    init(allGroups: [ProcessGroup], showing limit: Int, coreCount: Int) {
        self.groups = Array(allGroups.prefix(limit))
        self.busyCores = allGroups.reduce(0) { $0 + $1.cpuCores }
        self.processCount = allGroups.reduce(0) { $0 + $1.processCount }
        self.threadCount = allGroups.reduce(0) { $0 + $1.threads }
        self.groupCount = allGroups.count
        self.coreCount = coreCount
    }
}
