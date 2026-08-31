import AppKit
import Darwin

// The syscall half of process attribution. Public `libproc` only — no private
// framework, no entitlement, no root, nothing spawned. Kept behind a protocol so
// `ProcessRollup`'s math is tested against synthetic listings rather than
// whatever happens to be running on the test machine.

protocol ProcessLister: Sendable {
    /// Every process this user can read, one entry each. Unreadable processes
    /// are skipped rather than reported as zero: a root daemon we cannot see is
    /// absent, not idle.
    func list() -> [RawProcess]
}

/// Reads the process table through `libproc`.
///
/// What is readable without privileges: any process owned by this user answers
/// `proc_pid_rusage`, which carries `phys_footprint` (the Activity Monitor
/// number), lifetime disk bytes and wakeup counts. Other users' processes —
/// root daemons, mostly — refuse it, so they fall back to `PROC_PIDTASKALLINFO`,
/// which still gives CPU time, resident size and thread count. Nothing here can
/// see per-process *network* bytes; that needs the private NetworkStatistics
/// framework, and the aggregate Network card stays the honest answer.
final class LibprocProcessLister: ProcessLister, @unchecked Sendable {
    /// Kernel task times are in mach absolute-time units, not nanoseconds, and
    /// on Apple Silicon the two differ by a factor of ~41.67 (timebase 125/3).
    /// Treating ticks as nanoseconds reported a fully busy core as 2.4% — a
    /// one-second spin measured 0.024 "seconds" before this conversion existed.
    private static let ticksToSeconds: Double = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else {
            return 1e-9
        }
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()

    /// Executable paths never change for the life of a pid, so resolving one is
    /// a per-process cost rather than a per-tick one. Keyed by pid *and* launch
    /// time so a recycled pid cannot inherit the old name. `@unchecked
    /// Sendable`: the cache is only touched from inside `list()`, which the
    /// sampler actor serialises.
    private var nameCache: [Int32: (startedAt: UInt64, name: String)] = [:]

    func list() -> [RawProcess] {
        let pids = allPids()
        guard !pids.isEmpty else { return [] }

        // Registered applications get their localized name (the "Google Chrome"
        // a person recognises) instead of the executable's filename.
        //
        // Being registered is NOT the same as being a top-level app: measured on
        // a real machine, all 46 of a Firefox fork's content processes register
        // themselves, so keying rollup on registration alone gave every renderer
        // its own row. Activation policy is the distinction that holds — on that
        // machine, 9 regular apps, 61 accessory menu-bar agents, and 89
        // prohibited helpers including every one of those content processes.
        // Regular and accessory are things a person recognises and can quit;
        // prohibited processes belong to whichever of those spawned them.
        var appNames: [Int32: String] = [:]
        var rootPids = Set<Int32>()
        for app in NSWorkspace.shared.runningApplications {
            if let name = app.localizedName { appNames[app.processIdentifier] = name }
            if app.activationPolicy == .regular || app.activationPolicy == .accessory {
                rootPids.insert(app.processIdentifier)
            }
        }

        var result: [RawProcess] = []
        result.reserveCapacity(pids.count)
        var liveKeys = Set<Int32>()

        for pid in pids where pid > 0 {
            guard let task = taskAllInfo(pid) else { continue }
            let startedAt = UInt64(task.pbsd.pbi_start_tvsec)
            liveKeys.insert(pid)

            let name = appNames[pid] ?? cachedName(pid, startedAt: startedAt, fallback: task)
            let cpuSeconds =
                Double(task.ptinfo.pti_total_user &+ task.ptinfo.pti_total_system)
                * Self.ticksToSeconds

            var footprint = task.ptinfo.pti_resident_size
            var diskBytes: UInt64 = 0
            var wakeups: UInt64 = 0
            if let usage = rusage(pid) {
                footprint = usage.ri_phys_footprint
                diskBytes = usage.ri_diskio_bytesread &+ usage.ri_diskio_byteswritten
                wakeups = usage.ri_pkg_idle_wkups &+ usage.ri_interrupt_wkups
            }

            result.append(
                RawProcess(
                    pid: pid,
                    parentPid: Int32(bitPattern: task.pbsd.pbi_ppid),
                    name: name,
                    cpuSeconds: cpuSeconds,
                    footprint: footprint,
                    diskBytes: diskBytes,
                    wakeups: wakeups,
                    threads: Int(task.ptinfo.pti_threadnum),
                    startedAt: startedAt,
                    isApp: rootPids.contains(pid)))
        }

        // Drop cache entries for processes that have exited, so a long-open
        // window does not accumulate every name the machine ever ran.
        nameCache = nameCache.filter { liveKeys.contains($0.key) }
        return result
    }

    // MARK: - libproc

    private func allPids() -> [Int32] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        // Ask for headroom: processes can launch between the sizing call and the
        // read, and a full buffer would silently truncate the listing.
        let capacity = Int(bytes) / MemoryLayout<Int32>.size + 64
        var pids = [Int32](repeating: 0, count: capacity)
        let written = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &pids, Int32(capacity * MemoryLayout<Int32>.size))
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written) / MemoryLayout<Int32>.size))
    }

    private func taskAllInfo(_ pid: Int32) -> proc_taskallinfo? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, $0, size)
        }
        return read == size ? info : nil
    }

    /// `rusage_info_v4` is the newest layout every supported macOS answers. A
    /// nil here is the normal answer for another user's process, not an error.
    ///
    /// `rusage_info_t` is `void *`, and the call wants the address *of the
    /// struct* under that type — not the address of a pointer variable holding
    /// it. Passing the latter makes the kernel write the whole struct into an
    /// eight-byte stack slot, which smashes the stack and aborts the process.
    private func rusage(_ pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return read == 0 ? info : nil
    }

    private func cachedName(_ pid: Int32, startedAt: UInt64, fallback task: proc_taskallinfo) -> String {
        if let cached = nameCache[pid], cached.startedAt == startedAt { return cached.name }
        let name = executableName(pid) ?? commName(task)
        nameCache[pid] = (startedAt, name)
        return name
    }

    /// `PROC_PIDPATHINFO_MAXSIZE` is a macro the SDK marks unavailable to Swift;
    /// it is `4 * MAXPATHLEN`, and `proc_pidpath` documents that as the required
    /// buffer size.
    private static let pathBufferSize = 4 * Int(MAXPATHLEN)

    private func executableName(_ pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Self.pathBufferSize)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return ExecutableName.readable(fromPath: path)
    }

    /// `pbi_comm` is the kernel's 16-byte truncated name — the last resort when
    /// the path is unreadable, which is the usual case for root daemons.
    private func commName(_ task: proc_taskallinfo) -> String {
        withUnsafeBytes(of: task.pbsd.pbi_comm) { raw in
            String(decoding: Array(raw.prefix { $0 != 0 }), as: UTF8.self)
        }
    }
}


/// Turns an executable path into the name a person would recognise in a table.
enum ExecutableName {
    /// Path components that name a container rather than a program, skipped when
    /// the executable's own filename turns out to be uninformative.
    static let genericComponents: Set<String> = [
        "versions", "version", "bin", "sbin", "libexec", "current", "contents", "macos",
        "helpers", "resources", "frameworks", "node_modules", "dist", "build",
    ]

    /// ".../Foo.app/Contents/MacOS/Foo" is "Foo", which is the last component and
    /// the usual case. Some programs install their executable *as* a version
    /// number, though — Claude Code lives at ".../claude/versions/2.1.251" — and
    /// a table row reading "2.1.251" names nothing. There, walk back to the first
    /// component that is neither a version nor a container word.
    static func readable(fromPath path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard let last = components.last, !last.isEmpty else { return nil }
        if !isVersionLike(last) { return last }
        for component in components.reversed() {
            guard !isVersionLike(component), !genericComponents.contains(component.lowercased())
            else { continue }
            return component
        }
        return last
    }

    /// "2.1.251", "17", "3.12.0" — digits and dots only.
    static func isVersionLike(_ component: String) -> Bool {
        !component.isEmpty && component.allSatisfy { $0.isNumber || $0 == "." }
    }
}
