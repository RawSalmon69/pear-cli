import Foundation

// Owns all the mutable sampling state (previous CPU ticks, previous network
// counters, the SMC connection and resolved keys) behind an actor. Being an
// actor makes it `Sendable` and keeps every raw Mach/IOKit/SMC call off the
// main actor; only the resulting `MonitorSnapshot` value crosses back. The
// non-`Sendable` `SMCConnection` never leaves the actor, so no `@unchecked`
// is needed anywhere.
actor MonitorSampler {
    private var prevCPUTicks: [UInt32]?
    private var prevNet: (rx: UInt64, tx: UInt64, at: Date)?

    // Outer optional = "have we tried to open the SMC yet"; inner = the
    // connection (nil when the machine/OS refused the open).
    private var smcResolved = false
    private var smc: SMCConnection?
    private var sensorKeys: ResolvedSensorKeys?

    /// One full pass. Each section fails independently — a nil from any
    /// sampler just leaves that field nil in the snapshot.
    func sample() -> MonitorSnapshot {
        var snapshot = MonitorSnapshot()
        snapshot.cpu = sampleCPU()
        snapshot.memory = MemorySampler.sample()
        snapshot.network = sampleNetwork()
        snapshot.battery = BatterySampler.sample()
        snapshot.sensors = sampleSensors()
        return snapshot
    }

    private func sampleCPU() -> CPUSample? {
        guard let ticks = CPUSampler.readTicks() else { return nil }
        defer { prevCPUTicks = ticks }
        guard let prev = prevCPUTicks, prev.count == ticks.count else { return nil }

        let usages = CPUUsage.coreUsages(previous: prev, current: ticks)
        guard !usages.isEmpty else { return nil }
        let total = usages.reduce(0, +) / Double(usages.count)
        let cores = usages.enumerated().map { CoreLoad(id: $0.offset, usage: $0.element) }
        return CPUSample(cores: cores, total: total)
    }

    private func sampleNetwork() -> NetworkSample? {
        guard let counters = NetworkSampler.counters() else { return nil }
        let now = Date()
        defer { prevNet = (counters.rx, counters.tx, now) }
        guard let prev = prevNet else { return nil }

        let dt = now.timeIntervalSince(prev.at)
        guard dt > 0 else { return nil }
        // Clamp negative deltas (32-bit counter wrap or interface reset) to 0
        // instead of reporting a phantom spike.
        let dRx = counters.rx >= prev.rx ? counters.rx - prev.rx : 0
        let dTx = counters.tx >= prev.tx ? counters.tx - prev.tx : 0
        return NetworkSample(
            downBytesPerSec: Double(dRx) / dt,
            upBytesPerSec: Double(dTx) / dt,
            interfaceName: counters.name)
    }

    private func sampleSensors() -> SensorSample? {
        if !smcResolved {
            smcResolved = true
            smc = SMCConnection()
            if let smc { sensorKeys = SensorSampler.resolve(smc) }
        }
        guard let smc, let keys = sensorKeys, !keys.isEmpty else { return nil }
        return SensorSampler.read(smc, keys: keys)
    }
}
