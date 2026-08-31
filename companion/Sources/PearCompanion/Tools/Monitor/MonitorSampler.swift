import Foundation

// Owns all the mutable sampling state (previous CPU ticks, previous network
// counters, the SMC connection and resolved keys) behind an actor. Being an
// actor makes it `Sendable` and keeps every raw Mach/IOKit/SMC call off the
// main actor; only the resulting `MonitorSnapshot` value crosses back. The
// non-`Sendable` `SMCConnection` never leaves the actor, so no `@unchecked`
// is needed anywhere.
actor MonitorSampler {
    private var prevCPUTicks: [UInt32]?
    /// Previous process listing, keyed by pid, so per-process counters can be
    /// differenced into rates. Cleared when the section is hidden so a re-show
    /// does not difference across the gap.
    private var prevProcesses: [Int32: RawProcess]?
    private var prevProcessesAt: Date?
    private var prevNet: (rx: UInt64, tx: UInt64, at: Date)?

    private let processes: ProcessLister
    private var smc: SMCConnection?
    private var sensorKeys: ResolvedSensorKeys?
    // How many times we've tried to resolve the sensor key set. The open or the
    // first probe can transiently answer nothing, so retry for a few ticks
    // before accepting an empty set as final (see `sampleSensors`).
    private var smcResolveAttempts = 0
    private static let maxSMCResolveAttempts = 3

    /// How many rolled-up apps the card shows. The tail of a process table is
    /// hundreds of idle daemons, and nobody scrolls it.
    static let topGroupCount = 8

    init(processes: ProcessLister = LibprocProcessLister()) {
        self.processes = processes
    }

    /// One pass over the requested sections. A hidden section's sampler is
    /// never called — the guard is the "zero cost when hidden" guarantee, not
    /// just a render filter — so an empty set does no hardware work at all.
    /// Each sampled section still fails independently: a nil from any sampler
    /// just leaves that field nil in the snapshot.
    func sample(sections: Set<MonitorSection>, metric: ProcessMetric = .cpu) -> MonitorSnapshot {
        var snapshot = MonitorSnapshot()
        if sections.contains(.processes) {
            snapshot.processes = sampleProcesses(metric: metric)
        } else {
            prevProcesses = nil
            prevProcessesAt = nil
        }
        if sections.contains(.cpu) { snapshot.cpu = sampleCPU() }
        if sections.contains(.memory) { snapshot.memory = MemorySampler.sample() }
        if sections.contains(.network) { snapshot.network = sampleNetwork() }
        if sections.contains(.battery) { snapshot.battery = BatterySampler.sample() }
        if sections.contains(.sensors) { snapshot.sensors = sampleSensors() }
        return snapshot
    }

    /// Two listings make a rate, so the first tick after the section appears
    /// reports memory and thread counts with zero rates rather than nonsense
    /// derived from lifetime totals.
    private func sampleProcesses(metric: ProcessMetric) -> ProcessSample? {
        let now = Date()
        let current = processes.list()
        guard !current.isEmpty else { return nil }
        let interval = prevProcessesAt.map { now.timeIntervalSince($0) } ?? 0
        let previous = prevProcesses ?? [:]
        defer {
            prevProcesses = Dictionary(
                current.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
            prevProcessesAt = now
        }
        let groups = ProcessRollup.groups(
            previous: previous,
            current: current,
            interval: interval > 0 ? interval : 1,
            metric: metric)
        return ProcessSample(
            allGroups: groups,
            showing: Self.topGroupCount,
            coreCount: ProcessInfo.processInfo.activeProcessorCount)
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
        // Resolve lazily, retrying while we have nothing: a single transient
        // miss (empty key set) must not blank the Sensors card for the whole
        // session. Once a non-empty set resolves — or we've exhausted the
        // attempts — we stop probing and read only what exists.
        if (sensorKeys?.isEmpty ?? true), smcResolveAttempts < Self.maxSMCResolveAttempts {
            smcResolveAttempts += 1
            if smc == nil { smc = SMCConnection() }
            if let smc { sensorKeys = SensorSampler.resolve(smc) }
        }
        guard let smc, let keys = sensorKeys, !keys.isEmpty else { return nil }
        return SensorSampler.read(smc, keys: keys)
    }
}
