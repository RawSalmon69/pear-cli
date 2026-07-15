import Foundation
import IOKit
import IOKit.ps

// Battery detail from the IOKit power-source APIs plus the AppleSmartBattery
// registry entry. Returns nil on machines with no internal battery so the
// view hides the whole section on desktops.
//
// Adapted from Stats (MIT) — `Modules/Battery/readers.swift` `UsageReader`.
enum BatterySampler {
    static func sample() -> BatterySample? {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
        guard !sources.isEmpty else { return nil }

        for ps in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }

            let percent = desc[kIOPSCurrentCapacityKey] as? Int
            let isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false

            var timeRemaining: Int?
            if isCharging {
                if let t = desc[kIOPSTimeToFullChargeKey] as? Int, t >= 0 { timeRemaining = t }
            } else if let t = desc[kIOPSTimeToEmptyKey] as? Int, t >= 0 {
                timeRemaining = t
            }

            let (cycles, health) = smartBatteryDetail()
            return BatterySample(
                percent: percent,
                cycleCount: cycles,
                healthPercent: health,
                isCharging: isCharging,
                timeRemainingMinutes: timeRemaining,
                chargingWatts: adapterWatts())
        }
        return nil
    }

    /// Cycle count and health % from the AppleSmartBattery registry node.
    private static func smartBatteryDetail() -> (cycles: Int?, health: Int?) {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }

        func intProp(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }

        let cycles = intProp("CycleCount")
        let maxCap = intProp("AppleRawMaxCapacity") ?? intProp("MaxCapacity")
        let design = intProp("DesignCapacity")
        var health: Int?
        if let maxCap, let design, design > 0 {
            health = Int((Double(maxCap) / Double(design) * 100).rounded())
        }
        return (cycles, health)
    }

    /// Wattage of the attached power adapter, if any.
    private static func adapterWatts() -> Double? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?
            .takeRetainedValue() as? [String: Any] else { return nil }
        if let w = details[kIOPSPowerAdapterWattsKey] as? Int, w > 0 { return Double(w) }
        return nil
    }
}
