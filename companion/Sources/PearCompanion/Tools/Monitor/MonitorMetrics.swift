import Foundation

// Value snapshots and pure logic for the Monitor tool. Everything here is a
// `Sendable` value type or a pure function so the samplers (which run off the
// main actor) can hand results back to `@MainActor MonitorModel` without any
// shared mutable state, and so the math is unit-testable without hardware.

/// One CPU core's fraction of busy time over the last sampling interval.
struct CoreLoad: Sendable, Identifiable {
    let id: Int
    /// 0…1 busy fraction (user + system + nice) / total ticks.
    let usage: Double
}

/// Per-core CPU load plus the whole-package average.
struct CPUSample: Sendable {
    let cores: [CoreLoad]
    /// Average busy fraction across all cores, 0…1.
    let total: Double
}

/// A breakdown of physical memory. `used` already includes `wired` and
/// `compressed`; `app = used - wired - compressed`.
struct MemorySample: Sendable {
    let total: UInt64
    let used: UInt64
    let wired: UInt64
    let compressed: UInt64
    let free: UInt64
}

/// Instantaneous network throughput for the busiest primary interface(s).
struct NetworkSample: Sendable {
    let downBytesPerSec: Double
    let upBytesPerSec: Double
    let interfaceName: String?
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

/// One SMC reading, already scaled to its unit.
struct SensorReading: Sendable, Identifiable {
    let id: String
    let label: String
    let value: Double
    let unit: SensorUnit
}

enum SensorUnit: Sendable {
    case celsius
    case rpm
}

/// Temperatures and fan speeds read from the SMC. Either list may be empty;
/// the whole sample is `nil` when the SMC never opened or nothing responded.
struct SensorSample: Sendable {
    let temperatures: [SensorReading]
    let fans: [SensorReading]
}

/// One tick's worth of everything. Any field may be `nil` — each sampler
/// soft-fails independently ("every tool fails alone"), and the view renders
/// only the sections that carry data.
struct MonitorSnapshot: Sendable {
    var cpu: CPUSample?
    var memory: MemorySample?
    var network: NetworkSample?
    var battery: BatterySample?
    var sensors: SensorSample?

    /// True until at least one section has data — used for the initial
    /// "Sampling…" placeholder.
    var isEmpty: Bool {
        cpu == nil && memory == nil && network == nil && battery == nil && sensors == nil
    }
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

// MARK: - Human formatting

enum MonitorFormat {
    /// Byte rate as B/s, KB/s, MB/s, or GB/s (SI 1000 steps, matching the
    /// panel's `ByteFormat`). Negatives clamp to zero.
    static func rate(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        if v < 1000 { return String(format: "%.0f B/s", v) }
        let kb = v / 1000
        if kb < 1000 { return String(format: "%.1f KB/s", kb) }
        let mb = kb / 1000
        if mb < 1000 { return String(format: "%.1f MB/s", mb) }
        return String(format: "%.1f GB/s", mb / 1000)
    }

    /// Memory size in binary GB, one decimal.
    static func gib(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    /// A 0…1 fraction as a whole percent.
    static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
    }

    /// Minutes as `H:MM`.
    static func duration(minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return String(format: "%d:%02d", h, m)
    }
}
