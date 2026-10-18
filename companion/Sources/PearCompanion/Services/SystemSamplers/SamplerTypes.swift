import Foundation

// What is left of the native samplers after the Monitor tool was removed: the
// CPU tick math RunCat's animation speed runs on. The panel's memory, battery
// and uptime readings went when the panel stopped showing them.

// MARK: - Pure CPU delta math

/// Turns two consecutive `PROCESSOR_CPU_LOAD_INFO` tick arrays into per-core
/// busy fractions. The array is flattened as
/// `[core0.user, core0.system, core0.idle, core0.nice, core1.user, …]`, the
/// fixed Mach `CPU_STATE` layout (USER=0, SYSTEM=1, IDLE=2, NICE=3). Wrapping
/// subtraction (`&-`) handles the 32-bit counter rolling over.
///
/// Adapted from Stats (MIT) — `Modules/CPU/readers.swift` `LoadReader.read()`.
enum CPUUsage {
    static let stateCount = 4

    static func coreUsages(previous: [UInt32], current: [UInt32]) -> [Double] {
        guard previous.count == current.count,
              current.count >= stateCount,
              current.count % stateCount == 0
        else { return [] }

        let cores = current.count / stateCount
        var result = [Double]()
        result.reserveCapacity(cores)
        for c in 0..<cores {
            let base = c * stateCount
            let user = UInt64(current[base] &- previous[base])
            let system = UInt64(current[base + 1] &- previous[base + 1])
            let idle = UInt64(current[base + 2] &- previous[base + 2])
            let nice = UInt64(current[base + 3] &- previous[base + 3])
            let inUse = user + system + nice
            let total = inUse + idle
            // Clamp: a core going offline between samples can reset its ticks,
            // and a wrapped `&-` delta would otherwise read as a nonsense >100%.
            let fraction = total > 0 ? Double(inUse) / Double(total) : 0
            result.append(min(1, max(0, fraction)))
        }
        return result
    }
}

