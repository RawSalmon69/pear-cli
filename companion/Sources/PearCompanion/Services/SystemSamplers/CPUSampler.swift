import Darwin

// Reads raw per-core CPU tick counters. Stateless: it copies the counters out
// into a plain `[UInt32]` and frees the Mach allocation before returning, so
// no pointer outlives the call and nothing needs to be `Sendable`-audited. The
// caller keeps the previous array and diffs via `CPUUsage.coreUsages`.
//
// Adapted from Stats (MIT) — `Modules/CPU/readers.swift` `LoadReader.read()`.
enum CPUSampler {
    // mach_host_self() adds a host-port send right on every call; leaving each
    // one undeallocated leaks a port right per sample tick. Cache a single
    // right for the process lifetime and reuse it. (mach_task_self_ is a global
    // that needs no such handling, so the vm_deallocate below is unchanged.)
    private static let hostPort: mach_port_t = mach_host_self()

    /// A flattened `[core0.user, core0.system, core0.idle, core0.nice, …]`
    /// array (length = cores × 4), or nil if the host call failed.
    static func readTicks() -> [UInt32]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            hostPort, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: UnsafeRawPointer(info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var ticks = [UInt32]()
        ticks.reserveCapacity(Int(infoCount))
        for i in 0..<Int(infoCount) {
            // Counters are declared signed (integer_t) but are really unsigned
            // and monotonic; keep the bit pattern so wrapping diffs stay right.
            ticks.append(UInt32(bitPattern: info[i]))
        }
        return ticks
    }
}
