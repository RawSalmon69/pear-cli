import Foundation

/// Real stats via `pear status --json`. Soft-fails to `cliMissing` so the
/// panel can show a setup hint instead of empty tiles.
@MainActor
final class PearStatsService: StatsService, ObservableObject {
    @Published private(set) var items: [StatItem] = []
    @Published private(set) var cliMissing = false
    /// Root-disk used fraction; drives the mascot's worried mood.
    @Published private(set) var diskUsedFraction: Double?

    private nonisolated static let candidates = [
        "/usr/local/bin/pear",
        "/opt/homebrew/bin/pear",
    ]

    nonisolated static func pearBinary() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func current() -> [StatItem] { items }

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

    let disks: [Disk]?
    let memory: Memory?
    let batteries: [Battery]?
}
