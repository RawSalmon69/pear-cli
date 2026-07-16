import Foundation
import Observation

struct StatItem: Equatable, Sendable {
    let label: String
    let value: String
    let symbol: String
    /// 0...1 for ring gauges; nil when a ratio makes no sense.
    let fraction: Double?
}

/// The panel's compact Mac tiles, fed by the same native samplers the
/// Monitor tool uses (Tools/Monitor) — no CLI dependency, always live.
@MainActor
@Observable
final class PearStatsService {
    private(set) var items: [StatItem] = []
    private(set) var cliMissing = false
    /// Root-disk used fraction; drives the mascot's worried mood.
    private(set) var diskUsedFraction: Double?
    /// Secondary glanceable line.
    private(set) var uptime: String?
    private(set) var healthScore: Int?
    private(set) var healthMessage: String?

    // The pear CLI location is still needed by the disk bars view and the
    // cleaner runner, so the lookup stays here.
    private nonisolated static let candidates = [
        "/usr/local/bin/pear",
        "/opt/homebrew/bin/pear",
    ]

    /// The copy build.sh ships inside the app (Contents/Resources/pear-cli) —
    /// the fallback that keeps Clean/Optimize and the disk bars working on a
    /// Mac with no installed pear. Absent in `swift run`/tests, where only the
    /// installed candidates apply.
    private nonisolated static var bundled: String? {
        Bundle.main.resourceURL?.appendingPathComponent("pear-cli/pear").path
    }

    nonisolated static func pearBinary() -> String? {
        pearBinary(isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// Installed copies win — `pe update` keeps them fresher than the app —
    /// and the bundled copy backstops. Predicate-injectable so the order is
    /// unit-testable without touching the filesystem.
    nonisolated static func pearBinary(isExecutable: (String) -> Bool) -> String? {
        (candidates + [bundled].compactMap { $0 }).first(where: isExecutable)
    }

    func refresh() async {
        // CPU needs two tick samples; the gap runs while everything else
        // is gathered, so refresh still feels instant.
        let firstTicks = CPUSampler.readTicks()
        try? await Task.sleep(for: .milliseconds(500))
        let secondTicks = CPUSampler.readTicks()

        var next: [StatItem] = []

        if let disk = Self.rootDiskUsage() {
            diskUsedFraction = disk.usedFraction
            next.append(
                StatItem(
                    label: "Disk free",
                    value: Self.gigabytes(disk.free),
                    symbol: "internaldrive",
                    fraction: disk.usedFraction
                )
            )
        }
        if let memory = MemorySampler.sample(), memory.total > 0 {
            let fraction = Double(memory.used) / Double(memory.total)
            next.append(
                StatItem(
                    label: "Memory",
                    value: "\(Int((fraction * 100).rounded()))%",
                    symbol: "memorychip",
                    fraction: fraction
                )
            )
        }
        if let firstTicks, let secondTicks {
            let usages = CPUUsage.coreUsages(previous: firstTicks, current: secondTicks)
            if !usages.isEmpty {
                let total = usages.reduce(0, +) / Double(usages.count)
                next.append(
                    StatItem(
                        label: "CPU",
                        value: "\(Int((total * 100).rounded()))%",
                        symbol: "cpu",
                        fraction: min(max(total, 0), 1)
                    )
                )
            }
        }
        if let battery = BatterySampler.sample(), let percent = battery.percent {
            next.append(
                StatItem(
                    label: battery.isCharging ? "Charging" : "Battery",
                    value: "\(percent)%",
                    symbol: batterySymbol(percent, charging: battery.isCharging),
                    fraction: Double(percent) / 100
                )
            )
        }

        items = next
        uptime = Self.uptimeString(ProcessInfo.processInfo.systemUptime)
    }

    // MARK: - Native readings

    private static func rootDiskUsage() -> (free: Int64, usedFraction: Double)? {
        let url = URL(fileURLWithPath: "/")
        guard
            let values = try? url.resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ]),
            let total = values.volumeTotalCapacity, total > 0,
            let free = values.volumeAvailableCapacityForImportantUsage, free >= 0
        else {
            return nil
        }
        let used = Int64(total) - free
        return (free, Double(used) / Double(total))
    }

    private static func uptimeString(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.0f GB", Double(bytes) / 1_000_000_000)
    }

    private func batterySymbol(_ percent: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<20: return "battery.25percent"
        case ..<60: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
