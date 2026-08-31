import Foundation

// The small native samplers that outlived the Monitor tool. They feed the
// panel's greeting line (disk pressure, health message) and RunCat's animation
// speed, so they are infrastructure rather than part of the removed monitoring
// UI. Everything here is a value type or a pure function.

/// A breakdown of physical memory. `used` already includes `wired` and
/// `compressed`; `app = used - wired - compressed`.
struct MemorySample: Sendable {
    let total: UInt64
    let used: UInt64
    let wired: UInt64
    let compressed: UInt64
    let free: UInt64

    /// Used as a 0…1 fraction of physical memory — the single scalar the memory
    /// history line tracks over time.
    var usedFraction: Double {
        total > 0 ? min(1, Double(used) / Double(total)) : 0
    }
}

/// Battery detail. Present only on machines that have an internal battery;
/// desktops yield `nil` and the section is hidden.
struct BatterySample: Sendable {
    let percent: Int?
    let cycleCount: Int?
    /// maxCapacity / designCapacity, as a whole percent.
    let healthPercent: Int?
    let isCharging: Bool
    /// Minutes to full (charging) or to empty (discharging); nil while the
    /// estimate is still settling.
    let timeRemainingMinutes: Int?
    let chargingWatts: Double?
}

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

