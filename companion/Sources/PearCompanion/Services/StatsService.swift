import Foundation

struct StatItem: Equatable, Sendable {
    let label: String
    let value: String
    let symbol: String
    /// 0...1 for ring gauges; nil when a ratio makes no sense.
    let fraction: Double?
}

/// System health numbers. The real implementation shells out to
/// `pear status --json`; the mock returns fixtures.
@MainActor
protocol StatsService: AnyObject {
    func current() -> [StatItem]
    func refresh() async
}

@MainActor
final class MockStatsService: StatsService {
    func current() -> [StatItem] {
        [
            StatItem(label: "Disk", value: "234 GB", symbol: "internaldrive", fraction: 0.55),
            StatItem(label: "Memory", value: "12/32 GB", symbol: "memorychip", fraction: 0.38),
            StatItem(label: "Battery", value: "86%", symbol: "battery.75percent", fraction: 0.86),
        ]
    }

    func refresh() async {}
}
