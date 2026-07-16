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

    /// Which sections show and how often the loop ticks. Observable so the
    /// window's settings strip rebinds live; each change persists and, if the
    /// loop is running, restarts it so a newly-shown section appears promptly
    /// instead of a whole (up to 5 s) interval later.
    var prefs: MonitorPrefs {
        didSet {
            guard prefs != oldValue else { return }
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

    deinit {
        task?.cancel()
    }
}
