import Darwin

// Physical-memory breakdown from the Mach VM statistics. One-shot and
// absolute (no deltas), so it renders on the very first tick.
//
// Adapted from Stats (MIT) — `Modules/RAM/readers.swift` `UsageReader`.
enum MemorySampler {
    // mach_host_self() adds a host-port send right on every call; caching a
    // single right for the process lifetime avoids leaking one per sample tick.
    private static let hostPort: mach_port_t = mach_host_self()

    static func sample() -> MemorySample? {
        guard let total = totalMemory() else { return nil }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        // `vm_page_size` is a mutable C global (not concurrency-safe); query the
        // page size through the host port instead.
        var pageSize: vm_size_t = 0
        guard host_page_size(hostPort, &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return nil
        }
        let page = UInt64(pageSize)
        let active = UInt64(stats.active_count) * page
        let inactive = UInt64(stats.inactive_count) * page
        let speculative = UInt64(stats.speculative_count) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let purgeable = UInt64(stats.purgeable_count) * page
        let external = UInt64(stats.external_page_count) * page

        // Same formula Activity Monitor / Stats use for "used".
        let gross = active + inactive + speculative + wired + compressed
        let reclaimable = purgeable + external
        let used = gross > reclaimable ? gross - reclaimable : 0
        let free = total > used ? total - used : 0

        return MemorySample(
            total: total, used: used, wired: wired, compressed: compressed, free: free)
    }

    private static func totalMemory() -> UInt64? {
        var info = host_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_info(hostPort, HOST_BASIC_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, info.max_mem > 0 else { return nil }
        return UInt64(info.max_mem)
    }
}
