import Foundation
import Observation

struct StatItem: Equatable, Sendable {
    let label: String
    let value: String
    let symbol: String
    /// 0...1 for ring gauges; nil when a ratio makes no sense.
    let fraction: Double?
}

/// Real stats via `pear status --json`. Soft-fails to `cliMissing` so the
/// panel can show a setup hint instead of empty tiles.
@MainActor
@Observable
final class PearStatsService {
    private(set) var items: [StatItem] = []
    private(set) var cliMissing = false
    /// Root-disk used fraction; drives the mascot's worried mood.
    private(set) var diskUsedFraction: Double?
    /// Secondary glanceable line: uptime + overall health.
    private(set) var uptime: String?
    private(set) var healthScore: Int?
    private(set) var healthMessage: String?

    private nonisolated static let candidates = [
        "/usr/local/bin/pear",
        "/opt/homebrew/bin/pear",
    ]

    nonisolated static func pearBinary() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refresh() async {
        guard let binary = Self.pearBinary() else {
            cliMissing = true
            return
        }
        cliMissing = false

        let data: Data? = await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["status", "--json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return nil
            }
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? output : nil
        }.value

        guard let data, let snapshot = try? JSONDecoder().decode(StatusSnapshot.self, from: data) else {
            return
        }
        apply(snapshot)
    }

    private func apply(_ s: StatusSnapshot) {
        var next: [StatItem] = []

        if let disk = s.disks?.first(where: { $0.mount == "/" }) {
            let freeBytes = disk.total - disk.used
            let fraction = disk.usedPercent / 100
            diskUsedFraction = fraction
            next.append(
                StatItem(
                    label: "Disk free",
                    value: Self.gigabytes(freeBytes),
                    symbol: "internaldrive",
                    fraction: fraction
                )
            )
        }
        if let mem = s.memory {
            next.append(
                StatItem(
                    label: "Memory",
                    value: "\(Int(mem.usedPercent.rounded()))%",
                    symbol: "memorychip",
                    fraction: mem.usedPercent / 100
                )
            )
        }
        if let cpu = s.cpu {
            next.append(
                StatItem(
                    label: "CPU",
                    value: "\(Int(cpu.usage.rounded()))%",
                    symbol: "cpu",
                    fraction: min(max(cpu.usage / 100, 0), 1)
                )
            )
        }
        if let battery = s.batteries?.first {
            next.append(
                StatItem(
                    label: battery.status == "charging" ? "Charging" : "Battery",
                    value: "\(battery.percent)%",
                    symbol: batterySymbol(battery.percent, charging: battery.status == "charging"),
                    fraction: Double(battery.percent) / 100
                )
            )
        }
        items = next
        uptime = s.uptime
        healthScore = s.healthScore
        healthMessage = s.healthScoreMsg
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

// Decodes just the slice of `pear status --json` the tiles need.
struct StatusSnapshot: Decodable {
    struct Disk: Decodable {
        let mount: String
        let used: Int64
        let total: Int64
        let usedPercent: Double

        enum CodingKeys: String, CodingKey {
            case mount, used, total
            case usedPercent = "used_percent"
        }
    }

    struct Memory: Decodable {
        let usedPercent: Double

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
        }
    }

    struct Battery: Decodable {
        let percent: Int
        let status: String
    }

    struct CPU: Decodable {
        let usage: Double
    }

    let disks: [Disk]?
    let memory: Memory?
    let batteries: [Battery]?
    let cpu: CPU?
    let uptime: String?
    let healthScore: Int?
    let healthScoreMsg: String?

    enum CodingKeys: String, CodingKey {
        case disks, memory, batteries, cpu, uptime
        case healthScore = "health_score"
        case healthScoreMsg = "health_score_msg"
    }
}
