import Foundation
import Observation

// Main-actor observable that drives the popover. Sampling runs only while the
// popover is on screen: `start()` on appear, `stop()` on disappear, and a
// belt-and-suspenders cancel in `deinit`. The app's idle CPU budget is 0%, so
// there is deliberately no timer while the popover is closed.
@MainActor
@Observable
final class MonitorModel {
    private(set) var snapshot = MonitorSnapshot()

    /// Per-section sample history, appended each tick for visible sections only.
    /// Kept alongside `snapshot` (which only holds the latest tick) so the cards
    /// can draw a trend. Capacity is one screen's worth of samples; a hidden
    /// section's buffer stops growing and is cleared on hide (see `prefs.didSet`)
    /// so re-showing starts a fresh trace rather than a stale one across a gap.
    static let historyCapacity = 60
    private(set) var cpuHistory = HistoryBuffer<Double>(capacity: historyCapacity)
    private(set) var memoryHistory = HistoryBuffer<Double>(capacity: historyCapacity)
    private(set) var netDownHistory = HistoryBuffer<Double>(capacity: historyCapacity)
    private(set) var netUpHistory = HistoryBuffer<Double>(capacity: historyCapacity)

    /// Which sections show and how often the loop ticks. Observable so the
    /// window's settings strip rebinds live; each change persists and, if the
    /// loop is running, restarts it so a newly-shown section appears promptly
    /// instead of a whole (up to 5 s) interval later.
    var prefs: MonitorPrefs {
        didSet {
            guard prefs != oldValue else { return }
            // Clear history for any section just hidden so a later re-show starts
            // fresh instead of stitching across the hidden gap.
            for section in oldValue.visibleSections.subtracting(prefs.visibleSections) {
                clearHistory(section)
            }
            prefs.save(to: defaults)
            if task != nil { restart() }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sampler = MonitorSampler()
    @ObservationIgnored private var task: Task<Void, Never>?

    /// `defaults` is injectable so the prefs round-trip is testable without
    /// touching the shared domain.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.prefs = MonitorPrefs.load(from: defaults)
    }

    /// Begins the tick. Idempotent — a second `start()` is a no-op, so a
    /// view's `.onAppear` can call it freely.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self, sampler] in
            // Seed the CPU/network baselines for whatever is visible, wait
            // briefly, then take the first shown sample so rates are populated
            // almost immediately instead of a full interval later.
            // Memory/battery/sensors are absolute and appear on this first
            // shown sample too. Hidden sections are never sampled.
            _ = await sampler.sample(sections: self?.prefs.visibleSections ?? [])
            try? await Task.sleep(for: .milliseconds(600))
            while !Task.isCancelled {
                let snap = await sampler.sample(sections: self?.prefs.visibleSections ?? [])
                guard let self, !Task.isCancelled else { return }
                self.snapshot = snap
                self.recordHistory(snap)
                try? await Task.sleep(for: .seconds(self.prefs.refreshRate.seconds))
            }
        }
    }

    /// Stops sampling. Called from `.onDisappear`.
    func stop() {
        task?.cancel()
        task = nil
    }

    /// Cancels the running loop and starts a fresh one, so a prefs change takes
    /// effect on the next ~600 ms rather than at the end of the current sleep.
    private func restart() {
        stop()
        start()
    }

    /// Appends the latest tick to each visible section's buffer. A field is only
    /// present when that section was sampled (which only happens when visible),
    /// so this both gates on visibility and skips a soft-failed sampler.
    /// Internal (not private) so the gating is unit-testable without the loop.
    func recordHistory(_ snap: MonitorSnapshot) {
        if prefs.visibleSections.contains(.cpu), let cpu = snap.cpu {
            cpuHistory.append(cpu.total)
        }
        if prefs.visibleSections.contains(.memory), let memory = snap.memory {
            memoryHistory.append(memory.usedFraction)
        }
        if prefs.visibleSections.contains(.network), let network = snap.network {
            netDownHistory.append(network.downBytesPerSec)
            netUpHistory.append(network.upBytesPerSec)
        }
    }

    /// Clears the buffer(s) backing a section when it is hidden.
    private func clearHistory(_ section: MonitorSection) {
        switch section {
        case .cpu: cpuHistory.clear()
        case .memory: memoryHistory.clear()
        case .network:
            netDownHistory.clear()
            netUpHistory.clear()
        case .battery, .sensors:
            break  // no trend chart — nothing buffered
        }
    }

    deinit {
        task?.cancel()
    }
}
