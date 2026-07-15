import Observation

// Main-actor observable that drives the popover. Sampling runs only while the
// popover is on screen: `start()` on appear, `stop()` on disappear, and a
// belt-and-suspenders cancel in `deinit`. The app's idle CPU budget is 0%, so
// there is deliberately no timer while the popover is closed.
@MainActor
@Observable
final class MonitorModel {
    private(set) var snapshot = MonitorSnapshot()

    @ObservationIgnored private let sampler = MonitorSampler()
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Begins the 2 s tick. Idempotent — a second `start()` is a no-op, so a
    /// view's `.onAppear` can call it freely.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self, sampler] in
            // Seed the CPU/network baselines, wait briefly, then take the first
            // shown sample so rates are populated almost immediately instead of
            // a full interval later. Memory/battery/sensors are absolute and
            // appear on this first shown sample too.
            _ = await sampler.sample()
            try? await Task.sleep(for: .milliseconds(600))
            while !Task.isCancelled {
                let snap = await sampler.sample()
                guard let self, !Task.isCancelled else { return }
                self.snapshot = snap
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Stops sampling. Called from `.onDisappear`.
    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
