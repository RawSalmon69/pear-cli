import Foundation
import Observation

struct StatItem: Equatable, Sendable {
    let label: String
    let value: String
    let symbol: String
    /// 0...1 for ring gauges; nil when a ratio makes no sense.
    let fraction: Double?
}

// MARK: - CLI gate

/// What the app found when it went looking for the `pear` CLI it shells out to.
enum PearCLI: Equatable, Sendable {
    case ready(path: String)
    case notInstalled
    /// Older than `PearStatsService.minimumCLIVersion`. `installed` is nil when
    /// `pear --version` printed nothing we could parse.
    case tooOld(installed: CLIVersion?)
}

/// A `major.minor.patch` CLI version, parsed from `pear --version` and compared
/// against the minimum the app needs. Pure and unit-tested.
struct CLIVersion: Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    /// Reads the CLI's `--version` block — a blank line, then "Pear version
    /// 1.47.0", then channel/OS/kernel/disk lines — by taking the first dotted
    /// numeric token anywhere in it. Output with no such token (an error
    /// message, a bare commit hash) yields nil rather than a made-up version.
    static func parse(_ output: String) -> CLIVersion? {
        for token in output.split(whereSeparator: { !$0.isNumber && $0 != "." }) {
            let parts = token.split(separator: ".")
            guard (2...3).contains(parts.count) else { continue }
            let numbers = parts.compactMap { Int($0) }
            guard numbers.count == parts.count else { continue }
            return CLIVersion(
                major: numbers[0], minor: numbers[1], patch: numbers.count == 3 ? numbers[2] : 0)
        }
        return nil
    }

    static func < (lhs: CLIVersion, rhs: CLIVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

/// The panel's compact Mac tiles, fed by the same native samplers the
/// Monitor tool uses (Tools/Monitor) — no CLI dependency, always live.
@MainActor
@Observable
final class PearStatsService {
    private(set) var items: [StatItem] = []
    /// Root-disk used fraction; drives the mascot's worried mood.
    private(set) var diskUsedFraction: Double?
    /// Secondary glanceable line.
    private(set) var uptime: String?
    private(set) var healthScore: Int?
    private(set) var healthMessage: String?

    // Where an installed `pear` lands: the install script's default prefix
    // first, then a Homebrew one. Pear.app does NOT ship the CLI — the CLI is
    // GPL-3.0 and this app is paid — so these are the only candidates, and a
    // Mac without one degrades to the install-the-CLI state in the UI.
    private nonisolated static let candidates = [
        "/usr/local/bin/pear",
        "/opt/homebrew/bin/pear",
    ]

    /// Oldest installed CLI the app will drive: **1.47.0, the first release that
    /// contains `clean --system`.** The app invokes `clean`, `clean --system`,
    /// `optimize` and `analyze --json`; the released V1.46.0 has everything but
    /// `--system` (that landed on the CLI's main branch after it shipped), so
    /// anything below 1.47.0 breaks the Include-system-caches path halfway
    /// through a run. `resolveCLI()` refuses up front instead.
    nonisolated static let minimumCLIVersion = CLIVersion(major: 1, minor: 47, patch: 0)

    nonisolated static func pearBinary() -> String? {
        pearBinary(isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// First installed `pear` that exists, or nil. Predicate-injectable so the
    /// order is unit-testable without touching the filesystem.
    nonisolated static func pearBinary(isExecutable: (String) -> Bool) -> String? {
        candidates.first(where: isExecutable)
    }

    /// Resolves the CLI *and* checks its version before anything shells out to
    /// it. Because the app no longer carries its own copy, whatever the user
    /// installed is what runs — and an old one silently lacks flags this app
    /// passes (`clean --system` above all). Blocking on purpose: `pear
    /// --version` is a short local script (~0.1s) and every caller is about to
    /// spawn the same binary for minutes anyway.
    nonisolated static func resolveCLI() -> PearCLI {
        let path = pearBinary()
        return cliStatus(path: path, versionOutput: path.flatMap(readVersion))
    }

    /// The pure half of `resolveCLI()`: given a resolved path and whatever
    /// `pear --version` printed, decide whether the app can use it. Split out
    /// so the gate is unit-testable with no process spawn.
    nonisolated static func cliStatus(path: String?, versionOutput: String?) -> PearCLI {
        guard let path else { return .notInstalled }
        guard let version = versionOutput.flatMap(CLIVersion.parse) else {
            // Installed but unreadable version: treat as too old rather than
            // running it blind, and say so without inventing a number.
            return .tooOld(installed: nil)
        }
        return version < minimumCLIVersion ? .tooOld(installed: version) : .ready(path: path)
    }

    private nonisolated static func readVersion(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Same pinned PATH as CleanerRunner, for the same reason: a GUI app's
        // inherited PATH is rewritable with `launchctl setenv`, and this script
        // shells out to csrutil/df/brew.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
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
