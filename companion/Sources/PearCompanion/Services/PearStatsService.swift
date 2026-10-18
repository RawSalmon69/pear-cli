import Foundation
import Observation

/// The root disk's used fraction, read once per panel open. It feeds the cat's
/// "disk nearly full" line and nothing else. One synchronous volume query, so
/// the panel opens without waiting on it.
@MainActor
@Observable
final class PearStatsService {
    private(set) var diskUsedFraction: Double?

    func refresh() {
        diskUsedFraction = Self.rootDiskUsedFraction()
    }

    private static func rootDiskUsedFraction() -> Double? {
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
        return Double(Int64(total) - free) / Double(total)
    }
}
